import Testing
import Foundation
@testable import TracklessTelemetry

// Coverage for Error Reach (session-reach dedup for error events) — the error-side
// mirror of Feature Reach.

// MARK: - First-Occurrence Tracker

@Suite("Error Reach — First-Occurrence Tracker")
struct ErrorFirstOccurrenceTrackerTests {

    @Test("First occurrence returns true, repeat in the same session returns false")
    func firstOccurrenceThenRepeat() async {
        let tracker = ErrorFirstOccurrenceTracker()
        #expect(await tracker.markFirstOccurrence(name: "payment_failed") == true)
        #expect(await tracker.markFirstOccurrence(name: "payment_failed") == false)
    }

    @Test("Distinct error names dedup independently")
    func distinctNamesIndependent() async {
        let tracker = ErrorFirstOccurrenceTracker()
        #expect(await tracker.markFirstOccurrence(name: "payment_failed") == true)
        #expect(await tracker.markFirstOccurrence(name: "api_timeout") == true)
        // Both are now seen — repeats return false regardless of order.
        #expect(await tracker.markFirstOccurrence(name: "payment_failed") == false)
        #expect(await tracker.markFirstOccurrence(name: "api_timeout") == false)
    }

    @Test("clear() resets the set so a name counts as a first occurrence again")
    func clearResets() async {
        let tracker = ErrorFirstOccurrenceTracker()
        #expect(await tracker.markFirstOccurrence(name: "payment_failed") == true)
        #expect(await tracker.markFirstOccurrence(name: "payment_failed") == false)
        await tracker.clear()
        #expect(await tracker.markFirstOccurrence(name: "payment_failed") == true)
    }
}

// MARK: - Buffer firstOccurrences Rollup

@Suite("Error Reach — Buffer firstOccurrences rollup")
struct ErrorReachBufferTests {

    private let testContext = TracklessEventContext(platform: "ios")

    @Test("addCountable sums firstOccurrences across a first occurrence and a repeat")
    func sumsFirstOccurrenceWithRepeat() async {
        let buffer = EventBuffer()
        await buffer.add(TracklessEvent(
            type: .error,
            name: "payment_failed",
            firstOccurrences: 1,
            severity: .error
        ))
        // Repeat — firstOccurrences nil.
        await buffer.add(TracklessEvent(type: .error, name: "payment_failed", severity: .error))

        let size = await buffer.totalSize
        #expect(size == 1)

        let payloads = await buffer.drain(environment: "production", context: testContext)
        let event = payloads[0].events[0]
        #expect(event.count == 2)
        #expect(event.firstOccurrences == 1)
    }

    @Test("addCountable sums two firstOccurrences across a session boundary")
    func sumsTwoFirstOccurrences() async {
        // firstOccurrences:1 in one session, then again after a new session, both landing
        // in the same rollup key before the buffer drains (a flush was held off, e.g. by
        // the circuit breaker). A payload may legitimately carry firstOccurrences:2 with
        // a larger count.
        let buffer = EventBuffer()
        await buffer.add(TracklessEvent(
            type: .error,
            name: "payment_failed",
            count: 4,
            firstOccurrences: 1,
            severity: .error
        ))
        await buffer.add(TracklessEvent(
            type: .error,
            name: "payment_failed",
            count: 3,
            firstOccurrences: 1,
            severity: .error
        ))

        let payloads = await buffer.drain(environment: "production", context: testContext)
        #expect(payloads[0].events[0].count == 7)
        #expect(payloads[0].events[0].firstOccurrences == 2)
    }

    @Test("Repeat-only error entry drains without firstOccurrences (never 0)")
    func repeatOnlyNoFirstOccurrences() async {
        let buffer = EventBuffer()
        // No firstOccurrences on either.
        await buffer.add(TracklessEvent(type: .error, name: "payment_failed", severity: .error))
        await buffer.add(TracklessEvent(type: .error, name: "payment_failed", severity: .error))

        let payloads = await buffer.drain(environment: "production", context: testContext)
        let event = payloads[0].events[0]
        #expect(event.count == 2)
        #expect(event.firstOccurrences == nil)
    }

    @Test("Different-code variant after a first occurrence carries no firstOccurrences")
    func differentCodeNoFirstOccurrences() async {
        // Name-only dedup: the first error("payment_failed") got firstOccurrences:1 on the
        // code-less variant; a later payment_failed/etimedout is a separate rollup entry
        // with no first occurrence of its own.
        let buffer = EventBuffer()
        await buffer.add(TracklessEvent(
            type: .error,
            name: "payment_failed",
            firstOccurrences: 1,
            severity: .error
        ))
        await buffer.add(TracklessEvent(
            type: .error,
            name: "payment_failed",
            severity: .error,
            code: "etimedout"
        ))

        let size = await buffer.totalSize
        #expect(size == 2)

        let payloads = await buffer.drain(environment: "production", context: testContext)
        let base = payloads[0].events.first(where: { $0.code == nil })
        let coded = payloads[0].events.first(where: { $0.code == "etimedout" })
        #expect(base?.firstOccurrences == 1)
        #expect(coded?.firstOccurrences == nil)
    }
}

// MARK: - Wire Encoding

@Suite("Error Reach — Wire encoding")
struct ErrorReachEncodingTests {

    @Test("firstOccurrences is omitted from JSON when nil")
    func omitsWhenNil() throws {
        let event = TracklessEvent(type: .error, name: "payment_failed", count: 3, severity: .error)
        let data = try JSONEncoder().encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["count"] as? Int == 3)
        #expect(json.keys.contains("firstOccurrences") == false)
    }

    @Test("firstOccurrences is encoded when >= 1")
    func encodesWhenPresent() throws {
        let event = TracklessEvent(
            type: .error,
            name: "payment_failed",
            count: 5,
            firstOccurrences: 2,
            severity: .error
        )
        let data = try JSONEncoder().encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["firstOccurrences"] as? Int == 2)
    }
}

// MARK: - recordError Integration

@Suite("Error Reach — recordError integration")
struct ErrorReachIntegrationTests {

    /// A severity an already-installed app may still send. Built from the raw
    /// value so these tests keep exercising the legacy input without naming a
    /// deprecated enum case (which would warn on every build).
    static let legacyWarning = TracklessErrorSeverity(rawValue: "warning")!

    /// A configured state with a long flush interval so the periodic timer never fires
    /// during the test. Tests must call `setEnabled(false)` at the end to cancel the
    /// timer cleanly.
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

    private func errorEvent(in events: [TracklessEvent], name: String) -> TracklessEvent? {
        events.first(where: { $0.type == .error && $0.name == name })
    }

    @Test("First error() carries firstOccurrences:1; a repeat in the same session does not")
    func firstOccurrenceSetOnError() async {
        let state = await makeConfiguredState()

        await state.recordError(name: "payment_failed", severity: .error, code: nil)
        var events = await state.drainBufferForTesting()
        #expect(errorEvent(in: events, name: "payment_failed")?.firstOccurrences == 1)

        await state.recordError(name: "payment_failed", severity: .error, code: nil)
        events = await state.drainBufferForTesting()
        #expect(errorEvent(in: events, name: "payment_failed")?.firstOccurrences == nil)

        await state.setEnabled(false)
    }

    @Test("Dedup keys on the normalized name")
    func dedupUsesNormalizedName() async {
        let state = await makeConfiguredState()

        // "Payment Failed" and "payment_failed" normalize to the same name — the second is
        // a repeat, not a new first occurrence.
        await state.recordError(name: "Payment Failed", severity: .error, code: nil)
        var events = await state.drainBufferForTesting()
        #expect(errorEvent(in: events, name: "payment_failed")?.firstOccurrences == 1)

        await state.recordError(name: "payment_failed", severity: .error, code: nil)
        events = await state.drainBufferForTesting()
        #expect(errorEvent(in: events, name: "payment_failed")?.firstOccurrences == nil)

        await state.setEnabled(false)
    }

    @Test("Dedup ignores severity and code — only the first occurrence is marked")
    func dedupIgnoresSeverityAndCode() async {
        let state = await makeConfiguredState()

        // `legacyWarning` is spelled through `rawValue` rather than `.warning`
        // so this test exercises what an installed app still sends without
        // naming the deprecated case.
        await state.recordError(name: "payment_failed", severity: .error, code: "e500")
        await state.recordError(name: "payment_failed", severity: Self.legacyWarning, code: "etimedout")
        let events = await state.drainBufferForTesting()

        let marked = events.filter { $0.type == .error && $0.firstOccurrences != nil }
        #expect(marked.count == 1)
        #expect(marked.first?.code == "e500")

        await state.setEnabled(false)
    }

    @Test("Distinct error names each get their own first occurrence")
    func distinctNamesEachFirstOccurrence() async {
        let state = await makeConfiguredState()

        await state.recordError(name: "payment_failed", severity: .error, code: nil)
        await state.recordError(name: "api_timeout", severity: Self.legacyWarning, code: nil)
        let events = await state.drainBufferForTesting()
        #expect(errorEvent(in: events, name: "payment_failed")?.firstOccurrences == 1)
        #expect(errorEvent(in: events, name: "api_timeout")?.firstOccurrences == 1)

        await state.setEnabled(false)
    }

    @Test("Non-error events never carry firstOccurrences")
    func otherEventsHaveNoFirstOccurrences() async {
        let state = await makeConfiguredState()

        await state.recordEvent(type: .feature, name: "export")
        await state.recordEvent(type: .view, name: "home")
        let events = await state.drainBufferForTesting()
        #expect(events.allSatisfy { $0.type == .error || $0.firstOccurrences == nil })

        await state.setEnabled(false)
    }

    @Test("First-occurrence set survives a mid-session flush but resets on session end")
    func setSurvivesFlushResetsOnSessionEnd() async {
        let state = await makeConfiguredState()

        // First occurrence in the session.
        await state.recordError(name: "payment_failed", severity: .error, code: nil)
        var events = await state.drainBufferForTesting() // simulates a mid-session flush drain
        #expect(errorEvent(in: events, name: "payment_failed")?.firstOccurrences == 1)

        // Same session, after the flush: the set survived, so this is not a first occurrence.
        await state.recordError(name: "payment_failed", severity: .error, code: nil)
        events = await state.drainBufferForTesting()
        #expect(errorEvent(in: events, name: "payment_failed")?.firstOccurrences == nil)

        // Session ends → the set clears. The next occurrence is a first occurrence again.
        await state.endSessionForTesting()
        await state.recordError(name: "payment_failed", severity: .error, code: nil)
        events = await state.drainBufferForTesting()
        #expect(errorEvent(in: events, name: "payment_failed")?.firstOccurrences == 1)

        await state.setEnabled(false)
    }
}
