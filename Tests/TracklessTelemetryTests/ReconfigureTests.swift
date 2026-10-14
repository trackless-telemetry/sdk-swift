import Foundation
import Testing

@testable import TracklessTelemetry

/// A repeat `configure()`: a changed setting (typically a new API key when the
/// user switches organization) ends the session and flushes it under the
/// previous settings; identical settings keep the session.
///
/// Every test injects `TransportRecorder` in place of the network, so what
/// was sent, and under which key, is read back directly.
@Suite("Reconfigure")
struct ReconfigureTests {

    private static let keyA = "tl_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let keyB = "tl_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private func makeState(_ recorder: TransportRecorder) -> TracklessState {
        // A private NotificationCenter: lifecycle observers registered by
        // `configure()` never see a real system notification.
        TracklessState(notificationCenter: NotificationCenter(), transport: recorder.transport)
    }

    private func config(
        apiKey: String,
        environment: TracklessEnvironment = .production,
        enabled: Bool = true,
        onError: (@Sendable (Error) -> Void)? = nil
    ) -> TracklessConfig {
        TracklessConfig(
            apiKey: apiKey,
            endpoint: "https://ingest.test",
            environment: environment,
            enabled: enabled,
            onError: onError,
            flushIntervalSeconds: 3600,
            suppressWarnings: true
        )
    }

    // MARK: - Changed settings

    @Test("Events before a new key go out under the old key, events after under the new one")
    func eventsFollowTheKeyTheyWereRecordedUnder() async {
        let recorder = TransportRecorder()
        let state = makeState(recorder)

        await state.configure(config(apiKey: Self.keyA))
        await state.recordEvent(type: .feature, name: "before_switch")
        await state.configure(config(apiKey: Self.keyB))
        await state.recordEvent(type: .feature, name: "after_switch")
        await state.flush()

        let underA = recorder.events(apiKey: Self.keyA)
        let underB = recorder.events(apiKey: Self.keyB)
        #expect(underA.contains { $0.type == .feature && $0.name == "before_switch" })
        #expect(!underA.contains { $0.name == "after_switch" })
        #expect(underB.contains { $0.type == .feature && $0.name == "after_switch" })
        #expect(!underB.contains { $0.name == "before_switch" })

        await state.setEnabled(false)
    }

    @Test("The old session ends under the old key and a new one starts under the new key")
    func oldSessionEndsNewSessionStarts() async {
        let recorder = TransportRecorder()
        let state = makeState(recorder)

        await state.configure(config(apiKey: Self.keyA))
        await state.recordEvent(type: .view, name: "home")
        await state.configure(config(apiKey: Self.keyB))

        // The retired flush has completed by the time configure() returns.
        let underA = recorder.events(apiKey: Self.keyA)
        #expect(underA.filter { $0.type == .session && $0.name == "start" }.count == 1)
        let end = underA.first { $0.type == .session && $0.name == "end" }
        #expect(end != nil)
        #expect(end?.stepIndex == 1)

        await state.flush()
        let underB = recorder.events(apiKey: Self.keyB)
        #expect(underB.filter { $0.type == .session && $0.name == "start" }.count == 1)
        #expect(!underB.contains { $0.type == .session && $0.name == "end" })
        #expect(await state.isSessionActiveForTesting())

        await state.setEnabled(false)
    }

    @Test("The retired batch keeps the previous environment")
    func retiredBatchKeepsPreviousEnvironment() async {
        let recorder = TransportRecorder()
        let state = makeState(recorder)

        await state.configure(config(apiKey: Self.keyA, environment: .sandbox))
        await state.recordEvent(type: .feature, name: "one")
        await state.configure(config(apiKey: Self.keyA, environment: .production))
        await state.recordEvent(type: .feature, name: "two")
        await state.flush()

        let sent = recorder.sent
        let sandbox = sent.filter { $0.payload.environment == "sandbox" }.flatMap { $0.payload.events }
        let production = sent.filter { $0.payload.environment == "production" }.flatMap { $0.payload.events }
        #expect(sandbox.contains { $0.name == "one" })
        #expect(sandbox.contains { $0.type == .session && $0.name == "end" })
        #expect(production.contains { $0.name == "two" })
        #expect(production.contains { $0.type == .session && $0.name == "start" })
        #expect(!production.contains { $0.name == "one" })

        await state.setEnabled(false)
    }

    @Test("A disabled configuration sends no session end when replaced")
    func disabledConfigurationSendsNothing() async {
        let recorder = TransportRecorder()
        let state = makeState(recorder)

        await state.configure(config(apiKey: Self.keyA))
        await state.setEnabled(false)
        await state.configure(config(apiKey: Self.keyB))

        #expect(recorder.events(apiKey: Self.keyA).isEmpty)

        await state.setEnabled(false)
    }

    // MARK: - Identical settings

    @Test("An identical repeat configure keeps the session and the buffer")
    func identicalRepeatKeepsSession() async {
        let recorder = TransportRecorder()
        let state = makeState(recorder)

        await state.configure(config(apiKey: Self.keyA))
        await state.recordEvent(type: .feature, name: "kept")
        await state.configure(config(apiKey: Self.keyA))

        // Nothing was flushed by the repeat call.
        #expect(recorder.sent.isEmpty)

        await state.flush()
        let underA = recorder.events(apiKey: Self.keyA)
        #expect(underA.filter { $0.type == .session && $0.name == "start" }.count == 1)
        #expect(!underA.contains { $0.type == .session && $0.name == "end" })
        #expect(underA.contains { $0.name == "kept" })
        #expect(await state.isSessionActiveForTesting())

        await state.setEnabled(false)
    }

    @Test("An identical repeat configure replaces onError and keeps the session")
    func identicalRepeatReplacesOnError() async {
        let recorder = TransportRecorder(status: 503)
        let state = makeState(recorder)
        let first = ErrorRecorder()
        let second = ErrorRecorder()

        await state.configure(config(apiKey: Self.keyA, onError: { first.record($0) }))
        await state.configure(config(apiKey: Self.keyA, onError: { second.record($0) }))
        await state.recordEvent(type: .feature, name: "fails")
        await state.flush()

        #expect(first.errors.isEmpty)
        #expect(second.errors.count == 1)
        let starts = recorder.events(apiKey: Self.keyA).filter { $0.type == .session && $0.name == "start" }
        #expect(starts.count == 1)
        #expect(await state.isSessionActiveForTesting())

        await state.setEnabled(false)
    }
}

// MARK: - Test Helpers

/// Stands in for the network: records every payload with the key and endpoint
/// it was sent under, and answers with a fixed status.
final class TransportRecorder: @unchecked Sendable {
    struct Sent {
        let apiKey: String
        let endpoint: String
        let payload: TracklessEventPayload
    }

    private let lock = NSLock()
    private var _sent: [Sent] = []
    private let status: Int

    init(status: Int = 202) {
        self.status = status
    }

    var sent: [Sent] {
        lock.lock()
        defer { lock.unlock() }
        return _sent
    }

    func events(apiKey: String) -> [TracklessEvent] {
        sent.filter { $0.apiKey == apiKey }.flatMap { $0.payload.events }
    }

    var transport: TracklessTransport {
        { [self] endpoint, apiKey, payload, _ in
            record(Sent(apiKey: apiKey, endpoint: endpoint, payload: payload))
            return SendResult(status: status, body: nil)
        }
    }

    private func record(_ sent: Sent) {
        lock.lock()
        _sent.append(sent)
        lock.unlock()
    }
}
