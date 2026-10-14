import Foundation
import Testing
@testable import TracklessTelemetry

@Suite("Warning Behavior Tests")
struct WarningBehaviorTests {

    /// Config pointing at an unreachable endpoint with a flush interval long
    /// enough that no network activity happens during a test.
    private func testConfig(
        suppressWarnings: Bool = false,
        flushIntervalSeconds: TimeInterval = 3600,
        onError: (@Sendable (Error) -> Void)? = nil
    ) -> TracklessConfig {
        TracklessConfig(
            apiKey: "tl_0123456789abcdef0123456789abcdef",
            endpoint: "http://127.0.0.1:9",
            environment: .production,
            enabled: true,
            onError: onError,
            flushIntervalSeconds: flushIntervalSeconds,
            debugLogging: false,
            suppressWarnings: suppressWarnings
        )
    }

    // MARK: - Pre-Configure Drops

    @Test("Events recorded before configure() warn once")
    func preConfigureWarnsOnce() async {
        let state = TracklessState()
        let recorder = WarningRecorder()
        await state.setOnWarningForTesting { recorder.record($0) }

        await state.recordEvent(type: .feature, name: "early_feature")
        await state.recordEvent(type: .view, name: "early_view")
        await state.recordFunnel(funnelName: "checkout", stepIndex: 0, stepName: "cart")
        await state.recordPerformance(name: "load", durationSeconds: 1.0)
        await state.recordError(name: "boom", severity: .error, code: nil)

        #expect(recorder.messages.count == 1)
        #expect(recorder.messages.first?.contains("configure") == true)
    }

    @Test("Recording works after configure() with no further pre-configure warnings")
    func configureEnablesRecording() async {
        let state = TracklessState()
        let recorder = WarningRecorder()
        await state.setOnWarningForTesting { recorder.record($0) }

        await state.recordEvent(type: .feature, name: "early_feature")
        #expect(recorder.messages.count == 1)

        await state.configure(testConfig())
        await state.recordEvent(type: .feature, name: "later_feature")

        // Session start + the recorded feature
        let size = await state.bufferSizeForTesting()
        #expect(size == 2)
        #expect(recorder.messages.count == 1)
    }

    // MARK: - Buffer-Full Drops

    @Test("Buffer-full drops warn once per session")
    func bufferFullWarnsOnce() async {
        let state = TracklessState()
        let recorder = WarningRecorder()
        await state.setOnWarningForTesting { recorder.record($0) }
        await state.configure(testConfig())
        await state.replaceBufferForTesting(maxItems: 2)

        await state.recordEvent(type: .feature, name: "one")
        await state.recordEvent(type: .feature, name: "two")
        await state.recordEvent(type: .feature, name: "three")
        await state.recordEvent(type: .feature, name: "four")

        let size = await state.bufferSizeForTesting()
        #expect(size == 2)
        let bufferWarnings = recorder.messages.filter { $0.contains("buffer full") }
        #expect(bufferWarnings.count == 1)
    }

    @Test("Buffer-full warning respects suppressWarnings")
    func bufferFullWarningSuppressed() async {
        let state = TracklessState()
        let recorder = WarningRecorder()
        await state.setOnWarningForTesting { recorder.record($0) }
        await state.configure(testConfig(suppressWarnings: true))
        await state.replaceBufferForTesting(maxItems: 1)

        await state.recordEvent(type: .feature, name: "one")
        await state.recordEvent(type: .feature, name: "two")

        let size = await state.bufferSizeForTesting()
        #expect(size == 1)
        #expect(recorder.messages.isEmpty)
    }

    @Test("Buffer-full warning is re-armed when a new session starts")
    func bufferFullWarningResetsOnNewSession() async {
        let state = TracklessState(transport: TransportRecorder().transport)
        let recorder = WarningRecorder()
        await state.setOnWarningForTesting { recorder.record($0) }

        await state.configure(testConfig())
        await state.replaceBufferForTesting(maxItems: 1)
        await state.recordEvent(type: .feature, name: "one")
        await state.recordEvent(type: .feature, name: "two")

        // Reconfiguring with a changed setting starts a new session, which
        // re-arms the warning. (Identical settings would keep the session.)
        await state.configure(testConfig(flushIntervalSeconds: 1800))
        await state.replaceBufferForTesting(maxItems: 1)
        await state.recordEvent(type: .feature, name: "three")
        await state.recordEvent(type: .feature, name: "four")

        let bufferWarnings = recorder.messages.filter { $0.contains("buffer full") }
        #expect(bufferWarnings.count == 2)
    }

    // MARK: - Rejected Names Never Echo Raw Input

    /// A rejected name is raw, pre-normalization caller input: it reaches the
    /// warning *because* normalization failed, so no PII-stripped form of it
    /// exists. `warn` emits to the unified log with `privacy: .public`, where a
    /// sysdiagnose bundle collects it, so the raw value must never get there.
    ///
    /// On which inputs actually reach this path: PII stripping replaces a
    /// matched email/phone/SSN with the literal "[REDACTED]", which normalizes
    /// to the non-empty "redacted". A name containing a *recognized* email
    /// therefore always normalizes successfully and never reaches the rejection
    /// branch. The names that do reach it are the ones the PII guard does not
    /// recognize — most importantly non-Latin-script text, which includes
    /// personal names.
    private static let rejectedName = "Ольга Иванова"
    private static let email = "user@example.com"

    @Test("Rejection warning omits the raw name")
    func rejectionWarningOmitsRawName() async {
        let state = TracklessState()
        let recorder = WarningRecorder()
        await state.setOnWarningForTesting { recorder.record($0) }
        await state.configure(testConfig())

        await state.recordEvent(type: .feature, name: Self.rejectedName)

        let rejections = recorder.messages.filter { $0.contains("event name rejected") }
        #expect(rejections.count == 1)
        #expect(!recorder.messages.contains(where: { $0.contains(Self.rejectedName) }))
    }

    @Test("Rejection error omits the raw name")
    func rejectionErrorOmitsRawName() async {
        let state = TracklessState()
        let errors = ErrorRecorder()
        await state.configure(testConfig(onError: { errors.record($0) }))

        await state.recordEvent(type: .feature, name: Self.rejectedName)

        #expect(errors.errors.count == 1)
        let tracklessErrors = errors.errors.compactMap { $0 as? TracklessError }
        #expect(tracklessErrors.count == 1)
        if let first = tracklessErrors.first {
            if case .invalidFeatureName(let reason) = first {
                // The payload carries the rejection reason, never the name.
                #expect(!reason.contains(Self.rejectedName))
                #expect(reason.contains("raw name omitted"))
            } else {
                Issue.record("expected TracklessError.invalidFeatureName")
            }
        }
        #expect(!errors.descriptions.contains(where: { $0.contains(Self.rejectedName) }))
    }

    @Test("Every entry point keeps a rejected name out of warnings and errors")
    func everyEntryPointOmitsRejectedName() async {
        let state = TracklessState()
        let recorder = WarningRecorder()
        let errors = ErrorRecorder()
        await state.setOnWarningForTesting { recorder.record($0) }
        await state.configure(testConfig(onError: { errors.record($0) }))

        await state.recordEvent(type: .view, name: Self.rejectedName)
        await state.recordEvent(type: .feature, name: Self.rejectedName)
        await state.recordFunnel(funnelName: Self.rejectedName, stepIndex: 0, stepName: Self.rejectedName)
        await state.recordPerformance(name: Self.rejectedName, durationSeconds: 1.0)
        await state.recordError(name: Self.rejectedName, severity: .error, code: nil)

        let emitted = recorder.messages + errors.descriptions
        #expect(emitted.count >= 5)
        #expect(!emitted.contains(where: { $0.contains(Self.rejectedName) }))
    }

    @Test("An email in an accepted name is redacted before it is buffered or warned about")
    func emailIsRedactedBeforeBuffering() async {
        let state = TracklessState()
        let recorder = WarningRecorder()
        let errors = ErrorRecorder()
        await state.setOnWarningForTesting { recorder.record($0) }
        await state.configure(testConfig(onError: { errors.record($0) }))

        await state.recordEvent(type: .feature, name: "signup \(Self.email)", detail: Self.email)
        await state.recordEvent(type: .view, name: "profile \(Self.email)")

        let names = await state.drainBufferForTesting().map(\.name)
        #expect(names.contains("signup_redacted"))
        for candidate in names + recorder.messages + errors.descriptions {
            #expect(!candidate.contains(Self.email))
            #expect(!candidate.contains("@"))
        }
    }

    @Test("Rejection warning respects suppressWarnings")
    func rejectionWarningSuppressed() async {
        let state = TracklessState()
        let recorder = WarningRecorder()
        await state.setOnWarningForTesting { recorder.record($0) }
        await state.configure(testConfig(suppressWarnings: true))

        await state.recordEvent(type: .feature, name: Self.rejectedName)

        #expect(recorder.messages.isEmpty)
    }
}

// MARK: - Test Helpers

/// Thread-safe warning collector for async tests.
final class WarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _messages
    }

    func record(_ message: String) {
        lock.lock()
        _messages.append(message)
        lock.unlock()
    }
}

/// Thread-safe error collector for async tests.
final class ErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _errors: [Error] = []

    var errors: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return _errors
    }

    /// Rendered form of each error — what a developer forwarding `onError` to a
    /// logger or crash reporter would actually transmit.
    var descriptions: [String] {
        errors.map { String(describing: $0) }
    }

    func record(_ error: Error) {
        lock.lock()
        _errors.append(error)
        lock.unlock()
    }
}
