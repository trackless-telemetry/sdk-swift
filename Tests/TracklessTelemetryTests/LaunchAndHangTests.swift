import Foundation
import Testing
#if os(macOS)
import AppKit
#endif

@testable import TracklessTelemetry

/// `measureLaunch`, `detectHangs`, the reserved `trackless.` prefix, and the
/// session-end timer cutoff.
///
/// Nothing here sleeps for real or touches the real main queue: the state gets
/// a `FakeClock`, a private `NotificationCenter`, a hand-set "is the app
/// active" answer, a `ManualMainQueue` and a ticker that never fires on its
/// own, so a test decides exactly when the watchdog ticks and when the main
/// thread is free.
@Suite("Launch time and hangs")
struct LaunchAndHangTests {

    // MARK: - Fixtures

    private let apiKey = "tl_0123456789abcdef0123456789abcdef"

    private func makeState(
        clock: FakeClock,
        center: NotificationCenter = NotificationCenter(),
        active: ActiveFlag = ActiveFlag(false),
        main: ManualMainQueue = ManualMainQueue()
    ) -> TracklessState {
        TracklessState(
            clock: clock,
            notificationCenter: center,
            transport: TransportRecorder().transport,
            appIsActive: { active.value },
            postToMain: main.scheduler,
            hangTicker: { _, _ in {} }
        )
    }

    private func config(
        apiKey: String? = nil,
        enabled: Bool = true,
        measureLaunch: Bool = false,
        launchThresholdSeconds: Double? = nil,
        detectHangs: Bool = false
    ) -> TracklessConfig {
        TracklessConfig(
            apiKey: apiKey ?? self.apiKey,
            endpoint: "https://ingest.test",
            environment: .production,
            enabled: enabled,
            flushIntervalSeconds: 3600,
            measureLaunch: measureLaunch,
            launchThresholdSeconds: launchThresholdSeconds,
            detectHangs: detectHangs
        )
    }

    /// What `Trackless.configure` does: arm the probe synchronously, then run
    /// the configuration on the actor.
    private func configure(_ state: TracklessState, _ config: TracklessConfig) async {
        if config.measureLaunch { state.armLaunch() }
        await state.configure(config)
    }

    private func activate(_ center: NotificationCenter) {
        center.post(name: AppActivity.didBecomeActive!, object: nil)
    }

    private func performanceEvents(_ state: TracklessState) async -> [TracklessEvent] {
        await state.drainBufferForTesting().filter { $0.type == .performance }
    }

    /// Wait until a task hops onto the actor and buffers something.
    private func waitForBuffer(_ state: TracklessState, atLeast count: Int = 1) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await state.bufferSizeForTesting() >= count { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }

    // MARK: - Launch: opt-in

    @Test("measureLaunch off: an activation sends nothing")
    func launchOffSendsNothing() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let state = makeState(clock: clock, center: center)
        await configure(state, config())

        clock.advance(1)
        activate(center)
        await state.deliverLaunch()

        #expect(!state.launch.isWaiting)
        #expect(await performanceEvents(state).isEmpty)
    }

    @Test("Launch time runs from configure() to the first activation, sent once per process")
    func launchSentOnce() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let state = makeState(clock: clock, center: center)
        await configure(state, config(measureLaunch: true))
        _ = await state.drainBufferForTesting()

        clock.advance(1.5)
        activate(center)
        await state.deliverLaunch()

        let events = await performanceEvents(state)
        #expect(events.map(\.name) == [Trackless.launchMetricName])
        #expect(events.first?.durations == [1.5])
        #expect(events.first?.threshold == nil)

        // Later activations, a reconfigure and a destroy + configure: never again.
        clock.advance(5)
        activate(center)
        await configure(state, config(apiKey: "tl_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", measureLaunch: true))
        await state.destroy()
        await configure(state, config(measureLaunch: true))
        clock.advance(1)
        activate(center)
        await state.deliverLaunch()
        #expect(await performanceEvents(state).isEmpty)
    }

    @Test("launchThresholdSeconds is sent as the launch metric's threshold")
    func launchThresholdPassedThrough() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let state = makeState(clock: clock, center: center)
        await configure(state, config(measureLaunch: true, launchThresholdSeconds: 2.0))

        clock.advance(0.75)
        activate(center)
        await state.deliverLaunch()

        let events = await performanceEvents(state)
        #expect(events.first?.durations == [0.75])
        #expect(events.first?.threshold == 2.0)
    }

    @Test("A re-run configure() with the same settings does not restart the launch clock")
    func identicalReconfigureKeepsLaunchStart() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let state = makeState(clock: clock, center: center)
        await configure(state, config(measureLaunch: true))
        clock.advance(1)
        await configure(state, config(measureLaunch: true))
        clock.advance(0.5)
        activate(center)
        await state.deliverLaunch()

        #expect(await performanceEvents(state).first?.durations == [1.5])
    }

    @Test("Late configure (the app is already active) sends no launch time")
    func lateConfigureSendsNothing() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let state = makeState(clock: clock, center: center, active: ActiveFlag(true))
        await configure(state, config(measureLaunch: true))
        #expect(!state.launch.isWaiting)

        // The next activation is a return from the background, not a launch.
        clock.advance(30)
        activate(center)
        await state.deliverLaunch()
        #expect(await performanceEvents(state).isEmpty)
    }

    @Test("Late configure off the main thread is detected on the main queue")
    func lateConfigureOffMainThread() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let active = ActiveFlag(nil)  // off the main thread: unknown
        let main = ManualMainQueue()
        let state = makeState(clock: clock, center: center, active: active, main: main)
        await configure(state, config(measureLaunch: true))
        #expect(state.launch.isWaiting)

        // On the main queue the app turns out to be active already.
        active.value = true
        main.runAll()
        #expect(!state.launch.isWaiting)

        activate(center)
        await state.deliverLaunch()
        #expect(await performanceEvents(state).isEmpty)
    }

    @Test("Off the main thread, an activation that comes first still measures")
    func offMainActivationFirstMeasures() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let active = ActiveFlag(nil)
        let main = ManualMainQueue()
        let state = makeState(clock: clock, center: center, active: active, main: main)
        await configure(state, config(measureLaunch: true))

        clock.advance(2)
        activate(center)  // the observer was in place before the main-queue re-read
        active.value = true
        main.runAll()
        await state.deliverLaunch()

        #expect(await performanceEvents(state).first?.durations == [2])
    }

    @Test("A launch measured before the configure task ran is delivered by it")
    func launchBeforeConfigureTaskIsDelivered() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let state = makeState(clock: clock, center: center)

        // `Trackless.configure` armed the probe; the activation's task wins the
        // race to the actor and finds nothing configured yet.
        state.armLaunch()
        clock.advance(1.25)
        activate(center)
        await state.deliverLaunch()

        await state.configure(config(measureLaunch: true))
        let events = await performanceEvents(state)
        #expect(events.map(\.name) == [Trackless.launchMetricName])
        #expect(events.first?.durations == [1.25])
    }

    @Test("A launch measured while recording is disabled is not sent, even after re-enabling")
    func launchWhileDisabledNotSent() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let state = makeState(clock: clock, center: center)
        await configure(state, config(enabled: false, measureLaunch: true))

        clock.advance(1)
        activate(center)
        await state.deliverLaunch()
        await state.setEnabled(true)
        await state.deliverLaunch()

        #expect(await performanceEvents(state).isEmpty)
    }

    @Test("A reconfigure that turns measureLaunch off drops a pending launch")
    func launchTurnedOffBeforeActivation() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let state = makeState(clock: clock, center: center)
        await configure(state, config(measureLaunch: true))
        await configure(state, config(measureLaunch: false))

        clock.advance(1)
        activate(center)
        await state.deliverLaunch()
        #expect(await performanceEvents(state).isEmpty)
    }

    @Test("A launch time outside 0 to 86,400 seconds is dropped")
    func launchOutOfRangeDropped() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let state = makeState(clock: clock, center: center)
        await configure(state, config(measureLaunch: true))

        clock.jump(by: -5)
        activate(center)
        await state.deliverLaunch()
        #expect(await performanceEvents(state).isEmpty)
    }

    @Test("A launch of exactly 60 seconds is sent")
    func launchAtCapSent() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let state = makeState(clock: clock, center: center)
        await configure(state, config(measureLaunch: true))

        clock.advance(60)
        activate(center)
        await state.deliverLaunch()
        #expect(await performanceEvents(state).first?.durations == [60])
    }

    @Test("A launch longer than 60 seconds is dropped, not clipped, and the probe finishes")
    func launchOverCapDropped() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let state = makeState(clock: clock, center: center)
        await configure(state, config(measureLaunch: true))

        clock.advance(60.001)
        activate(center)
        await state.deliverLaunch()
        #expect(!state.launch.isWaiting)
        #expect(await performanceEvents(state).isEmpty)

        // A later activation is not measured instead.
        clock.advance(1)
        activate(center)
        await state.deliverLaunch()
        #expect(await performanceEvents(state).isEmpty)
    }

    @Test("SDK metrics leave the session's depth alone")
    func launchDoesNotCountAsActivity() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let state = makeState(clock: clock, center: center)
        await configure(state, config(measureLaunch: true))

        clock.advance(1)
        activate(center)
        await state.deliverLaunch()
        await state.recordHang(0.5)  // detectHangs off: dropped
        await state.endSessionForTesting()

        let events = await state.drainBufferForTesting()
        let end = events.first { $0.type == .session && $0.name == "end" }
        #expect(end?.stepIndex == 0)
        #expect(events.filter { $0.type == .performance }.map(\.name) == [Trackless.launchMetricName])
    }

    @Test("Turning measureLaunch or detectHangs on counts as changed settings")
    func optionsAreSettings() async {
        let clock = FakeClock()
        let state = makeState(clock: clock)
        await configure(state, config())

        state.startTimer("open")
        await configure(state, config(detectHangs: true))
        #expect(state.stopTimer("open") == nil)

        state.startTimer("open")
        await configure(state, config(measureLaunch: true, detectHangs: true))
        #expect(state.stopTimer("open") == nil)

        state.startTimer("open")
        await configure(state, config(measureLaunch: true, detectHangs: true))
        #expect(state.timers.count == 1)
    }

    // MARK: - Hangs: watchdog unit

    @Test("Watchdog: a main thread blocked for 250 ms or more reports one hang on recovery")
    func watchdogReportsHang() {
        let clock = FakeClock()
        let main = ManualMainQueue()
        let watchdog = HangWatchdog(clock: clock, postToMain: main.scheduler, ticker: { _, _ in {} })
        let hangs = HangRecorder()
        watchdog.enable { hangs.record($0) }
        watchdog.appBecameActive()

        watchdog.tick()
        #expect(main.count == 1)
        clock.advance(0.5)
        watchdog.tick()  // still outstanding: no second ping
        clock.advance(0.5)
        watchdog.tick()
        #expect(main.count == 1)

        main.runAll()  // the main thread recovers
        #expect(hangs.values == [1.0])
    }

    @Test("Watchdog: a wait under 250 ms is not a hang")
    func watchdogIgnoresShortWait() {
        let clock = FakeClock()
        let main = ManualMainQueue()
        let watchdog = HangWatchdog(clock: clock, postToMain: main.scheduler, ticker: { _, _ in {} })
        let hangs = HangRecorder()
        watchdog.enable { hangs.record($0) }
        watchdog.appBecameActive()

        watchdog.tick()
        clock.advance(0.125)
        main.runAll()
        watchdog.tick()
        clock.advance(0.25)
        main.runAll()

        #expect(hangs.values == [0.25])
    }

    @Test("Watchdog: stops at resign-active, settling a hang the user left during, and restarts")
    func watchdogStopsAndRestarts() {
        let clock = FakeClock()
        let main = ManualMainQueue()
        let ticks = TickerRecorder()
        let watchdog = HangWatchdog(clock: clock, postToMain: main.scheduler, ticker: ticks.ticker)
        let hangs = HangRecorder()
        watchdog.enable { hangs.record($0) }

        watchdog.appBecameActive()
        #expect(watchdog.isRunning)
        #expect(ticks.started == 1)
        watchdog.tick()
        clock.advance(1)
        watchdog.appResignedActive()  // on the main thread, so it has recovered
        #expect(hangs.values == [1.0])
        #expect(!watchdog.isRunning)
        #expect(ticks.cancelled == 1)

        main.runAll()  // the stale ping does not report twice
        watchdog.tick()  // not running: posts nothing
        #expect(main.count == 0)
        #expect(hangs.values == [1.0])

        watchdog.appBecameActive()
        #expect(watchdog.isRunning)
        #expect(ticks.started == 2)
    }

    @Test("Watchdog: does not start until enabled, and disable stops it")
    func watchdogEnableDisable() {
        let clock = FakeClock()
        let main = ManualMainQueue()
        let watchdog = HangWatchdog(clock: clock, postToMain: main.scheduler, ticker: { _, _ in {} })

        watchdog.appBecameActive()
        #expect(!watchdog.isRunning)

        watchdog.enable { _ in }
        watchdog.appBecameActive()
        #expect(watchdog.isRunning)
        watchdog.disable()
        #expect(!watchdog.isRunning)
        #expect(!watchdog.isEnabled)
    }

    // MARK: - Hangs: through the SDK

    @Test("detectHangs off: the watchdog never runs")
    func hangsOffNeverRuns() async {
        let clock = FakeClock()
        let state = makeState(clock: clock, active: ActiveFlag(true))
        await configure(state, config())

        state.hangs.appBecameActive()
        #expect(!state.hangs.isRunning)
        await state.recordHang(1)
        #expect(await performanceEvents(state).isEmpty)
    }

    @Test("detectHangs: a hang is sent as trackless.hang with no threshold")
    func hangSent() async {
        let clock = FakeClock()
        let main = ManualMainQueue()
        let state = makeState(clock: clock, active: ActiveFlag(true), main: main)
        await configure(state, config(detectHangs: true))
        _ = await state.drainBufferForTesting()
        #expect(state.hangs.isRunning)

        state.hangs.tick()
        clock.advance(0.75)
        main.runAll()
        #expect(await waitForBuffer(state))

        let events = await performanceEvents(state)
        #expect(events.map(\.name) == [Trackless.hangMetricName])
        #expect(events.first?.durations == [0.75])
        #expect(events.first?.threshold == nil)
    }

    @Test("detectHangs: configure while inactive waits for the activation to start the watchdog")
    func hangsWaitForActivation() async {
        let clock = FakeClock()
        let state = makeState(clock: clock, active: ActiveFlag(false))
        await configure(state, config(detectHangs: true))
        #expect(!state.hangs.isRunning)

        state.hangs.appBecameActive()
        #expect(state.hangs.isRunning)
    }

    @Test("detectHangs: off the main thread, the watchdog starts from the main queue")
    func hangsStartFromMainQueue() async {
        let clock = FakeClock()
        let active = ActiveFlag(nil)
        let main = ManualMainQueue()
        let state = makeState(clock: clock, active: active, main: main)
        await configure(state, config(detectHangs: true))
        #expect(!state.hangs.isRunning)

        active.value = true
        main.runAll()
        #expect(state.hangs.isRunning)
    }

    @Test("detectHangs: setEnabled(false), a reconfigure without it and destroy() stop the watchdog")
    func hangsStopWithTheSDK() async {
        let clock = FakeClock()
        let state = makeState(clock: clock, active: ActiveFlag(true))

        await configure(state, config(detectHangs: true))
        await state.setEnabled(false)
        #expect(!state.hangs.isRunning)
        await state.setEnabled(true)
        #expect(state.hangs.isRunning)

        await configure(state, config(apiKey: "tl_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
        #expect(!state.hangs.isRunning)

        await configure(state, config(detectHangs: true))
        #expect(state.hangs.isRunning)
        await state.destroy()
        #expect(!state.hangs.isRunning)
    }

    @Test("A hang reported while recording is disabled is not sent")
    func hangWhileDisabledNotSent() async {
        let clock = FakeClock()
        let state = makeState(clock: clock, active: ActiveFlag(true))
        await configure(state, config(detectHangs: true))
        await state.setEnabled(false)
        await state.recordHang(1)
        #expect(await state.bufferSizeForTesting() == 0)
    }

    #if os(macOS)
    @Test("macOS: resign-active stops the watchdog and become-active restarts it")
    func macOSNotificationsDriveTheWatchdog() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let state = makeState(clock: clock, center: center, active: ActiveFlag(true))
        await configure(state, config(detectHangs: true))
        #expect(state.hangs.isRunning)

        center.post(name: NSApplicationNotifications.didResignActive, object: nil)
        #expect(!state.hangs.isRunning)
        center.post(name: NSApplicationNotifications.didBecomeActive, object: nil)
        #expect(state.hangs.isRunning)

        await state.setEnabled(false)
    }
    #endif

    // MARK: - Reserved prefix

    @Test("performance() warns once per process for a trackless. name, and sends it")
    func reservedPrefixWarnsOnce() async {
        let clock = FakeClock()
        let warnings = WarningRecorder()
        let state = makeState(clock: clock)
        await state.setOnWarningForTesting { warnings.record($0) }
        await configure(state, config())

        await state.recordPerformance(name: "Trackless.Custom", durationSeconds: 1)
        await state.recordPerformance(name: "trackless.other", durationSeconds: 1)
        await state.startTimer("trackless.timer")?.value
        await state.recordPerformance(name: "not_reserved", durationSeconds: 1)

        let reserved = warnings.messages.filter { $0.contains("reserved") }
        #expect(reserved.count == 1)
        #expect(reserved.first?.contains("trackless.custom") == true)
        let names = await performanceEvents(state).map(\.name).sorted()
        #expect(names == ["not_reserved", "trackless.custom", "trackless.other"])
    }

    @Test("startTimer and measure warn for a trackless. name too")
    func reservedPrefixTimerAndMeasure() async {
        let clock = FakeClock()
        let timerWarnings = WarningRecorder()
        let timerState = makeState(clock: clock)
        await timerState.setOnWarningForTesting { timerWarnings.record($0) }
        await configure(timerState, config())
        await timerState.startTimer("trackless.checkout")?.value
        #expect(timerWarnings.messages.filter { $0.contains("reserved") }.count == 1)

        let measureWarnings = WarningRecorder()
        let measureState = makeState(clock: clock)
        await measureState.setOnWarningForTesting { measureWarnings.record($0) }
        await configure(measureState, config())
        var send: Task<Void, Never>?
        Trackless.measure(on: measureState, "trackless.parse", thresholdSeconds: nil, onSend: { send = $0 }) {
            clock.advance(0.5)
        }
        await send?.value
        #expect(measureWarnings.messages.filter { $0.contains("reserved") }.count == 1)
        #expect(await performanceEvents(measureState).map(\.name) == ["trackless.parse"])
    }

    @Test("The SDK's own launch and hang sends do not trigger the reserved-prefix warning")
    func sdkSendsDoNotWarn() async {
        let clock = FakeClock()
        let center = NotificationCenter()
        let warnings = WarningRecorder()
        let state = makeState(clock: clock, center: center, active: ActiveFlag(false))
        await state.setOnWarningForTesting { warnings.record($0) }
        await configure(state, config(measureLaunch: true, detectHangs: true))

        clock.advance(1)
        activate(center)
        await state.deliverLaunch()
        await state.recordHang(0.5)

        #expect(await performanceEvents(state).count == 2)
        #expect(warnings.messages.filter { $0.contains("reserved") }.isEmpty)

        // The once-per-process warning is still there for a developer's name.
        await state.recordPerformance(name: "trackless.mine", durationSeconds: 1)
        #expect(warnings.messages.filter { $0.contains("reserved") }.count == 1)
    }

    // MARK: - Session-end timer cutoff

    @Test("Background: only timers started before the notification are discarded")
    func backgroundCutoffKeepsLaterTimers() async {
        let clock = FakeClock()
        let state = makeState(clock: clock)
        await configure(state, config())

        state.startTimer("before")
        // What the didEnterBackground block captures, before its task runs.
        let cutoff = state.timers.currentSequence
        // The app returns and starts a timer before that task reaches the actor.
        state.startTimer("after")
        await state.handleAppDidEnterBackground(at: clock.now, timerCutoff: cutoff)

        #expect(state.stopTimer("before") == nil)
        clock.advance(1)
        await state.stopTimer("after")?.value
        #expect(await performanceEvents(state).map(\.name) == ["after"])
    }

    @Test("macOS idle timeout: only timers started before the timer fired are discarded")
    func idleTimeoutCutoffKeepsLaterTimers() async {
        let clock = FakeClock()
        let state = makeState(clock: clock)
        await configure(state, config())

        state.startTimer("before")
        await state.handleAppDidResignActive(at: clock.now)
        clock.advance(400)
        let cutoff = state.timers.currentSequence  // read in the idle timer's handler
        state.startTimer("after")
        await state.handleIdleTimeout(timerCutoff: cutoff)

        #expect(state.stopTimer("before") == nil)
        #expect(state.timers.count == 1)
    }

    @Test("macOS activation past the idle window: only timers started before it are discarded")
    func lateActivationCutoffKeepsLaterTimers() async {
        let clock = FakeClock()
        let state = makeState(clock: clock)
        await configure(state, config())

        state.startTimer("before")
        await state.handleAppDidResignActive(at: clock.now)
        clock.advance(400)
        let stamp = clock.now
        let cutoff = state.timers.currentSequence  // read in the become-active block
        state.startTimer("after")
        await state.handleAppDidBecomeActive(at: stamp, timerCutoff: cutoff)

        #expect(state.stopTimer("before") == nil)
        #expect(state.timers.count == 1)
    }
}

// MARK: - Test Helpers

#if os(macOS)
/// AppKit's notification names, without importing AppKit into every test.
enum NSApplicationNotifications {
    static let didResignActive = NSApplication.didResignActiveNotification
    static let didBecomeActive = NSApplication.didBecomeActiveNotification
}
#endif

/// A settable answer for `appIsActive`; nil stands for "called off the main thread".
final class ActiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    init(_ value: Bool?) {
        stored = value
    }

    var value: Bool? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// A main queue the test drains by hand: what is queued runs only at `runAll()`.
final class ManualMainQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [@Sendable () -> Void] = []

    var scheduler: HangWatchdog.MainScheduler {
        { [self] block in
            lock.lock()
            blocks.append(block)
            lock.unlock()
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return blocks.count
    }

    func runAll() {
        while true {
            lock.lock()
            guard !blocks.isEmpty else {
                lock.unlock()
                return
            }
            let block = blocks.removeFirst()
            lock.unlock()
            block()
        }
    }
}

final class HangRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimeInterval] = []

    var values: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ value: TimeInterval) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }
}

/// Counts ticker starts and cancels; never ticks on its own.
final class TickerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var cancels = 0

    var started: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var cancelled: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancels
    }

    var ticker: HangWatchdog.Ticker {
        { [self] _, _ in
            lock.lock()
            starts += 1
            lock.unlock()
            return { [self] in
                lock.lock()
                cancels += 1
                lock.unlock()
            }
        }
    }
}
