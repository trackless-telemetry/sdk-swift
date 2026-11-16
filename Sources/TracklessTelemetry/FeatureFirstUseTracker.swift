import Foundation

/// In-memory per-session first-use tracker for feature events.
///
/// Records which normalized feature names have been used at least once in the
/// current session, so the first `feature(name)` call in a session can be marked
/// with `firstUses: 1` (feeding server-side session-reach counts) and repeats are
/// not. Dedup is keyed on the normalized feature **name only**, not `(name, detail)`
/// — a session that exercises several detail variants still contributes exactly one
/// first-use (see feature-reach spec §25.4.1).
///
/// Zero persistence — all state is in-memory only. Cleared on session end, and NOT
/// on buffer flush (the buffer drains mid-session; this set must survive those
/// drains).
actor FeatureFirstUseTracker {

    /// Normalized feature names seen at least once in the current session.
    private var seen: Set<String> = []

    init() {}

    /// Check and record the first use of a feature name for the current session.
    ///
    /// - Returns: true if this is the first use of `name` this session, false if the
    ///   name was already used.
    func markFirstUse(name: String) -> Bool {
        // `Set.insert` returns `.inserted == true` only for a newly added element.
        seen.insert(name).inserted
    }

    /// Clear all first-use state (call on session end, NOT on flush).
    func clear() {
        seen.removeAll()
    }
}
