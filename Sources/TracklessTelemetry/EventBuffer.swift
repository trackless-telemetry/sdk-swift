import Foundation

/// Thread-safe in-memory event buffer with client-side rollup.
///
/// Count-aggregatable events (feature, view, error, event)
/// are rolled up by key. Performance events append to durations[].
/// Non-aggregatable events (funnel, session start/end) are appended individually.
///
/// Uses Swift actor for thread safety (Swift 6 strict concurrency).
actor EventBuffer {

    /// Default max unique items in the buffer.
    static let defaultMaxItems = 1000

    /// Max events per flush payload.
    static let maxEventsPerFlush = 100

    /// Max serialized payload size in bytes — matches the server's request body limit.
    static let maxPayloadBytes = 50 * 1024

    /// Aggregated events keyed by rollup key.
    private var aggregated: [String: TracklessEvent] = [:]
    /// Non-aggregatable events (funnel steps, session start/end).
    private var individual: [TracklessEvent] = []
    private let maxItems: Int

    /// The payload `date` for `instant`: the local calendar day, `yyyy-MM-dd`.
    ///
    /// Static so the uncaught-exception path, which cannot reach this actor,
    /// stamps its payload by the same rule.
    static func payloadDate(for instant: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: instant)
    }

    init(maxItems: Int = EventBuffer.defaultMaxItems) {
        self.maxItems = maxItems
    }

    /// Add an event to the buffer. Returns true if accepted.
    @discardableResult
    func add(_ event: TracklessEvent) -> Bool {
        // Non-aggregatable types go to individual list
        if event.type == .funnel || (event.type == .session && event.name != "duration") {
            if totalSize >= maxItems { return false }
            individual.append(event)
            return true
        }

        // Performance events aggregate durations
        if event.type == .performance {
            return addPerformance(event)
        }

        // Count-aggregatable events
        return addCountable(event)
    }

    private func addCountable(_ event: TracklessEvent) -> Bool {
        let key = rollupKey(event)

        if var existing = aggregated[key] {
            existing.count = (existing.count ?? 1) + (event.count ?? 1)
            existing.firstUses = Self.sumFirstMarkers(existing.firstUses, event.firstUses)
            existing.firstOccurrences = Self.sumFirstMarkers(
                existing.firstOccurrences,
                event.firstOccurrences
            )
            aggregated[key] = existing
            return true
        }

        if totalSize >= maxItems { return false }

        var newEvent = event
        newEvent.count = event.count ?? 1
        // firstUses / firstOccurrences are copied through as-is (nil unless this was a
        // session's first use / first occurrence). Neither is ever coerced to 0 — a 0 on
        // the wire is rejected by the backend.
        aggregated[key] = newEvent
        return true
    }

    /// Sum two optional first-marker values (`firstUses` for features,
    /// `firstOccurrences` for errors), treating `nil` as 0. Returns `nil` when the total
    /// is 0 so the field stays absent on the wire (only the owning event type ever
    /// carries it, and a merged repeat-only entry must not encode a `0`).
    private static func sumFirstMarkers(_ lhs: Int?, _ rhs: Int?) -> Int? {
        let total = (lhs ?? 0) + (rhs ?? 0)
        return total > 0 ? total : nil
    }

    private func addPerformance(_ event: TracklessEvent) -> Bool {
        let key = rollupKey(event)

        if var existing = aggregated[key] {
            var durations = existing.durations ?? []
            if let d = event.duration {
                durations.append(d)
            } else if let ds = event.durations {
                durations.append(contentsOf: ds)
            }
            existing.durations = durations
            existing.duration = nil
            aggregated[key] = existing
            return true
        }

        if totalSize >= maxItems { return false }

        var newEvent = event
        if let d = newEvent.duration {
            newEvent.durations = [d]
            newEvent.duration = nil
        } else if newEvent.durations == nil {
            newEvent.durations = []
        }
        aggregated[key] = newEvent
        return true
    }

    /// Drain the buffer into TracklessEventPayloads and clear it.
    func drain(environment: String, context: TracklessEventContext) -> [TracklessEventPayload] {
        let allEvents = Array(aggregated.values) + individual
        aggregated.removeAll()
        individual.removeAll()

        guard !allEvents.isEmpty else { return [] }

        let date = Self.payloadDate(for: Date())
        var payloads: [TracklessEventPayload] = []

        var i = 0
        while i < allEvents.count {
            let end = min(i + Self.maxEventsPerFlush, allEvents.count)
            let chunk = Array(allEvents[i..<end])
            payloads.append(TracklessEventPayload(
                date: date,
                environment: environment,
                context: context,
                events: chunk
            ))
            i = end
        }

        return payloads
    }

    /// Split a payload into payloads that each fit within the serialized size limit.
    ///
    /// If the encoded payload exceeds `limit`, its events are split in half and each
    /// half is retried recursively. A single-event payload that still exceeds the
    /// limit is returned in `dropped` — the caller decides how to report it. The
    /// wire format is unchanged: every returned payload is a complete
    /// `TracklessEventPayload` with the same date, environment, and context.
    static func splitBySize(
        _ payload: TracklessEventPayload,
        limit: Int = EventBuffer.maxPayloadBytes
    ) -> (payloads: [TracklessEventPayload], dropped: [TracklessEvent]) {
        guard let encoded = try? JSONEncoder().encode(payload) else {
            // Encoding failures surface through the HTTP layer; pass through unchanged.
            return ([payload], [])
        }
        if encoded.count <= limit {
            return ([payload], [])
        }
        guard payload.events.count > 1 else {
            return ([], payload.events)
        }

        let mid = payload.events.count / 2
        let halves = [Array(payload.events[..<mid]), Array(payload.events[mid...])]
        var payloads: [TracklessEventPayload] = []
        var dropped: [TracklessEvent] = []
        for half in halves {
            let result = splitBySize(
                TracklessEventPayload(
                    date: payload.date,
                    environment: payload.environment,
                    context: payload.context,
                    events: half
                ),
                limit: limit
            )
            payloads.append(contentsOf: result.payloads)
            dropped.append(contentsOf: result.dropped)
        }
        return (payloads, dropped)
    }

    /// Clear the buffer without draining.
    func clear() {
        aggregated.removeAll()
        individual.removeAll()
    }

    /// Total number of unique items in the buffer.
    var totalSize: Int {
        aggregated.count + individual.count
    }

    /// Check if the buffer is empty.
    var isEmpty: Bool {
        totalSize == 0
    }

    /// Build the rollup key for count-aggregatable events.
    private func rollupKey(_ event: TracklessEvent) -> String {
        switch event.type {
        case .feature, .view:
            return "\(event.type.rawValue)|\(event.name)|\(event.detail ?? "")"
        case .error:
            return "\(event.type.rawValue)|\(event.name)|\(event.severity?.rawValue ?? "")|\(event.code ?? "")"
        case .performance:
            let thresholdStr = event.threshold.map { String($0) } ?? ""
            return "\(event.type.rawValue)|\(event.name)|\(thresholdStr)"
        case .session:
            return "\(event.type.rawValue)|\(event.name)"
        case .funnel:
            return "\(event.type.rawValue)|\(event.name)|\(event.step ?? "")"
        }
    }
}
