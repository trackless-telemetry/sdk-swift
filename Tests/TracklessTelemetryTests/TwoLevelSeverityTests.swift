import Testing
import Foundation
@testable import TracklessTelemetry

// Coverage for the two stored levels: `error(_:code:)` and `info(_:detail:)`.
//
// The SDK maps whatever severity a caller passes to one of two values before the
// event is buffered, so nothing but `error` or `info` reaches the wire. These
// tests pin that mapping, the wire shape `info()` produces, and the fact that
// `info()` behaves like every other non-session event (depth, session reach,
// normalization, PII stripping).

@Suite("Two stored levels — client-side mapping")
struct StoredSeverityMappingTests {

    /// The five strings an installed app may still send, spelled through
    /// `rawValue` so these tests do not name the deprecated cases.
    static func sent(_ raw: String) -> TracklessErrorSeverity {
        TracklessErrorSeverity(rawValue: raw)!
    }

    @Test("Every legacy severity maps to one of the two stored levels")
    func mapsFiveToTwo() {
        #expect(Trackless.storedSeverity(Self.sent("debug")) == .info)
        #expect(Trackless.storedSeverity(Self.sent("info")) == .info)
        #expect(Trackless.storedSeverity(Self.sent("warning")) == .error)
        #expect(Trackless.storedSeverity(Self.sent("error")) == .error)
        #expect(Trackless.storedSeverity(Self.sent("fatal")) == .error)
    }

    @Test("The five raw values still parse — the validator accepts all of them")
    func allFiveStillParse() {
        for raw in ["debug", "info", "warning", "error", "fatal"] {
            #expect(TracklessErrorSeverity(rawValue: raw) != nil)
        }
    }
}

@Suite("Two stored levels — recordError integration")
struct TwoLevelRecordErrorTests {

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

    private func sent(_ raw: String) -> TracklessErrorSeverity {
        TracklessErrorSeverity(rawValue: raw)!
    }

    @Test("Each legacy severity is buffered at its stored level, never as sent")
    func buffersStoredLevelOnly() async {
        let state = await makeConfiguredState()

        await state.recordError(name: "e_debug", severity: sent("debug"), code: nil)
        await state.recordError(name: "e_info", severity: sent("info"), code: nil)
        await state.recordError(name: "e_warning", severity: sent("warning"), code: nil)
        await state.recordError(name: "e_error", severity: sent("error"), code: nil)
        await state.recordError(name: "e_fatal", severity: sent("fatal"), code: nil)
        let events = await state.drainBufferForTesting()

        func level(_ name: String) -> TracklessErrorSeverity? {
            events.first(where: { $0.type == .error && $0.name == name })?.severity
        }
        #expect(level("e_debug") == .info)
        #expect(level("e_info") == .info)
        #expect(level("e_warning") == .error)
        #expect(level("e_error") == .error)
        #expect(level("e_fatal") == .error)

        await state.setEnabled(false)
    }

    @Test("Mixed legacy severities for one name and code roll up to one entry")
    func mixedSeveritiesRollUp() async {
        let state = await makeConfiguredState()

        await state.recordError(name: "payment_failed", severity: sent("fatal"), code: "DECLINED")
        await state.recordError(name: "payment_failed", severity: sent("warning"), code: "DECLINED")
        await state.recordError(name: "payment_failed", severity: sent("error"), code: "DECLINED")
        let events = await state.drainBufferForTesting()

        let errors = events.filter { $0.type == .error && $0.name == "payment_failed" }
        #expect(errors.count == 1)
        #expect(errors.first?.severity == .error)
        #expect(errors.first?.code == "declined")
        #expect(errors.first?.count == 3)
        #expect(errors.first?.firstOccurrences == 1)

        await state.setEnabled(false)
    }

    @Test("info() sends the detail as code at severity info")
    func infoWireShape() async throws {
        let state = await makeConfiguredState()

        await state.recordError(name: "tier", severity: .info, code: "paid")
        let events = await state.drainBufferForTesting()
        let event = try #require(events.first(where: { $0.type == .error && $0.name == "tier" }))

        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(event)
        ) as! [String: Any]
        #expect(json["type"] as? String == "error")
        #expect(json["name"] as? String == "tier")
        #expect(json["severity"] as? String == "info")
        #expect(json["code"] as? String == "paid")

        await state.setEnabled(false)
    }

    @Test("info() without a detail carries no code")
    func infoWithoutDetail() async throws {
        let state = await makeConfiguredState()

        await state.recordError(name: "offline_fallback", severity: .info, code: nil)
        let events = await state.drainBufferForTesting()
        let event = try #require(events.first(where: { $0.name == "offline_fallback" }))

        #expect(event.severity == .info)
        #expect(event.code == nil)
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(event)
        ) as! [String: Any]
        #expect(json["code"] == nil)

        await state.setEnabled(false)
    }

    @Test("An error and an info on one name are two rows sharing one first occurrence")
    func sharedNameSharesReach() async {
        let state = await makeConfiguredState()

        await state.recordError(name: "tier", severity: .error, code: nil)
        await state.recordError(name: "tier", severity: .info, code: "paid")
        let events = await state.drainBufferForTesting()

        let rows = events.filter { $0.type == .error && $0.name == "tier" }
        #expect(rows.count == 2)
        #expect(rows.first(where: { $0.severity == .error })?.firstOccurrences == 1)
        #expect(rows.first(where: { $0.severity == .info })?.firstOccurrences == nil)

        await state.setEnabled(false)
    }

    @Test("info() marks the first occurrence once per session")
    func infoFirstOccurrenceOncePerSession() async {
        let state = await makeConfiguredState()

        await state.recordError(name: "tier", severity: .info, code: "paid")
        await state.recordError(name: "tier", severity: .info, code: "paid")
        let events = await state.drainBufferForTesting()

        let row = events.first(where: { $0.type == .error && $0.name == "tier" })
        #expect(row?.count == 2)
        #expect(row?.firstOccurrences == 1)

        await state.setEnabled(false)
    }

    @Test("info() increments session depth like any other non-session event")
    func infoIncrementsDepth() async throws {
        let state = await makeConfiguredState()

        await state.recordError(name: "tier", severity: .info, code: "paid")
        await state.recordError(name: "units", severity: .info, code: "metric")
        await state.recordError(name: "tier", severity: .info, code: "paid")
        await state.endSessionForTesting()
        let events = await state.drainBufferForTesting()

        let end = try #require(events.first(where: { $0.type == .session && $0.name == "end" }))
        // `stepIndex` on a session-end event carries the session's depth.
        #expect(end.stepIndex == 3)

        await state.setEnabled(false)
    }

    @Test("The info detail is normalized and PII-stripped exactly like a code")
    func infoDetailNormalized() async {
        let state = await makeConfiguredState()

        await state.recordError(name: "tier", severity: .info, code: "Paid Tier")
        await state.recordError(name: "contact", severity: .info, code: "user@example.com")
        let events = await state.drainBufferForTesting()

        #expect(events.first(where: { $0.name == "tier" })?.code == "paid_tier")
        #expect(events.first(where: { $0.name == "contact" })?.code == "redacted")

        await state.setEnabled(false)
    }

    @Test("A rejected info name records nothing")
    func rejectedInfoNameRecordsNothing() async {
        let state = await makeConfiguredState()

        // Normalizes to empty, so nothing is buffered — the same guard `error()`
        // and `feature()` apply.
        await state.recordError(name: "___", severity: .info, code: "paid")
        let events = await state.drainBufferForTesting()

        #expect(events.contains(where: { $0.type == .error }) == false)

        await state.setEnabled(false)
    }
}
