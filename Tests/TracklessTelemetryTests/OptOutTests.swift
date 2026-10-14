import Foundation
import Testing

@testable import TracklessTelemetry

/// `setEnabled(false)` drops the session without sending its end, so an
/// opt-out never leads to a later send; `setEnabled(true)` starts a new one.
@Suite("Opt-out with setEnabled")
struct OptOutTests {

    private static let apiKey = "tl_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private func configuredState(_ recorder: TransportRecorder) async -> TracklessState {
        let state = TracklessState(notificationCenter: NotificationCenter(), transport: recorder.transport)
        await state.configure(
            TracklessConfig(
                apiKey: Self.apiKey,
                endpoint: "https://ingest.test",
                environment: .production,
                enabled: true,
                onError: nil,
                flushIntervalSeconds: 3600,
                suppressWarnings: true
            )
        )
        return state
    }

    @Test("setEnabled(false) drops the session, so destroy() sends nothing")
    func optOutThenDestroySendsNothing() async {
        let recorder = TransportRecorder()
        let state = await configuredState(recorder)

        await state.recordEvent(type: .feature, name: "before_opt_out")
        await state.setEnabled(false)
        await state.destroy()

        #expect(recorder.sent.isEmpty)
    }

    @Test("setEnabled(true) after an opt-out starts a new session")
    func optInStartsNewSession() async {
        let recorder = TransportRecorder()
        let state = await configuredState(recorder)

        await state.recordEvent(type: .feature, name: "before_opt_out")
        await state.setEnabled(false)
        await state.setEnabled(true)
        await state.recordEvent(type: .feature, name: "after_opt_in")
        await state.destroy()

        let sessions = recorder.events(apiKey: Self.apiKey).filter { $0.type == .session }
        #expect(sessions.map(\.name) == ["start", "end"])
        #expect(sessions.last?.stepIndex == 1)
    }
}
