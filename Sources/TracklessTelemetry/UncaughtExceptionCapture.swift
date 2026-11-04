import Foundation

/// What a send from the uncaught-exception handler needs, captured while the
/// SDK is healthy.
///
/// The handler runs on a thread that is about to die. It cannot await the state
/// actor, so everything it sends is read from here: the state actor replaces it
/// synchronously, with no suspension point, whenever configure, setEnabled or
/// destroy changes what a send would go out under.
struct UncaughtSendSnapshot: Sendable {
    let endpoint: String
    let apiKey: String
    let environment: TracklessEnvironment
    /// The batch context, which carries `sdkVersion`.
    let context: TracklessEventContext
    /// The configuration's session. Its `endNow()` is synchronous and shares
    /// the session's one lock-guarded record, so the start time and depth it
    /// reports are the live ones, and a session ends only once.
    let session: SessionManager
}

/// The `captureUncaught` option: counts an `NSException` the app did not
/// catch as `error("trackless.uncaught", code: <exception name>)`.
///
/// **What it reads from the exception: its `name`, nothing else.** Not the
/// reason, not `userInfo`, not the call stack symbols or return addresses. The
/// name goes through the same normalization as any `code`; one that
/// normalization rejects is sent as `unknown`.
///
/// **Sends now or never.** Nothing is written to disk for a later launch. The
/// handler builds a standalone payload — the uncaught error event and the
/// session's end — posts it with a `URLSession` data task and waits on a
/// semaphore for at most `waitSeconds` (1.5 s). Events still in the state
/// actor's buffer are lost, as they are on any crash.
///
/// **Chained, always.** The handler that was installed before ours (a crash
/// reporter's, typically) is saved at install and called after our send,
/// whatever the send did — failed, timed out, or never started because the
/// option is off or recording is disabled.
///
/// **Installed once, never removed.** Another library may have installed its
/// own handler after ours and chained to it, so uninstalling would cut that
/// library's chain. Turning the option off, `setEnabled(false)` or `destroy()`
/// clear the snapshot instead, and the handler passes straight through.
///
/// **Coverage on Apple platforms is narrow.** Most Swift crashes —
/// force-unwrapping nil, `fatalError`, an array index out of range — are
/// signals, not exceptions, and never reach this handler. On macOS, AppKit
/// catches exceptions raised during event handling and logs them.
///
/// Never throws into the host, and takes its lock only for field reads.
final class UncaughtExceptionCapture: @unchecked Sendable {

    /// Delivers one request, calling `completion` when it finishes (in any
    /// way). Production uses a `URLSession` data task; tests inject a recorder.
    typealias Sender = @Sendable (
        _ request: URLRequest,
        _ completion: @escaping @Sendable () -> Void
    ) -> Void

    /// The longest the handler holds up a dying process for its send.
    static let defaultWaitSeconds: TimeInterval = 1.5

    /// The code sent when the exception's name does not survive normalization.
    static let fallbackCode = "unknown"

    /// Production sender: the completion-handler data task, not the async API —
    /// the handler's thread blocks on a semaphore and cannot await.
    static let urlSessionSender: Sender = { request, completion in
        URLSession.shared.dataTask(with: request) { _, _, _ in
            completion()
        }.resume()
    }

    private let clock: TracklessClock
    private let sender: Sender
    private let waitSeconds: TimeInterval
    private let slot: any UncaughtHandlerSlot

    private let lock = NSLock()
    private var snapshot: UncaughtSendSnapshot?
    private var installed = false
    private var previous: CExceptionHandler?
    private var sent = false

    init(
        clock: TracklessClock,
        sender: @escaping Sender = UncaughtExceptionCapture.urlSessionSender,
        waitSeconds: TimeInterval = UncaughtExceptionCapture.defaultWaitSeconds,
        slot: any UncaughtHandlerSlot = ProcessUncaughtHandlerSlot()
    ) {
        self.clock = clock
        self.sender = sender
        self.waitSeconds = waitSeconds
        self.slot = slot
    }

    /// Replace what a send goes out under; nil makes the handler send nothing.
    func update(_ snapshot: UncaughtSendSnapshot?) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    /// Install the handler, unless this capture already did. The previous
    /// handler is read before ours goes in, so there is no moment at which ours
    /// is live without knowing what to chain to.
    func installIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        previous = slot.get()
        UncaughtExceptionCapture.target.set(self)
        slot.set(uncaughtExceptionTrampoline)
    }

    /// Whether `installIfNeeded()` has installed the handler.
    var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    /// The handler body: send once, if there is a snapshot, then call the
    /// previous handler — unconditionally.
    func handle(_ exception: NSException) {
        lock.lock()
        let previous = self.previous
        let snapshot = sent ? nil : self.snapshot
        if snapshot != nil { sent = true }
        lock.unlock()

        if let snapshot {
            send(exceptionName: exception.name.rawValue, under: snapshot)
        }
        previous?(exception)
    }

    /// The one payload this sends: the uncaught error event and, when a session
    /// is running, its end. **Ends the snapshot's session** (through the
    /// session's own lock, so the actor can never end it a second time). The
    /// error event does not add to the session's depth: like the launch and
    /// hang metrics, it describes the app rather than anything the user did.
    func payload(exceptionName: String, under snapshot: UncaughtSendSnapshot) -> TracklessEventPayload {
        let code = FeatureValidator.normalize(exceptionName) ?? Self.fallbackCode
        var events = [
            TracklessEvent(
                type: .error,
                name: Trackless.uncaughtErrorName,
                firstOccurrences: 1,
                severity: .error,
                code: code
            ),
        ]
        if let end = snapshot.session.endNow() {
            events.append(TracklessState.sessionEndEvent(end))
        }
        return TracklessEventPayload(
            date: EventBuffer.payloadDate(for: clock.now),
            environment: snapshot.environment.rawValue,
            context: snapshot.context,
            events: events
        )
    }

    private func send(exceptionName: String, under snapshot: UncaughtSendSnapshot) {
        let payload = payload(exceptionName: exceptionName, under: snapshot)
        guard let request = try? HTTPClient.makeRequest(
            endpoint: snapshot.endpoint,
            apiKey: snapshot.apiKey,
            payload: payload,
            timeoutSeconds: waitSeconds
        ) else { return }

        let done = DispatchSemaphore(value: 0)
        sender(request) { done.signal() }
        _ = done.wait(timeout: .now() + waitSeconds)
    }

    // MARK: - Process-wide hook

    /// The capture the C-convention handler forwards to.
    ///
    /// A `@convention(c)` function cannot capture context, so the handler has
    /// to find its capture through a global. This is a `static let` of a
    /// lock-guarded box rather than a `nonisolated(unsafe) var`, so the
    /// compiler still checks it: the box is the only shared mutable state, and
    /// its one field is read and written under its lock. Production has one
    /// state, so one capture, installed once per process.
    static let target = Target()

    final class Target: @unchecked Sendable {
        private let lock = NSLock()
        private var capture: UncaughtExceptionCapture?

        func set(_ capture: UncaughtExceptionCapture) {
            lock.lock()
            self.capture = capture
            lock.unlock()
        }

        var current: UncaughtExceptionCapture? {
            lock.lock()
            defer { lock.unlock() }
            return capture
        }
    }
}

/// The C function pointer type `NSSetUncaughtExceptionHandler` takes.
typealias CExceptionHandler = @convention(c) (NSException) -> Void

/// The function installed with `NSSetUncaughtExceptionHandler`. A plain
/// top-level `func` with no captured context, so it converts to the C function
/// pointer the API takes; it reaches its capture through
/// `UncaughtExceptionCapture.target`.
func uncaughtExceptionTrampoline(_ exception: NSException) {
    UncaughtExceptionCapture.target.current?.handle(exception)
}

/// Where the process keeps its uncaught-exception handler. Production is the
/// real Foundation slot; tests inject one so nothing in the test process is
/// replaced.
protocol UncaughtHandlerSlot: Sendable {
    func get() -> CExceptionHandler?
    func set(_ handler: CExceptionHandler?)
}

/// The real slot: `NSGetUncaughtExceptionHandler` / `NSSetUncaughtExceptionHandler`.
struct ProcessUncaughtHandlerSlot: UncaughtHandlerSlot {
    func get() -> CExceptionHandler? {
        NSGetUncaughtExceptionHandler()
    }

    func set(_ handler: CExceptionHandler?) {
        NSSetUncaughtExceptionHandler(handler)
    }
}
