import Foundation
import Testing

@testable import TracklessTelemetry

/// The idle state machine, driven through the platform-neutral handlers.
///
/// Deliberately free of `#if`: these handlers are the same code on every
/// platform, and the AppKit notification names that reach them are pinned
/// separately in `MacOSLifecycleWiringTests`.
///
/// Every test drains the buffer immediately after `configure()`. That discards
/// the `session/start` event *and* makes each subsequent `performFlush()` return
/// at its `isEmpty` guard — so no test in this suite touches the network.
@Suite("Session idle state machine")
struct SessionIdleStateMachineTests {

    private func makeState(
        clock: FakeClock,
        idleTimeout: TimeInterval = 300,
        onWarning: (@Sendable (String) -> Void)? = nil
    ) async -> TracklessState {
        // A private NotificationCenter: observers registered by `configure()`
        // never reach `.default`, so a real system notification during a test
        // run cannot perturb it.
        let state = TracklessState(clock: clock, notificationCenter: NotificationCenter())
        if let onWarning {
            await state.setOnWarningForTesting(onWarning)
        }
        await state.configure(
            TracklessConfig(
                apiKey: "tl_test",
                endpoint: "http://127.0.0.1:9",
                environment: .sandbox,
                flushIntervalSeconds: 3600,
                suppressWarnings: onWarning == nil,
                sessionIdleTimeoutSeconds: idleTimeout
            )
        )
        _ = await state.drainBufferForTesting()
        return state
    }

    private func sessionEvent(in events: [TracklessEvent], named name: String) -> TracklessEvent? {
        events.first(where: { $0.type == .session && $0.name == name })
    }

    // MARK: - Resign

    @Test("Resign opens the idle window without ending the session or buffering an event")
    func resignArmsWithoutEnding() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(100)
        await state.handleAppDidResignActive(at: clock.now)

        #expect(await state.isSessionActiveForTesting())
        #expect(await state.isSessionMarkedInactiveForTesting())
        #expect(await state.idleDeadlineForTesting() == FakeClock.base.addingTimeInterval(400))
        #expect(await state.hasIdleTimerForTesting())
        #expect(await state.drainBufferForTesting().isEmpty)

        await state.setEnabled(false)
    }

    @Test("A repeated resign keeps the original truncation point")
    func repeatedResignKeepsFirstMark() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(100)
        await state.handleAppDidResignActive(at: clock.now)
        clock.advance(50)
        await state.handleAppDidResignActive(at: clock.now)

        await state.handleIdleTimeout()
        let end = sessionEvent(in: await state.drainBufferForTesting(), named: "end")
        #expect(end?.duration == 100)

        await state.setEnabled(false)
    }

    /// The repeat must not move the deadline either. Resigning at wall 100 and
    /// again at 150 with a 300s timeout leaves one boundary, at 400 — not 450.
    /// Becoming active at 420 therefore lands *past* it and restarts the
    /// session; if the second resign had re-armed, 420 would still be inside
    /// the window and the session would simply continue.
    @Test("A repeated resign does not extend the idle window")
    func repeatedResignKeepsFirstDeadline() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(100)
        await state.handleAppDidResignActive(at: clock.now)
        clock.advance(50)
        await state.handleAppDidResignActive(at: clock.now)

        clock.advance(270) // wall 420, past the first resign's 400 boundary
        await state.handleAppDidBecomeActive(at: clock.now)

        let events = await state.drainBufferForTesting()
        #expect(sessionEvent(in: events, named: "end")?.duration == 100)
        #expect(sessionEvent(in: events, named: "start") != nil)

        await state.setEnabled(false)
    }

    // MARK: - Reactivation

    @Test("Reactivation inside the window continues the session; the gap counts")
    func reactivationInsideWindowContinues() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(100)
        await state.handleAppDidResignActive(at: clock.now)

        clock.advance(60)
        await state.handleAppDidBecomeActive(at: clock.now)

        #expect(await state.isSessionActiveForTesting())
        #expect(await state.isSessionMarkedInactiveForTesting() == false)
        #expect(await state.idleDeadlineForTesting() == nil)
        #expect(await state.hasIdleTimerForTesting() == false)
        // No session boundary was crossed, so neither event was buffered.
        #expect(await state.drainBufferForTesting().isEmpty)

        clock.advance(40)
        await state.endSessionForTesting()
        let end = sessionEvent(in: await state.drainBufferForTesting(), named: "end")
        #expect(end?.duration == 200)

        await state.setEnabled(false)
    }

    /// The pinning test for the whole design.
    ///
    /// Start at 0, resign at 100, reactivate at 400 with a 300s timeout. The
    /// duration must be **100**: truncated at the resign, not extended to the
    /// timeout boundary (which would be 400) and not measured to the
    /// reactivation.
    @Test("Reactivation past the boundary ends at the resign point and restarts")
    func reactivationPastBoundaryTruncatesAtResign() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock, idleTimeout: 300)

        clock.advance(100)
        await state.handleAppDidResignActive(at: clock.now)

        // Reaches base+400 — exactly the deadline, which counts as past it.
        clock.advance(300)
        await state.handleAppDidBecomeActive(at: clock.now)

        let events = await state.drainBufferForTesting()
        let end = sessionEvent(in: events, named: "end")
        #expect(end?.duration == 100)
        #expect(sessionEvent(in: events, named: "start") != nil)
        #expect(await state.isSessionActiveForTesting())
        #expect(await state.idleDeadlineForTesting() == nil)
        #expect(await state.hasIdleTimerForTesting() == false)

        await state.setEnabled(false)
    }

    @Test("The new session after a boundary crossing measures from the reactivation")
    func newSessionStartsAtReactivation() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(100)
        await state.handleAppDidResignActive(at: clock.now)
        clock.advance(400)
        await state.handleAppDidBecomeActive(at: clock.now)
        _ = await state.drainBufferForTesting()

        clock.advance(25)
        await state.endSessionForTesting()
        let end = sessionEvent(in: await state.drainBufferForTesting(), named: "end")
        #expect(end?.duration == 25)

        await state.setEnabled(false)
    }

    // MARK: - Timeout

    @Test("The timeout ends the session and starts no new one")
    func timeoutEndsSession() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(100)
        await state.handleAppDidResignActive(at: clock.now)
        clock.advance(300)
        await state.handleIdleTimeout()

        let events = await state.drainBufferForTesting()
        #expect(sessionEvent(in: events, named: "end")?.duration == 100)
        #expect(sessionEvent(in: events, named: "start") == nil)
        #expect(await state.isSessionActiveForTesting() == false)
        #expect(await state.idleDeadlineForTesting() == nil)

        await state.setEnabled(false)
    }

    @Test("A second timeout cannot end the session twice")
    func doubleTimeoutEndsOnce() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(100)
        await state.handleAppDidResignActive(at: clock.now)
        await state.handleIdleTimeout()
        _ = await state.drainBufferForTesting()

        await state.handleIdleTimeout()
        #expect(await state.drainBufferForTesting().isEmpty)

        await state.setEnabled(false)
    }

    @Test("A timeout that fires after a reactivation does nothing")
    func timeoutAfterReactivationIsIgnored() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(100)
        await state.handleAppDidResignActive(at: clock.now)
        clock.advance(10)
        await state.handleAppDidBecomeActive(at: clock.now)

        await state.handleIdleTimeout()

        #expect(await state.isSessionActiveForTesting())
        #expect(await state.drainBufferForTesting().isEmpty)

        await state.setEnabled(false)
    }

    @Test("Activation after a timeout starts exactly one new session")
    func activationAfterTimeoutStartsOneSession() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(100)
        await state.handleAppDidResignActive(at: clock.now)
        await state.handleIdleTimeout()
        _ = await state.drainBufferForTesting()

        clock.advance(10)
        await state.handleAppDidBecomeActive(at: clock.now)

        let events = await state.drainBufferForTesting()
        #expect(events.filter { $0.type == .session && $0.name == "start" }.count == 1)
        #expect(await state.isSessionActiveForTesting())

        await state.setEnabled(false)
    }

    // MARK: - Ordering guard

    @Test("A resign stamped before the last processed signal is dropped")
    func staleResignIsDropped() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        // A Cmd-Tab bounce whose two tasks started out of order: the
        // become-active is processed first, then the older resign arrives.
        let resignStamp = clock.now.addingTimeInterval(10)
        let activateStamp = clock.now.addingTimeInterval(11)

        await state.handleAppDidBecomeActive(at: activateStamp)
        await state.handleAppDidResignActive(at: resignStamp)

        #expect(await state.idleDeadlineForTesting() == nil)
        #expect(await state.hasIdleTimerForTesting() == false)
        #expect(await state.isSessionMarkedInactiveForTesting() == false)

        await state.setEnabled(false)
    }

    @Test("An activation stamped before the last processed signal is dropped")
    func staleActivationIsDropped() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        let staleStamp = clock.now.addingTimeInterval(5)
        clock.advance(10)
        await state.handleAppDidResignActive(at: clock.now)

        await state.handleAppDidBecomeActive(at: staleStamp)

        // The idle window is still open — the stale activation did not close it.
        #expect(await state.idleDeadlineForTesting() != nil)
        #expect(await state.isSessionMarkedInactiveForTesting())

        await state.setEnabled(false)
    }

    // MARK: - Teardown cancels the window

    @Test("setEnabled(false) cancels a pending idle window")
    func disableCancelsIdleWindow() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(10)
        await state.handleAppDidResignActive(at: clock.now)
        await state.setEnabled(false)

        #expect(await state.idleDeadlineForTesting() == nil)
        #expect(await state.hasIdleTimerForTesting() == false)
    }

    @Test("A window cancelled by a disable/enable toggle does not leave the duration truncated")
    func toggleInsideWindowDoesNotTruncateDuration() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(100)
        await state.handleAppDidResignActive(at: clock.now)
        await state.setEnabled(false)
        await state.setEnabled(true)

        // Back inside what would have been the window (it ran to T+400).
        clock.advance(100)
        await state.handleAppDidBecomeActive(at: clock.now)
        #expect(await state.isSessionActiveForTesting())
        #expect(await state.isSessionMarkedInactiveForTesting() == false)

        clock.advance(3600)
        await state.handleAppDidResignActive(at: clock.now)
        await state.handleIdleTimeout()

        let end = sessionEvent(in: await state.drainBufferForTesting(), named: "end")
        #expect(end?.duration == 3800)

        await state.setEnabled(false)
    }

    @Test("A window cancelled by a disable/enable toggle still ends the session once it has lapsed")
    func toggleThenLateActivationEndsAndRestarts() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(100)
        await state.handleAppDidResignActive(at: clock.now)
        await state.setEnabled(false)
        await state.setEnabled(true)

        // Well past the T+400 boundary the cancelled window would have had.
        clock.advance(900)
        await state.handleAppDidBecomeActive(at: clock.now)

        let events = await state.drainBufferForTesting()
        #expect(sessionEvent(in: events, named: "end")?.duration == 100)
        #expect(sessionEvent(in: events, named: "start") != nil)
        #expect(await state.isSessionActiveForTesting())
        #expect(await state.isSessionMarkedInactiveForTesting() == false)

        await state.setEnabled(false)
    }

    @Test("Re-configure() cancels a pending idle window")
    func reconfigureCancelsIdleWindow() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(10)
        await state.handleAppDidResignActive(at: clock.now)

        await state.configure(
            TracklessConfig(
                apiKey: "tl_test",
                endpoint: "http://127.0.0.1:9",
                environment: .sandbox,
                flushIntervalSeconds: 3600,
                suppressWarnings: true
            )
        )

        #expect(await state.idleDeadlineForTesting() == nil)
        #expect(await state.hasIdleTimerForTesting() == false)

        await state.setEnabled(false)
    }

    @Test("destroy() cancels a pending idle window")
    func destroyCancelsIdleWindow() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(10)
        await state.handleAppDidResignActive(at: clock.now)
        await state.destroy()

        #expect(await state.idleDeadlineForTesting() == nil)
        #expect(await state.hasIdleTimerForTesting() == false)
        #expect(await state.isSessionActiveForTesting() == false)
    }

    // MARK: - The iOS shape of the same handlers

    @Test("Background ends the session; the next activation starts a new one")
    func backgroundThenForeground() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock)

        clock.advance(45)
        await state.handleAppDidEnterBackground(at: clock.now)

        #expect(await state.isSessionActiveForTesting() == false)
        #expect(await state.idleDeadlineForTesting() == nil)

        clock.advance(600)
        await state.handleAppDidBecomeActive(at: clock.now)
        #expect(await state.isSessionActiveForTesting())

        await state.setEnabled(false)
    }

    // MARK: - Configuration

    @Test("A sub-second timeout passes through TracklessConfig unclamped")
    func configBypassesTheClamp() async {
        let clock = FakeClock()
        let state = await makeState(clock: clock, idleTimeout: 0.25)

        #expect(await state.sessionIdleTimeoutForTesting() == 0.25)

        await state.handleAppDidResignActive(at: clock.now)
        #expect(await state.idleDeadlineForTesting() == FakeClock.base.addingTimeInterval(0.25))

        await state.setEnabled(false)
    }

    @Test("A clamped timeout warns once at configure")
    func clampWarnsOnce() async {
        let recorder = WarningRecorder()
        let clock = FakeClock()
        let state = TracklessState(clock: clock, notificationCenter: NotificationCenter())
        await state.setOnWarningForTesting { recorder.record($0) }

        await state.configure(
            TracklessConfig(
                apiKey: "tl_test",
                endpoint: "http://127.0.0.1:9",
                environment: .sandbox,
                flushIntervalSeconds: 3600,
                sessionIdleTimeoutSeconds: 30,
                sessionIdleTimeoutWasClamped: true
            )
        )

        let clampWarnings = recorder.messages.filter { $0.contains("sessionIdleTimeoutSeconds") }
        #expect(clampWarnings.count == 1)

        await state.setEnabled(false)
    }

    @Test("An in-range timeout warns about nothing")
    func inRangeDoesNotWarn() async {
        let recorder = WarningRecorder()
        let clock = FakeClock()
        let state = await makeState(clock: clock, onWarning: { recorder.record($0) })

        #expect(recorder.messages.filter { $0.contains("sessionIdleTimeoutSeconds") }.isEmpty)

        await state.setEnabled(false)
    }
}

@Suite("sessionIdleTimeoutSeconds clamping")
struct SessionIdleTimeoutClampTests {

    @Test("Below the minimum clamps up to 30s")
    func belowMinimum() {
        #expect(Trackless.clampSessionIdleTimeout(5) == 30)
        #expect(Trackless.clampSessionIdleTimeout(0) == 30)
        #expect(Trackless.clampSessionIdleTimeout(-90) == 30)
    }

    @Test("Above the maximum clamps down to 3600s")
    func aboveMaximum() {
        #expect(Trackless.clampSessionIdleTimeout(7_200) == 3_600)
        #expect(Trackless.clampSessionIdleTimeout(86_400) == 3_600)
    }

    @Test("A value inside the range is preserved")
    func insideRange() {
        #expect(Trackless.clampSessionIdleTimeout(30) == 30)
        #expect(Trackless.clampSessionIdleTimeout(300) == 300)
        #expect(Trackless.clampSessionIdleTimeout(3_600) == 3_600)
    }

    /// `min`/`max` propagate NaN rather than clamping it, so a non-finite value
    /// would otherwise sail through the range check and arm a deadline that
    /// never compares true.
    @Test("A non-finite value falls back to the default rather than to a bound")
    func nonFiniteFallsBack() {
        #expect(Trackless.clampSessionIdleTimeout(.nan) == Trackless.defaultSessionIdleTimeoutSeconds)
        #expect(Trackless.clampSessionIdleTimeout(.infinity) == Trackless.defaultSessionIdleTimeoutSeconds)
        #expect(Trackless.clampSessionIdleTimeout(-.infinity) == Trackless.defaultSessionIdleTimeoutSeconds)
        #expect(Trackless.defaultSessionIdleTimeoutSeconds == 300)
    }
}
