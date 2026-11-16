import Testing
import Foundation
@testable import TracklessTelemetry

@Suite("Trackless Static API Tests")
struct TracklessClientTests {

    // MARK: - EventBuffer Unit Tests (used by the static API)

    @Test("EventBuffer: feature events aggregate count")
    func featureEventsAggregate() async {
        let buffer = EventBuffer()
        await buffer.add(TracklessEvent(type: .feature, name: "export_clicked"))
        await buffer.add(TracklessEvent(type: .feature, name: "export_clicked"))
        await buffer.add(TracklessEvent(type: .feature, name: "export_clicked"))

        let payloads = await buffer.drain(
            environment: "production",
            context: TracklessEventContext(platform: "ios")
        )
        #expect(payloads[0].events[0].count == 3)
    }

    @Test("EventBuffer: view events aggregate count")
    func viewEventsAggregate() async {
        let buffer = EventBuffer()
        await buffer.add(TracklessEvent(type: .view, name: "home"))
        await buffer.add(TracklessEvent(type: .view, name: "home"))

        let payloads = await buffer.drain(
            environment: "production",
            context: TracklessEventContext(platform: "ios")
        )
        #expect(payloads[0].events[0].count == 2)
    }

    @Test("EventBuffer: view events with detail aggregate separately")
    func viewEventsWithDetailAggregate() async {
        let buffer = EventBuffer()
        await buffer.add(TracklessEvent(type: .view, name: "settings", detail: "profile"))
        await buffer.add(TracklessEvent(type: .view, name: "settings", detail: "profile"))
        await buffer.add(TracklessEvent(type: .view, name: "settings"))

        let size = await buffer.totalSize
        #expect(size == 2)
    }

    @Test("EventBuffer: feature events with detail aggregate separately")
    func featureEventsWithDetailAggregate() async {
        let buffer = EventBuffer()
        await buffer.add(TracklessEvent(type: .feature, name: "export", detail: "csv"))
        await buffer.add(TracklessEvent(type: .feature, name: "export", detail: "csv"))
        await buffer.add(TracklessEvent(type: .feature, name: "export"))

        let size = await buffer.totalSize
        #expect(size == 2)
    }

    @Test("EventBuffer: error events aggregate by severity+code")
    func errorEventsAggregate() async {
        let buffer = EventBuffer()
        // The buffer keys on whatever severity it is handed. `recordError` maps
        // before it gets here, so in practice this is `.error` or `.info`; the
        // rollup key itself is severity-agnostic and tested as such.
        await buffer.add(TracklessEvent(type: .error, name: "crash", severity: .error, code: "E001"))
        await buffer.add(TracklessEvent(type: .error, name: "crash", severity: .error, code: "E001"))
        // Different code = different entry
        await buffer.add(TracklessEvent(type: .error, name: "crash", severity: .error, code: "E002"))

        let size = await buffer.totalSize
        #expect(size == 2)
    }

    @Test("EventBuffer: view events with nil detail use empty string in rollup key")
    func viewEventsNilDetail() async {
        let buffer = EventBuffer()
        await buffer.add(TracklessEvent(type: .view, name: "home"))
        await buffer.add(TracklessEvent(type: .view, name: "home"))

        let size = await buffer.totalSize
        #expect(size == 1)

        let payloads = await buffer.drain(
            environment: "production",
            context: TracklessEventContext(platform: "ios")
        )
        #expect(payloads[0].events[0].count == 2)
        #expect(payloads[0].events[0].detail == nil)
    }

    // MARK: - Session Manager

    @Test("SessionManager tracks duration and depth")
    func sessionDurationAndDepth() async {
        let session = SessionManager()
        let started = await session.start()
        #expect(started == true)

        await session.recordActivity()
        await session.recordActivity()
        await session.recordActivity()

        let result = await session.end()
        #expect(result != nil)
        #expect(result?.depth == 3)
        #expect((result?.duration ?? -1) >= 0)
    }

    @Test("SessionManager start returns false if already active")
    func sessionStartIdempotent() async {
        let session = SessionManager()
        let first = await session.start()
        #expect(first == true)
        let second = await session.start()
        #expect(second == false)
    }

    @Test("SessionManager end returns nil if no active session")
    func sessionEndNoSession() async {
        let session = SessionManager()
        let result = await session.end()
        #expect(result == nil)
    }

    // MARK: - Event Payload Structure

    @Test("TracklessEventPayload encodes to correct JSON structure")
    func payloadEncoding() throws {
        let payload = TracklessEventPayload(
            date: "2026-03-14",
            environment: "sandbox",
            context: TracklessEventContext(platform: "ios", osVersion: "17.0"),
            events: [
                TracklessEvent(type: .feature, name: "export_clicked", count: 3),
                TracklessEvent(type: .view, name: "home", count: 1),
            ]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["date"] as? String == "2026-03-14")
        #expect(json["environment"] as? String == "sandbox")

        let context = json["context"] as? [String: Any]
        #expect(context?["platform"] as? String == "ios")

        let events = json["events"] as? [[String: Any]]
        #expect(events?.count == 2)
    }

    // MARK: - Environment

    @Test("Environment auto-detection returns sandbox in DEBUG builds")
    func environmentDetection() {
        let env = Trackless.detectEnvironment()
        #if DEBUG
        #expect(env == .sandbox)
        #else
        #expect(env == .production)
        #endif
    }

    // MARK: - TracklessError Cases

    @Test("TracklessError.flushRejected carries status code and body")
    func flushRejectedErrorCase() {
        let error = TracklessError.flushRejected(statusCode: 429, body: "Rate limited")
        if case .flushRejected(let code, let body) = error {
            #expect(code == 429)
            #expect(body == "Rate limited")
        } else {
            Issue.record("Expected flushRejected case")
        }
    }

    @Test("TracklessError.flushFailed carries status code")
    func flushFailedErrorCase() {
        let error = TracklessError.flushFailed(statusCode: 503)
        if case .flushFailed(let code) = error {
            #expect(code == 503)
        } else {
            Issue.record("Expected flushFailed case")
        }
    }

    // MARK: - Feature Validator (unchanged, verify still works with new types)

    @Test("Valid event names pass validation")
    func validNames() {
        #expect(FeatureValidator.isValid("export_clicked") == true)
        #expect(FeatureValidator.isValid("theme.dark") == true)
        #expect(FeatureValidator.isValid("a") == true)
    }

    @Test("Invalid event names fail validation")
    func invalidNames() {
        #expect(FeatureValidator.isValid("") == false)
        #expect(FeatureValidator.isValid("has space") == false)
        #expect(FeatureValidator.isValid(".starts_with_dot") == false)
        #expect(FeatureValidator.isValid(String(repeating: "a", count: 101)) == false)
    }
}

// MARK: - Test Helpers

/// Thread-safe error collector for async tests.
final class ErrorHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _errors: [Error] = []

    var errors: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return _errors
    }

    func record(_ error: Error) {
        lock.lock()
        _errors.append(error)
        lock.unlock()
    }
}
