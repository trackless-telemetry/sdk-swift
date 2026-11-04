import Foundation
import Testing

@testable import TracklessTelemetry

/// `captureUncaught`: the `NSException` handler, its chaining, the send
/// snapshot, the 1.5 s cap and the reserved prefix on `error()` / `info()`.
///
/// No real network and no real handler install (except one test, which puts
/// the process's handler back): the state gets a `FakeHandlerSlot`, a
/// `RequestRecorder` sender and a `FakeClock`, and the tests call the handler
/// directly with a constructed `NSException`.
///
/// Serialized because the C-convention handler finds its capture through one
/// process-wide target, which every install in this suite points at itself.
@Suite("Uncaught exceptions", .serialized)
struct UncaughtExceptionTests {

    // MARK: - Fixtures

    private let apiKey = "tl_0123456789abcdef0123456789abcdef"
    private let endpoint = "https://ingest.test"

    private func makeState(
        clock: FakeClock = FakeClock(),
        sender: RequestRecorder,
        slot: any UncaughtHandlerSlot,
        waitSeconds: TimeInterval = 1.5,
        transport: TransportRecorder = TransportRecorder()
    ) -> TracklessState {
        TracklessState(
            clock: clock,
            notificationCenter: NotificationCenter(),
            transport: transport.transport,
            appIsActive: { false },
            postToMain: ManualMainQueue().scheduler,
            hangTicker: { _, _ in {} },
            uncaughtSender: sender.sender,
            uncaughtWaitSeconds: waitSeconds,
            uncaughtHandlerSlot: slot
        )
    }

    private func config(
        apiKey: String? = nil,
        enabled: Bool = true,
        captureUncaught: Bool = true
    ) -> TracklessConfig {
        TracklessConfig(
            apiKey: apiKey ?? self.apiKey,
            endpoint: endpoint,
            environment: .production,
            enabled: enabled,
            flushIntervalSeconds: 3600,
            captureUncaught: captureUncaught
        )
    }

    /// A unique exception name per test, so the shared previous-handler log
    /// can be read without interference.
    private func exception(_ name: String, reason: String? = nil, userInfo: [AnyHashable: Any]? = nil) -> NSException {
        NSException(name: NSExceptionName(rawValue: name), reason: reason, userInfo: userInfo)
    }

    // MARK: - Opt-in

    @Test("Option off: the handler is not installed and nothing is sent")
    func optionOff() async {
        let sender = RequestRecorder()
        let slot = FakeHandlerSlot()
        let state = makeState(sender: sender, slot: slot)
        await state.configure(config(captureUncaught: false))

        #expect(slot.setCount == 0)
        #expect(!state.uncaught.isInstalled)

        state.uncaught.handle(exception("OffException"))
        #expect(sender.requests.isEmpty)
    }

    @Test("Option on but configured disabled: not installed")
    func configuredDisabled() async {
        let sender = RequestRecorder()
        let slot = FakeHandlerSlot()
        let state = makeState(sender: sender, slot: slot)
        await state.configure(config(enabled: false))

        #expect(slot.setCount == 0)
        state.uncaught.handle(exception("DisabledConfigException"))
        #expect(sender.requests.isEmpty)
    }

    @Test("Installs once, chained to the handler that was there before")
    func installsOnceAndChains() async {
        let sender = RequestRecorder()
        let slot = FakeHandlerSlot(initial: recordPreviousHandler)
        let state = makeState(sender: sender, slot: slot)

        await state.configure(config())
        #expect(slot.setCount == 1)
        #expect(state.uncaught.isInstalled)

        // A changed configuration, a disable and re-enable, and a destroy and
        // configure: never a second install.
        await state.configure(config(apiKey: "tl_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
        await state.setEnabled(false)
        await state.setEnabled(true)
        await state.destroy()
        await state.configure(config())
        #expect(slot.setCount == 1)

        // The previous handler is called after our send, with the same exception.
        let log = PreviousHandlerLog.shared
        let before = log.count(of: "ChainException")
        state.uncaught.handle(exception("ChainException"))
        #expect(sender.requests.count == 1)
        #expect(log.count(of: "ChainException") == before + 1)
    }

    @Test("Changing captureUncaught in a repeat configure is a changed setting")
    func changedSetting() async {
        let sender = RequestRecorder()
        let transport = TransportRecorder()
        let state = makeState(sender: sender, slot: FakeHandlerSlot(), transport: transport)
        await state.configure(config(captureUncaught: false))
        await state.configure(config(captureUncaught: true))

        // The retired session was ended and flushed: a changed configuration.
        let retired = transport.events(apiKey: apiKey).filter { $0.type == .session }.map(\.name)
        #expect(retired == ["start", "end"])
        #expect(state.uncaught.isInstalled)
    }

    // MARK: - The send

    @Test("Sends one payload: the uncaught error, code normalized, and the session end")
    func sendsOnePayload() async throws {
        let clock = FakeClock()
        let sender = RequestRecorder()
        let state = makeState(clock: clock, sender: sender, slot: FakeHandlerSlot())
        await state.configure(config())
        await state.recordEvent(type: .feature, name: "export")
        await state.recordEvent(type: .view, name: "home")
        clock.advance(12)

        state.uncaught.handle(exception(NSExceptionName.invalidArgumentException.rawValue))

        let requests = sender.requests
        try #require(requests.count == 1)
        let request = requests[0]
        #expect(request.url?.absoluteString == endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == apiKey)
        #expect(request.timeoutInterval == 1.5)

        let payload = try JSONDecoder().decode(TracklessEventPayload.self, from: try #require(request.httpBody))
        #expect(payload.environment == "production")
        #expect(payload.context == (await state.contextForTesting()))
        #expect(payload.date == EventBuffer.payloadDate(for: clock.now))
        #expect(payload.events.count == 2)

        let error = try #require(payload.events.first)
        #expect(error.type == .error)
        #expect(error.name == "trackless.uncaught")
        #expect(error.code == "nsinvalidargumentexception")
        #expect(error.severity == .error)
        #expect(error.firstOccurrences == 1)

        let end = try #require(payload.events.last)
        #expect(end.type == .session)
        #expect(end.name == "end")
        #expect(end.duration == 12)
        // Depth counts the two events the user caused, not the uncaught error.
        #expect(end.stepIndex == 2)

        // The session ended exactly once: nothing is left for the actor to end.
        #expect(!(await state.isSessionActiveForTesting()))
    }

    @Test("A second uncaught exception sends nothing more, and still chains")
    func sendsOncePerProcess() async {
        let sender = RequestRecorder()
        let state = makeState(sender: sender, slot: FakeHandlerSlot(initial: recordPreviousHandler))
        await state.configure(config())
        let log = PreviousHandlerLog.shared
        let before = log.count(of: "TwiceException")

        state.uncaught.handle(exception("TwiceException"))
        state.uncaught.handle(exception("TwiceException"))

        #expect(sender.requests.count == 1)
        #expect(log.count(of: "TwiceException") == before + 2)
    }

    @Test("Exception names go through the same normalization as any code")
    func codeNormalization() throws {
        let capture = UncaughtExceptionCapture(clock: FakeClock(), sender: RequestRecorder().sender, slot: FakeHandlerSlot())
        let snapshot = UncaughtSendSnapshot(
            endpoint: endpoint,
            apiKey: apiKey,
            environment: .sandbox,
            context: TracklessEventContext(),
            session: SessionManager(clock: FakeClock())
        )
        func code(_ name: String) -> String? {
            capture.payload(exceptionName: name, under: snapshot).events.first?.code
        }

        #expect(code("MyApp.Custom Exception") == "myapp.custom_exception")
        #expect(code("NSRangeException") == "nsrangeexception")
        // Rejected by normalization: empty, all hex, nothing left after the
        // character rules.
        #expect(code("") == "unknown")
        #expect(code("deadbeefdeadbeefdeadbeefdeadbeef") == "unknown")
        #expect(code("例外") == "unknown")
        // No session running: the error event alone.
        #expect(capture.payload(exceptionName: "x", under: snapshot).events.count == 1)
    }

    @Test("With no session running (iOS, after background) only the error event is sent")
    func noSessionNoEnd() async throws {
        let sender = RequestRecorder()
        let state = makeState(sender: sender, slot: FakeHandlerSlot())
        await state.configure(config())
        await state.endSessionForTesting()

        state.uncaught.handle(exception("BackgroundException"))

        let payload = try #require(sender.payloads.first)
        #expect(payload.events.map(\.name) == ["trackless.uncaught"])
    }

    @Test("Nothing from the reason, user info or call stack reaches the payload")
    func readsOnlyTheName() async throws {
        let sender = RequestRecorder()
        let state = makeState(sender: sender, slot: FakeHandlerSlot())
        await state.configure(config())

        state.uncaught.handle(exception(
            "LeakException",
            reason: "reason_secret jane@example.com /Users/jane/file.swift:42",
            userInfo: ["userinfo_key": "userinfo_secret"]
        ))

        let body = try #require(sender.requests.first?.httpBody)
        let text = try #require(String(data: body, encoding: .utf8))
        for leaked in ["reason_secret", "jane", "example.com", "file.swift", "userinfo_key", "userinfo_secret"] {
            #expect(!text.contains(leaked), "payload contains \(leaked)")
        }
        #expect(text.contains("leakexception"))
    }

    @Test("The capture's source reads nothing from the exception but its name")
    func sourceReadsOnlyTheName() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TracklessTelemetry/UncaughtExceptionCapture.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for forbidden in [".reason", "userInfo", "callStackSymbols", "callStackReturnAddresses"] {
            #expect(!code.contains(forbidden), "UncaughtExceptionCapture.swift uses \(forbidden)")
        }
        #expect(code.contains("exception.name.rawValue"))
    }

    // MARK: - Failure and the cap

    @Test("The previous handler is called when the send fails")
    func chainsWhenSendFails() async {
        let sender = RequestRecorder(mode: .failImmediately)
        let state = makeState(sender: sender, slot: FakeHandlerSlot(initial: recordPreviousHandler))
        await state.configure(config())
        let log = PreviousHandlerLog.shared
        let before = log.count(of: "FailedSendException")

        state.uncaught.handle(exception("FailedSendException"))

        #expect(sender.requests.count == 1)
        #expect(log.count(of: "FailedSendException") == before + 1)
    }

    @Test("A send that never finishes is abandoned at the cap, then the previous handler runs")
    func chainsAfterTheCap() async {
        let sender = RequestRecorder(mode: .neverComplete)
        let state = makeState(sender: sender, slot: FakeHandlerSlot(initial: recordPreviousHandler), waitSeconds: 0.05)
        await state.configure(config())
        let log = PreviousHandlerLog.shared
        let before = log.count(of: "SlowSendException")

        let started = Date()
        state.uncaught.handle(exception("SlowSendException"))
        let waited = Date().timeIntervalSince(started)

        #expect(sender.requests.count == 1)
        #expect(sender.requests.first?.timeoutInterval == 0.05)
        #expect(waited >= 0.04)
        #expect(waited < 1.0)
        #expect(log.count(of: "SlowSendException") == before + 1)
    }

    @Test("An unparseable endpoint sends nothing and still chains")
    func chainsOnBadEndpoint() async {
        let sender = RequestRecorder()
        let state = makeState(sender: sender, slot: FakeHandlerSlot(initial: recordPreviousHandler))
        await state.configure(TracklessConfig(
            apiKey: apiKey,
            endpoint: "",
            environment: .production,
            flushIntervalSeconds: 3600,
            captureUncaught: true
        ))
        let log = PreviousHandlerLog.shared
        let before = log.count(of: "BadEndpointException")

        state.uncaught.handle(exception("BadEndpointException"))

        #expect(sender.requests.isEmpty)
        #expect(log.count(of: "BadEndpointException") == before + 1)
    }

    // MARK: - Pass-through

    @Test("setEnabled(false): passes straight through, sends nothing; re-enabling sends again")
    func disabledPassesThrough() async {
        let sender = RequestRecorder()
        let state = makeState(sender: sender, slot: FakeHandlerSlot(initial: recordPreviousHandler))
        await state.configure(config())
        await state.setEnabled(false)
        let log = PreviousHandlerLog.shared
        let before = log.count(of: "OptedOutException")

        state.uncaught.handle(exception("OptedOutException"))
        #expect(sender.requests.isEmpty)
        #expect(log.count(of: "OptedOutException") == before + 1)

        await state.setEnabled(true)
        state.uncaught.handle(exception("OptedOutException"))
        #expect(sender.requests.count == 1)
    }

    @Test("Turned off by a reconfigure: still installed, passes straight through")
    func turnedOffPassesThrough() async {
        let sender = RequestRecorder()
        let slot = FakeHandlerSlot(initial: recordPreviousHandler)
        let state = makeState(sender: sender, slot: slot)
        await state.configure(config())
        await state.configure(config(captureUncaught: false))
        let log = PreviousHandlerLog.shared
        let before = log.count(of: "TurnedOffException")

        state.uncaught.handle(exception("TurnedOffException"))

        #expect(slot.setCount == 1)
        #expect(sender.requests.isEmpty)
        #expect(log.count(of: "TurnedOffException") == before + 1)
    }

    @Test("destroy(): passes straight through, sends nothing")
    func destroyedPassesThrough() async {
        let sender = RequestRecorder()
        let state = makeState(sender: sender, slot: FakeHandlerSlot())
        await state.configure(config())
        await state.destroy()

        state.uncaught.handle(exception("DestroyedException"))
        #expect(sender.requests.isEmpty)
    }

    @Test("A reconfigure points the send at the new key and the new session")
    func reconfigureRetargets() async throws {
        let sender = RequestRecorder()
        let state = makeState(sender: sender, slot: FakeHandlerSlot())
        await state.configure(config())
        await state.recordEvent(type: .feature, name: "old_session")
        let newKey = "tl_cccccccccccccccccccccccccccccccc"
        await state.configure(config(apiKey: newKey))

        state.uncaught.handle(exception("RetargetException"))

        let request = try #require(sender.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == newKey)
        let payload = try #require(sender.payloads.first)
        // The new session has no activity yet.
        #expect(payload.events.last?.stepIndex == 0)
    }

    // MARK: - The real slot

    @Test("Installed in the process slot, the C handler forwards to the capture and chains")
    func realSlot() async throws {
        let original = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(recordPreviousHandler)
        defer { NSSetUncaughtExceptionHandler(original) }

        let sender = RequestRecorder()
        let state = makeState(sender: sender, slot: ProcessUncaughtHandlerSlot())
        await state.configure(config())

        let installed = try #require(NSGetUncaughtExceptionHandler())
        let log = PreviousHandlerLog.shared
        let before = log.count(of: "RealSlotException")
        installed(exception("RealSlotException"))

        #expect(sender.requests.count == 1)
        #expect(log.count(of: "RealSlotException") == before + 1)
    }

    // MARK: - Reserved prefix

    @Test("error() and info() warn once per process for a trackless. name, and send it")
    func reservedPrefixOnErrorAndInfo() async {
        let warnings = WarningRecorder()
        let state = makeState(sender: RequestRecorder(), slot: FakeHandlerSlot())
        await state.setOnWarningForTesting { warnings.record($0) }
        await state.configure(config(captureUncaught: false))

        await state.recordError(name: "Trackless.Mine", severity: .error, code: nil)
        await state.recordError(name: "trackless.other", severity: .info, code: nil)
        await state.recordError(name: "not_reserved", severity: .error, code: nil)

        let reserved = warnings.messages.filter { $0.contains("reserved") }
        #expect(reserved.count == 1)
        #expect(reserved.first?.hasPrefix("error name \"trackless.mine\"") == true)
        let names = await state.drainBufferForTesting().filter { $0.type == .error }.map(\.name).sorted()
        #expect(names == ["not_reserved", "trackless.mine", "trackless.other"])

        let infoWarnings = WarningRecorder()
        let infoState = makeState(sender: RequestRecorder(), slot: FakeHandlerSlot())
        await infoState.setOnWarningForTesting { infoWarnings.record($0) }
        await infoState.configure(config(captureUncaught: false))
        await infoState.recordError(name: "trackless.tier", severity: .info, code: "paid")
        let infoReserved = infoWarnings.messages.filter { $0.contains("reserved") }
        #expect(infoReserved.count == 1)
        #expect(infoReserved.first?.hasPrefix("info name \"trackless.tier\"") == true)
    }

    @Test("The SDK's own uncaught send never warns")
    func uncaughtSendDoesNotWarn() async {
        let warnings = WarningRecorder()
        let sender = RequestRecorder()
        let state = makeState(sender: sender, slot: FakeHandlerSlot())
        await state.setOnWarningForTesting { warnings.record($0) }
        await state.configure(config())

        state.uncaught.handle(exception("QuietException"))
        #expect(sender.requests.count == 1)
        #expect(warnings.messages.filter { $0.contains("reserved") }.isEmpty)

        // The once-per-process warning is still there for a developer's name.
        await state.recordError(name: "trackless.uncaught", severity: .error, code: nil)
        #expect(warnings.messages.filter { $0.contains("reserved") }.count == 1)
    }
}

// MARK: - Test Helpers

/// What the previous handler in the slot saw: the names of the exceptions it
/// was called with. Shared, because a C function pointer cannot capture.
final class PreviousHandlerLog: @unchecked Sendable {
    static let shared = PreviousHandlerLog()

    private let lock = NSLock()
    private var names: [String] = []

    func record(_ name: String) {
        lock.lock()
        names.append(name)
        lock.unlock()
    }

    func count(of name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return names.filter { $0 == name }.count
    }
}

/// Stands in for a crash reporter's handler installed before ours.
func recordPreviousHandler(_ exception: NSException) {
    PreviousHandlerLog.shared.record(exception.name.rawValue)
}

/// An uncaught-exception slot that is not the process's.
final class FakeHandlerSlot: UncaughtHandlerSlot, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: CExceptionHandler?
    private var sets = 0

    init(initial: CExceptionHandler? = nil) {
        handler = initial
    }

    func get() -> CExceptionHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    func set(_ handler: CExceptionHandler?) {
        lock.lock()
        self.handler = handler
        sets += 1
        lock.unlock()
    }

    var setCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sets
    }
}

/// Stands in for the URLSession data task: records each request and finishes
/// it at once, finishes it as a failure, or never finishes it.
final class RequestRecorder: @unchecked Sendable {
    enum Mode {
        case succeed
        case failImmediately
        case neverComplete
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let mode: Mode

    init(mode: Mode = .succeed) {
        self.mode = mode
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    var payloads: [TracklessEventPayload] {
        requests.compactMap { request in
            request.httpBody.flatMap { try? JSONDecoder().decode(TracklessEventPayload.self, from: $0) }
        }
    }

    var sender: UncaughtExceptionCapture.Sender {
        { [self] request, completion in
            lock.lock()
            _requests.append(request)
            lock.unlock()
            switch mode {
            case .succeed, .failImmediately:
                // The capture does nothing different on failure: it waits for
                // the completion or the cap, whichever is first.
                completion()
            case .neverComplete:
                break
            }
        }
    }
}
