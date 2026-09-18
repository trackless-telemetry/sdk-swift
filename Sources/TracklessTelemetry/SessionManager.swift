import Foundation

/// In-memory session state manager.
///
/// Tracks session start time and depth (number of non-session events).
///
/// Zero persistence — all state is in-memory only.
actor SessionManager {

    private let clock: TracklessClock

    /// When the session started, on the wall clock (see `TracklessClock`).
    private var startedAt: Date?

    /// Where the duration is truncated, if the app has gone inactive without the
    /// session having ended yet (macOS idle window). `nil` means "still running,
    /// measure to now".
    private var inactiveAt: Date?

    /// The longest duration this reports. A session cannot plausibly run for a
    /// day — the wall clock jumping is the only way to compute one — and the
    /// server buckets everything past 30 minutes together, so clamping here
    /// discards a clock artifact without discarding any real measurement.
    static let maxPlausibleDuration: TimeInterval = 86_400

    private var depth: Int = 0
    private var active: Bool = false

    init(clock: TracklessClock = SystemClock()) {
        self.clock = clock
    }

    /// Start a new session. Returns true if a new session was started.
    func start() -> Bool {
        if active { return false }

        startedAt = clock.now
        inactiveAt = nil
        depth = 0
        active = true
        return true
    }

    /// Record activity (non-session event). Increments depth.
    func recordActivity() {
        guard active else { return }
        depth += 1
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
        guard active, inactiveAt == nil else { return }
        inactiveAt = clock.now
    }

    /// Clear the truncation mark — the app became active again inside the idle
    /// window, so the session continues and the interior gap counts toward it.
    func clearInactiveMark() {
        inactiveAt = nil
    }

    /// Whether a truncation mark is currently set.
    var isMarkedInactive: Bool {
        inactiveAt != nil
    }

    /// When the truncation mark was set, or nil without one. Lets the client
    /// rebuild an idle window that was cancelled while the mark was still held.
    var inactiveSince: Date? {
        inactiveAt
    }

    /// End the current session. Returns duration in seconds and depth, or nil.
    func end() -> (duration: Int, depth: Int)? {
        guard active, let start = startedAt else { return nil }

        active = false
        let stop = inactiveAt ?? clock.now
        inactiveAt = nil
        // Clamped at both ends because this is the wall clock: an NTP correction
        // or a user changing the time can run it backwards, which would otherwise
        // report a negative duration, or forwards, which would report a session
        // lasting a year. See `TracklessClock` for why a monotonic clock is not
        // used instead.
        let elapsed = min(
            SessionManager.maxPlausibleDuration,
            max(0, stop.timeIntervalSince(start))
        )
        return (duration: Int(elapsed.rounded()), depth: depth)
    }

    /// Whether a session is currently active.
    var isActive: Bool {
        active
    }

    /// Current session depth.
    var currentDepth: Int {
        depth
    }

    /// Clean up.
    func destroy() {
        active = false
    }
}
