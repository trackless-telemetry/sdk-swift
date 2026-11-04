import Foundation
import Testing

@testable import TracklessTelemetry

/// `startTimer` / `stopTimer` / `cancelTimer` and `measure`.
///
/// Every test drives a `FakeClock` and a private `NotificationCenter`, and
/// awaits the task a stop returns before reading the buffer back.
@Suite("Timers")
struct TimerTests {

    private func makeState(clock: FakeClock) -> TracklessState {
        TracklessState(
            clock: clock,
            notificationCenter: NotificationCenter(),
            transport: TransportRecorder().transport
        )
    }

    private func config(
        apiKey: String = "tl_0123456789abcdef0123456789abcdef",
        onError: (@Sendable (Error) -> Void)? = nil
    ) -> TracklessConfig {
        TracklessConfig(
            apiKey: apiKey,
            endpoint: "https://ingest.test",
            environment: .production,
            onError: onError,
            flushIntervalSeconds: 3600
        )
    }

    private func configuredState(
        clock: FakeClock,
        warnings: WarningRecorder? = nil,
        onError: (@Sendable (Error) -> Void)? = nil
    ) async -> TracklessState {
        let state = makeState(clock: clock)
        if let warnings {
            await state.setOnWarningForTesting { warnings.record($0) }
        }
        await state.configure(config(onError: onError))
        return state
    }

    private func performanceEvents(_ state: TracklessState) async -> [TracklessEvent] {
        await state.drainBufferForTesting().filter { $0.type == .performance }
    }

    // MARK: - Start and stop

    @Test("stopTimer sends the elapsed time and threshold as a performance measurement")
    func stopSendsPerformance() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        state.startTimer("checkout")
        clock.advance(1.5)
        await state.stopTimer("checkout", thresholdSeconds: 2.0)?.value

        let events = await performanceEvents(state)
        #expect(events.count == 1)
        #expect(events.first?.name == "checkout")
        #expect(events.first?.durations == [1.5])
        #expect(events.first?.threshold == 2.0)
    }

    @Test("The name is normalized at start, so a differently written stop closes it")
    func normalizedNameMatches() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        state.startTimer("Checkout Flow")
        clock.advance(3)
        await state.stopTimer("checkout_flow")?.value

        let events = await performanceEvents(state)
        #expect(events.map(\.name) == ["checkout_flow"])
        #expect(events.first?.durations == [3])
        #expect(state.timers.count == 0)
    }

    @Test("stopTimer with no open timer sends nothing")
    func stopWithoutStartIsNoOp() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        #expect(state.stopTimer("never_started") == nil)
        state.startTimer("once")
        await state.stopTimer("once")?.value
        #expect(state.stopTimer("once") == nil)

        let events = await performanceEvents(state)
        #expect(events.count == 1)
        #expect(events.first?.durations?.count == 1)
    }

    @Test("cancelTimer drops the timer and sends nothing")
    func cancelSendsNothing() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        state.startTimer("upload")
        clock.advance(2)
        state.cancelTimer("Upload")

        #expect(state.stopTimer("upload") == nil)
        #expect(await performanceEvents(state).isEmpty)
    }

    @Test("Starting an open name again restarts it")
    func restartResetsStart() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        state.startTimer("search")
        clock.advance(10)
        state.startTimer("search")
        clock.advance(4)
        await state.stopTimer("search")?.value

        let events = await performanceEvents(state)
        #expect(events.first?.durations == [4])
        #expect(state.timers.count == 0)
    }

    // MARK: - Cap

    @Test("At most 50 timers are open; a start past the cap is ignored with one warning")
    func capIgnoresAndWarnsOnce() async {
        let clock = FakeClock()
        let warnings = WarningRecorder()
        let state = await configuredState(clock: clock, warnings: warnings)

        for index in 0..<OpenTimers.maxOpen {
            #expect(state.startTimer("timer_\(index)") == nil)
        }
        await state.startTimer("one_too_many")?.value
        #expect(state.startTimer("two_too_many") == nil)
        #expect(state.timers.count == OpenTimers.maxOpen)

        let capWarnings = warnings.messages.filter { $0.contains("timers are already open") }
        #expect(capWarnings.count == 1)
        #expect(state.stopTimer("one_too_many") == nil)

        // Restarting a name that is already open is not a new timer.
        #expect(state.startTimer("timer_0") == nil)
        #expect(state.timers.count == OpenTimers.maxOpen)
    }

    @Test("The cap warning re-arms after the session ends")
    func capWarningRearmsPerSession() async {
        let clock = FakeClock()
        let warnings = WarningRecorder()
        let state = await configuredState(clock: clock, warnings: warnings)

        for index in 0...OpenTimers.maxOpen { await state.startTimer("timer_\(index)")?.value }
        await state.endSessionForTesting()
        await state.startSessionForTesting()
        for index in 0...OpenTimers.maxOpen { await state.startTimer("timer_\(index)")?.value }

        #expect(warnings.messages.filter { $0.contains("timers are already open") }.count == 2)
    }

    // MARK: - Session end

    @Test("Session end discards every open timer")
    func sessionEndDiscards() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        state.startTimer("checkout")
        state.startTimer("search")
        await state.endSessionForTesting()
        await state.startSessionForTesting()

        #expect(state.timers.count == 0)
        #expect(state.stopTimer("checkout") == nil)
        #expect(state.stopTimer("search") == nil)
        #expect(await performanceEvents(state).isEmpty)
    }

    @Test("Background (iOS) ends the session and discards open timers")
    func backgroundDiscards() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        state.startTimer("checkout")
        await state.handleAppDidEnterBackground(at: clock.now)
        await state.handleAppDidBecomeActive(at: clock.now.addingTimeInterval(1))

        #expect(state.stopTimer("checkout") == nil)
    }

    @Test("setEnabled(false) discards open timers")
    func disableDiscards() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        state.startTimer("checkout")
        await state.setEnabled(false)
        await state.setEnabled(true)

        #expect(state.stopTimer("checkout") == nil)
    }

    @Test("A reconfigure with changed settings discards open timers; identical settings keep them")
    func reconfigureDiscardsOnlyOnChange() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        state.startTimer("kept")
        await state.configure(config())
        #expect(state.timers.count == 1)

        await state.configure(config(apiKey: "tl_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
        #expect(state.stopTimer("kept") == nil)
    }

    @Test("A timer started after configure() was called survives that reconfigure")
    func cutoffKeepsLaterStarts() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        state.startTimer("before")
        // What `Trackless.configure` captures on the caller's thread before its task runs.
        let cutoff = state.timers.currentSequence
        state.startTimer("after")
        await state.configure(config(apiKey: "tl_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), timerCutoff: cutoff)

        #expect(state.stopTimer("before") == nil)
        clock.advance(1)
        await state.stopTimer("after")?.value
        #expect(await performanceEvents(state).map(\.name) == ["after"])
    }

    @Test("destroy() discards open timers")
    func destroyDiscards() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        state.startTimer("checkout")
        await state.destroy()
        #expect(state.timers.count == 0)
    }

    // MARK: - Elapsed bounds

    @Test("A negative elapsed time (clock moved back) is dropped with a warning")
    func negativeElapsedDropped() async {
        let clock = FakeClock()
        let warnings = WarningRecorder()
        let state = await configuredState(clock: clock, warnings: warnings)

        state.startTimer("checkout")
        clock.jump(by: -5)
        await state.stopTimer("checkout")?.value

        #expect(await performanceEvents(state).isEmpty)
        #expect(warnings.messages.contains { $0.contains("checkout") && $0.contains("outside") })
    }

    @Test("An elapsed time over a day is dropped; exactly a day is kept")
    func overADayDropped() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        state.startTimer("too_long")
        clock.advance(OpenTimers.maxElapsedSeconds + 1)
        await state.stopTimer("too_long")?.value
        #expect(await performanceEvents(state).isEmpty)

        state.startTimer("a_day")
        clock.advance(OpenTimers.maxElapsedSeconds)
        await state.stopTimer("a_day")?.value
        #expect(await performanceEvents(state).first?.durations == [OpenTimers.maxElapsedSeconds])
    }

    // MARK: - Invalid names

    @Test("A name normalization rejects is ignored with the usual warning and onError")
    func invalidNameRejected() async {
        let clock = FakeClock()
        let warnings = WarningRecorder()
        let errors = ErrorRecorder()
        let state = await configuredState(clock: clock, warnings: warnings, onError: { errors.record($0) })

        await state.startTimer("日本語")?.value
        #expect(state.timers.count == 0)
        #expect(state.stopTimer("日本語") == nil)
        state.cancelTimer("日本語")

        #expect(warnings.messages.filter { $0.contains("event name rejected") }.count == 1)
        #expect(errors.errors.count == 1)
    }

    @Test("A timer stopped while the SDK is not recording sends nothing")
    func stopWhileDisabledSendsNothing() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)
        await state.setEnabled(false)

        state.startTimer("checkout")
        clock.advance(1)
        await state.stopTimer("checkout")?.value
        #expect(await state.bufferSizeForTesting() == 0)
    }

    // MARK: - measure

    @Test("measure (sync) returns the body's value and sends its duration")
    func measureSyncSends() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        var send: Task<Void, Never>?
        let value = Trackless.measure(on: state, "Parse CSV", thresholdSeconds: 0.5, onSend: { send = $0 }) {
            clock.advance(0.25)
            return 42
        }
        await send?.value

        #expect(value == 42)
        let events = await performanceEvents(state)
        #expect(events.first?.name == "parse_csv")
        #expect(events.first?.durations == [0.25])
        #expect(events.first?.threshold == 0.5)
        #expect(state.timers.count == 0)
    }

    @Test("measure (sync) sends nothing when the body throws, and rethrows")
    func measureSyncThrowSendsNothing() async {
        struct Boom: Error {}
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        var sendCalled = false
        #expect(throws: Boom.self) {
            try Trackless.measure(on: state, "parse", thresholdSeconds: nil, onSend: { _ in sendCalled = true }) {
                throw Boom()
            }
        }
        #expect(!sendCalled)
        #expect(await performanceEvents(state).isEmpty)
    }

    @Test("measure (async) awaits the body and sends its duration")
    func measureAsyncSends() async throws {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        var send: Task<Void, Never>?
        let value = try await Trackless.measure(on: state, "feed_load", thresholdSeconds: 2.0, onSend: { send = $0 }) {
            try await Task.sleep(nanoseconds: 1_000)
            clock.advance(1.25)
            return "feed"
        }
        await send?.value

        #expect(value == "feed")
        let events = await performanceEvents(state)
        #expect(events.first?.name == "feed_load")
        #expect(events.first?.durations == [1.25])
    }

    @Test("measure (async) sends nothing when the session ends while the body runs")
    func measureAcrossSessionEndSendsNothing() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        var send: Task<Void, Never>? = Task {}
        await Trackless.measure(on: state, "feed_load", thresholdSeconds: nil, onSend: { send = $0 }) {
            await state.endSessionForTesting()
            clock.advance(1)
        }
        #expect(send == nil)
        #expect(await performanceEvents(state).isEmpty)
    }

    @Test("measure does not count toward the open-timer cap")
    func measureIgnoresCap() async {
        let clock = FakeClock()
        let state = await configuredState(clock: clock)

        for index in 0..<OpenTimers.maxOpen { state.startTimer("timer_\(index)") }
        var send: Task<Void, Never>?
        Trackless.measure(on: state, "nested", thresholdSeconds: nil, onSend: { send = $0 }) {
            clock.advance(1)
        }
        await send?.value
        #expect(await performanceEvents(state).map(\.name) == ["nested"])
    }
}
