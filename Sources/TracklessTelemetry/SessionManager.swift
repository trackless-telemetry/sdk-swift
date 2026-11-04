import Foundation

/// In-memory session state manager.
///
/// Tracks session start time and depth (number of non-session events).
///
/// Zero persistence — all state is in-memory only.
///
/// The state itself sits behind a lock rather than in actor storage, so that
/// `endNow()` can end the session **synchronously** from the uncaught-exception
/// handler, which runs on a dying thread that cannot await this actor. The
/// actor methods and `endNow()` share one record, so a session ends exactly
/// once whichever path gets there first.
actor SessionManager {

    private let clock: TracklessClock

    private struct Record {
        /// When the session started, on the wall clock (see `TracklessClock`).
        var startedAt: Date?

        /// Where the duration is truncated, if the app has gone inactive without
        /// the session having ended yet (macOS idle window). `nil` means "still
        /// running, measure to now".
        var inactiveAt: Date?

        var depth: Int = 0
        var active: Bool = false
    }

    /// The record and its lock. `@unchecked Sendable` because every access to
    /// `value` goes through `withRecord`, under `lock`, and the lock is never
    /// held across a suspension point or a call out of this type.
    private final class LockedRecord: @unchecked Sendable {
        let lock = NSLock()
        var value = Record()
    }

    private let storage = LockedRecord()

    /// The longest duration this reports. A session cannot plausibly run for a
    /// day — the wall clock jumping is the only way to compute one — and the
    /// server buckets everything past 30 minutes together, so clamping here
    /// discards a clock artifact without discarding any real measurement.
    static let maxPlausibleDuration: TimeInterval = 86_400

    init(clock: TracklessClock = SystemClock()) {
        self.clock = clock
    }

    private nonisolated func withRecord<T>(_ body: (inout Record) -> T) -> T {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return body(&storage.value)
    }

    /// Start a new session. Returns true if a new session was started.
    func start() -> Bool {
        let now = clock.now
        return withRecord { record in
            if record.active { return false }
            record.startedAt = now
            record.inactiveAt = nil
            record.depth = 0
            record.active = true
            return true
        }
    }

    /// Record activity (non-session event). Increments depth.
    func recordActivity() {
        withRecord { record in
            guard record.active else { return }
            record.depth += 1
        }
    }

    /// Record the point at which the session's duration stops accumulating,
    /// without ending the session.
    ///
    /// macOS only: the app resigned active and may or may not come back before
    /// the idle timeout. The duration must truncate here rather than at the
    /// timeout boundary — otherwise every macOS session would gain exactly the
    /// idle timeout, making the metric a function of a config value.
    ///
    /// Idempotent: a second resign before any reactivation keeps the first mark,
    /// so a duplicated notification cannot extend the measured session.
    func markInactive() {
        let now = clock.now
        withRecord { record in
            guard record.active, record.inactiveAt == nil else { return }
            record.inactiveAt = now
        }
    }

    /// Clear the truncation mark — the app became active again inside the idle
    /// window, so the session continues and the interior gap counts toward it.
    func clearInactiveMark() {
        withRecord { $0.inactiveAt = nil }
    }

    /// Whether a truncation mark is currently set.
    var isMarkedInactive: Bool {
        withRecord { $0.inactiveAt != nil }
    }

    /// When the truncation mark was set, or nil without one. Lets the client
    /// rebuild an idle window that was cancelled while the mark was still held.
    var inactiveSince: Date? {
        withRecord { $0.inactiveAt }
    }

    /// End the current session. Returns duration in seconds and depth, or nil.
    func end() -> (duration: Int, depth: Int)? {
        endNow()
    }

    /// `end()`, callable synchronously from any thread — the uncaught-exception
    /// handler's way to end the session it is about to report.
    nonisolated func endNow() -> (duration: Int, depth: Int)? {
        let now = clock.now
        return withRecord { record in
            guard record.active, let start = record.startedAt else { return nil }

            record.active = false
            let stop = record.inactiveAt ?? now
            record.inactiveAt = nil
            // Clamped at both ends because this is the wall clock: an NTP
            // correction or a user changing the time can run it backwards, which
            // would otherwise report a negative duration, or forwards, which
            // would report a session lasting a year. See `TracklessClock` for
            // why a monotonic clock is not used instead.
            let elapsed = min(
                SessionManager.maxPlausibleDuration,
                max(0, stop.timeIntervalSince(start))
            )
            return (duration: Int(elapsed.rounded()), depth: record.depth)
        }
    }

    /// Whether a session is currently active.
    var isActive: Bool {
        withRecord { $0.active }
    }

    /// Current session depth.
    var currentDepth: Int {
        withRecord { $0.depth }
    }

    /// Clean up.
    func destroy() {
        withRecord { $0.active = false }
    }
}
