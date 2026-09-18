#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import TracklessTelemetry

/// The one platform-conditional test file.
///
/// Everything about the idle state machine is pinned in
/// `SessionIdleStateMachineTests` against the platform-neutral handlers. What is
/// left — and what can only be checked on a macOS host — is the wiring: that the
/// real `NSApplication` notification names reach those handlers, and that they
/// stop reaching them after teardown.
///
/// The observers register with `queue: nil`, so posting is synchronous, but each
/// block then hands off to an unstructured `Task` — hence the polling helper
/// rather than a fixed sleep.
@Suite("macOS lifecycle wiring", .serialized)
struct MacOSLifecycleWiringTests {

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    private func makeState(center: NotificationCenter, clock: FakeClock) async -> TracklessState {
        let state = TracklessState(clock: clock, notificationCenter: center)
        await state.configure(
            TracklessConfig(
                apiKey: "tl_test",
                endpoint: "http://127.0.0.1:9",
                environment: .sandbox,
                flushIntervalSeconds: 3600,
                suppressWarnings: true,
                sessionIdleTimeoutSeconds: 300
            )
        )
        _ = await state.drainBufferForTesting()
        return state
    }

    @Test("NSApplication.didResignActiveNotification opens the idle window")
    func resignNotificationReachesTheHandler() async {
        let center = NotificationCenter()
        let clock = FakeClock()
        let state = await makeState(center: center, clock: clock)

        clock.advance(100)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)

        #expect(await waitUntil { await state.idleDeadlineForTesting() != nil })
        #expect(await state.isSessionActiveForTesting())
        #expect(await state.isSessionMarkedInactiveForTesting())

        await state.setEnabled(false)
    }

    @Test("NSApplication.didBecomeActiveNotification closes it again")
    func becomeActiveNotificationReachesTheHandler() async {
        let center = NotificationCenter()
        let clock = FakeClock()
        let state = await makeState(center: center, clock: clock)

        clock.advance(100)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(await waitUntil { await state.idleDeadlineForTesting() != nil })

        clock.advance(30)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(await waitUntil { await state.idleDeadlineForTesting() == nil })
        #expect(await state.isSessionActiveForTesting())
        #expect(await state.isSessionMarkedInactiveForTesting() == false)

        await state.setEnabled(false)
    }

    @Test("setEnabled(false) unregisters the observers")
    func teardownUnregistersObservers() async {
        let center = NotificationCenter()
        let clock = FakeClock()
        let state = await makeState(center: center, clock: clock)

        await state.setEnabled(false)

        clock.advance(100)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)

        // Nothing should arrive. Give a real task a chance to run before
        // asserting the negative.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await state.idleDeadlineForTesting() == nil)
    }

    @Test("NSApplication.willTerminateNotification ends the session")
    func terminateNotificationEndsTheSession() async {
        let center = NotificationCenter()
        let clock = FakeClock()
        let state = await makeState(center: center, clock: clock)

        clock.advance(42)
        // The handler blocks its caller on purpose (see `handleWillTerminate`),
        // so the post goes to a plain GCD thread and the assertion polls.
        // Deliberately *not* `Task.detached`: that would block a cooperative-pool
        // thread, which is the one resource the work it is waiting on needs. In
        // production the caller is AppKit's main thread at quit, which is not a
        // cooperative thread either.
        DispatchQueue.global().async {
            center.post(name: NSApplication.willTerminateNotification, object: nil)
        }

        #expect(await waitUntil { await state.isSessionActiveForTesting() == false })

        await state.setEnabled(false)
    }

    @Test("The macOS build reports platform macos and an sdkVersion to match")
    func macOSReportsItsOwnPlatform() {
        let ctx = ContextDetection.detect()
        #expect(ctx.platform == "macos")
        #expect(ctx.sdkVersion?.hasPrefix("macos/") == true)
        #expect(ctx.deviceClass == "desktop")
    }
}
#endif
