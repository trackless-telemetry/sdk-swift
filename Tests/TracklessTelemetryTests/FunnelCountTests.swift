import Testing
import Foundation
@testable import TracklessTelemetry

// Funnel steps count every call, the way feature() does: no per-session dedup.
// docs/funnel-counts-plan-2026-11.md §3.1 and §5.

@Suite("Funnel — every call counts")
struct FunnelCountTests {

    /// A configured state with a long flush interval so the periodic timer never fires
    /// during the test. Tests call `setEnabled(false)` at the end to cancel it.
    private func makeConfiguredState() async -> TracklessState {
        let state = TracklessState()
        let config = TracklessConfig(
            apiKey: "tl_test",
            endpoint: "https://example.invalid",
            environment: .sandbox,
            enabled: true,
            onError: nil,
            flushIntervalSeconds: 3600,
            debugLogging: false,
            suppressWarnings: true
        )
        await state.configure(config)
        return state
    }

    private func funnelEvents(_ events: [TracklessEvent]) -> [TracklessEvent] {
        events.filter { $0.type == .funnel }
    }

    /// The depth the `session/end` event reports, i.e. how many times the session's
    /// `recordActivity()` ran.
    private func endedSessionDepth(_ events: [TracklessEvent]) -> Int? {
        events.first(where: { $0.type == .session && $0.name == "end" })?.stepIndex
    }

    @Test("The same step three times in one session buffers three events and three activities")
    func sameStepThreeTimes() async {
        let state = await makeConfiguredState()
        #expect(await state.isSessionActiveForTesting())
        _ = await state.drainBufferForTesting() // drop the session/start event

        for _ in 0..<3 {
            await state.recordFunnel(funnelName: "breath", stepIndex: 0, stepName: "started")
        }
        #expect(await state.bufferSizeForTesting() == 3)

        await state.endSessionForTesting()
        let events = await state.drainBufferForTesting()
        let funnels = funnelEvents(events)
        #expect(funnels.count == 3)
        #expect(funnels.allSatisfy { $0.name == "breath" && $0.step == "started" && $0.stepIndex == 0 })
        #expect(endedSessionDepth(events) == 3)

        await state.setEnabled(false)
    }

    @Test("A flow repeated in one session sends every step of every run")
    func repeatedFlowInOneSession() async {
        let state = await makeConfiguredState()
        _ = await state.drainBufferForTesting()

        for _ in 0..<2 {
            await state.recordFunnel(funnelName: "checkout", stepIndex: 0, stepName: "cart")
            await state.recordFunnel(funnelName: "checkout", stepIndex: 1, stepName: "payment")
        }

        let funnels = funnelEvents(await state.drainBufferForTesting())
        #expect(funnels.count == 4)
        #expect(funnels.map(\.stepIndex) == [0, 1, 0, 1])

        await state.setEnabled(false)
    }

    @Test("Steps sent on both sides of a session end are all sent")
    func stepsAcrossSessionEnd() async {
        let state = await makeConfiguredState()
        _ = await state.drainBufferForTesting()

        await state.recordFunnel(funnelName: "checkout", stepIndex: 0, stepName: "cart")
        await state.recordFunnel(funnelName: "checkout", stepIndex: 1, stepName: "payment")
        await state.endSessionForTesting()
        await state.startSessionForTesting()
        await state.recordFunnel(funnelName: "checkout", stepIndex: 0, stepName: "cart")
        await state.recordFunnel(funnelName: "checkout", stepIndex: 1, stepName: "payment")

        let funnels = funnelEvents(await state.drainBufferForTesting())
        #expect(funnels.count == 4)
        #expect(funnels.map(\.stepIndex) == [0, 1, 0, 1])

        await state.setEnabled(false)
    }

    @Test("No funnel event carries count, and none is rolled up")
    func noFunnelEventCarriesCount() async {
        let state = await makeConfiguredState()
        _ = await state.drainBufferForTesting()

        for _ in 0..<5 {
            await state.recordFunnel(funnelName: "checkout", stepIndex: 2, stepName: "confirm")
        }

        let funnels = funnelEvents(await state.drainBufferForTesting())
        #expect(funnels.count == 5)
        #expect(funnels.allSatisfy { $0.count == nil })

        await state.setEnabled(false)
    }

    @Test("A repeated step logs no drop warning")
    func repeatedStepNoWarning() async {
        let state = TracklessState()
        let warnings = WarningSink()
        await state.setOnWarningForTesting { warnings.append($0) }
        await state.configure(TracklessConfig(
            apiKey: "tl_test",
            endpoint: "https://example.invalid",
            environment: .sandbox,
            enabled: true,
            onError: nil,
            flushIntervalSeconds: 3600,
            debugLogging: false,
            suppressWarnings: false
        ))

        await state.recordFunnel(funnelName: "checkout", stepIndex: 0, stepName: "cart")
        await state.recordFunnel(funnelName: "checkout", stepIndex: 0, stepName: "cart")
        #expect(warnings.messages.filter { $0.contains("funnel") }.isEmpty)

        await state.setEnabled(false)
    }
}

/// Thread-safe collector for warning messages.
private final class WarningSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(message)
    }

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
