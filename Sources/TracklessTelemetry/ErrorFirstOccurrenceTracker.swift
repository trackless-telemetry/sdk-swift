import Foundation

/// In-memory per-session first-occurrence tracker for error and info events.
///
/// Records which normalized names have occurred at least once in the current
/// session, so the first `error(name)` or `info(name)` call in a session can be
/// marked with `firstOccurrences: 1` (feeding server-side session-reach counts)
/// and repeats are not. Dedup is keyed on the normalized **name only**, not
/// `(name, severity, code)` — a session that reports the same name with several
/// codes still contributes exactly one first occurrence, mirroring the name-only
/// dedup `FeatureFirstUseTracker` applies to `(name, detail)`. `error()` and
/// `info()` share this set, which is why a name must not be shared between them.
///
/// Zero persistence — all state is in-memory only. Mirrors `FeatureFirstUseTracker`:
/// cleared on session end, and NOT on buffer flush (the buffer drains mid-session;
/// this set must survive those drains).
actor ErrorFirstOccurrenceTracker {

    /// Normalized error names seen at least once in the current session.
    private var seen: Set<String> = []

    init() {}

    /// Check and record the first occurrence of an error name for the current session.
    ///
    /// - Returns: true if this is the first occurrence of `name` this session, false if
    ///   the name has already occurred.
    func markFirstOccurrence(name: String) -> Bool {
        // `Set.insert` returns `.inserted == true` only for a newly added element.
        seen.insert(name).inserted
    }

    /// Clear all first-occurrence state (call on session end, NOT on flush).
    func clear() {
        seen.removeAll()
    }
}
