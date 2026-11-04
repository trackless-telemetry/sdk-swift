import Foundation

/// The main-thread watchdog behind `detectHangs`.
///
/// Every `intervalSeconds` a background tick posts a no-op to the main queue
/// and records when it did. When the main queue runs it, the wait is measured;
/// a wait of `thresholdSeconds` (250 ms, Apple's definition of a hang) or more
/// is reported once, when the main thread has recovered, as one
/// `trackless.hang` sample of that many seconds. While a ping is outstanding no
/// other is posted, so a long hang costs one ping, not one per tick.
///
/// **Only while the app is active.** `appBecameActive()` starts the ticks and
/// `appResignedActive()` stops them, so an app that is not on screen takes no
/// wake-ups from this. Both are called from lifecycle notifications on the main
/// thread.
///
/// **Never blocks the main thread.** The tick runs on a private utility queue;
/// the main thread only runs the posted no-op, which takes a lock for a few
/// field reads. Nothing here throws.
///
/// **Clock.** The same wall clock as the session and timers (`Date()` in
/// production): a monotonic clock on Apple platforms is a required-reason
/// boot-time API, and the SDK reads none. A clock that jumps during a hang can
/// distort one sample; the state actor drops anything outside `0...1 day`.
///
/// Scheduling is injected so tests drive ticks and the main queue by hand.
final class HangWatchdog: @unchecked Sendable {

    /// Runs a block on the main queue.
    typealias MainScheduler = @Sendable (@escaping @Sendable () -> Void) -> Void

    /// Starts a repeating tick every `interval` seconds and returns its cancel.
    typealias Ticker = @Sendable (
        _ interval: TimeInterval,
        _ tick: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void

    /// A main-thread wait at or above this is a hang. Apple's definition.
    static let thresholdSeconds: TimeInterval = 0.25

    /// How often the watchdog pings the main queue.
    static let intervalSeconds: TimeInterval = 0.25

    /// Production main scheduler.
    static let mainQueue: MainScheduler = { DispatchQueue.main.async(execute: $0) }

    /// Production ticker: a `DispatchSourceTimer` on a private utility queue.
    static let dispatchTicker: Ticker = { interval, tick in
        let timer = DispatchSource.makeTimerSource(queue: tickQueue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler(handler: tick)
        let holder = TimerState()
        holder.setTimer(timer)
        timer.resume()
        return { holder.cancelTimer() }
    }

    private static let tickQueue = DispatchQueue(label: "com.trackless.sdk.hang-watchdog", qos: .utility)

    private let lock = NSLock()
    private let clock: TracklessClock
    private let postToMain: MainScheduler
    private let ticker: Ticker

    private var onHang: (@Sendable (TimeInterval) -> Void)?
    private var cancelTicks: (@Sendable () -> Void)?
    private var pingID: UInt64 = 0
    private var outstandingID: UInt64?
    private var outstandingSentAt: Date = .distantPast

    init(
        clock: TracklessClock,
        postToMain: @escaping MainScheduler = HangWatchdog.mainQueue,
        ticker: @escaping Ticker = HangWatchdog.dispatchTicker
    ) {
        self.clock = clock
        self.postToMain = postToMain
        self.ticker = ticker
    }

    /// Whether hang detection is switched on (`detectHangs` and recording).
    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onHang != nil
    }

    /// Whether the ticks are running (test support).
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelTicks != nil
    }

    /// Switch detection on. Ticks start only at the next `appBecameActive()`.
    func enable(onHang: @escaping @Sendable (TimeInterval) -> Void) {
        lock.lock()
        self.onHang = onHang
        lock.unlock()
    }

    /// Switch detection off and stop the ticks. An outstanding ping is dropped.
    func disable() {
        lock.lock()
        onHang = nil
        let cancel = stopLocked()
        lock.unlock()
        cancel?()
    }

    /// The app is active: start ticking, when detection is on and not already running.
    func appBecameActive() {
        lock.lock()
        guard onHang != nil, cancelTicks == nil else {
            lock.unlock()
            return
        }
        // A placeholder, so a concurrent call sees it running while the ticker
        // is created outside the lock.
        cancelTicks = {}
        lock.unlock()

        let cancel = ticker(Self.intervalSeconds) { [weak self] in self?.tick() }

        lock.lock()
        let stillWanted = onHang != nil && cancelTicks != nil
        if stillWanted { cancelTicks = cancel }
        lock.unlock()
        if !stillWanted { cancel() }
    }

    /// The app resigned active or entered the background: stop ticking.
    ///
    /// Called on the main thread, so the main thread is free right now: a ping
    /// still outstanding has finished waiting, and is settled — a hang the user
    /// left the app during is still counted.
    func appResignedActive() {
        lock.lock()
        let hang = settleLocked()
        let cancel = stopLocked()
        let handler = onHang
        lock.unlock()
        cancel?()
        if let hang { handler?(hang) }
    }

    /// One tick: post a ping unless one is still outstanding.
    func tick() {
        lock.lock()
        guard cancelTicks != nil, outstandingID == nil else {
            lock.unlock()
            return
        }
        pingID &+= 1
        let id = pingID
        outstandingID = id
        outstandingSentAt = clock.now
        lock.unlock()
        postToMain { [weak self] in self?.pong(id) }
    }

    /// The main queue ran ping `id`.
    private func pong(_ id: UInt64) {
        lock.lock()
        guard outstandingID == id else {
            lock.unlock()
            return
        }
        let hang = settleLocked()
        let handler = onHang
        lock.unlock()
        if let hang { handler?(hang) }
    }

    /// Close the outstanding ping, if any; its wait when that was a hang.
    private func settleLocked() -> TimeInterval? {
        guard outstandingID != nil else { return nil }
        outstandingID = nil
        let waited = clock.now.timeIntervalSince(outstandingSentAt)
        return waited >= Self.thresholdSeconds ? waited : nil
    }

    /// Stop ticking and drop the outstanding ping; the ticker's cancel, to be
    /// called outside the lock.
    private func stopLocked() -> (@Sendable () -> Void)? {
        outstandingID = nil
        let cancel = cancelTicks
        cancelTicks = nil
        return cancel
    }
}
