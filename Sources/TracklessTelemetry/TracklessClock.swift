import Foundation

/// The clock the session lifecycle reads, behind one injectable seam.
///
/// It is the wall clock, deliberately, and it answers two questions: how long a
/// session lasted, and how long the app has been idle. An idle deadline must be
/// wall time — a Mac that sleeps for two hours has been idle for two hours,
/// whether or not the CPU was running — so the only question was whether
/// *duration* deserved a second, monotonic clock beside it.
///
/// It does not. A monotonic clock on Apple platforms means
/// `ProcessInfo.systemUptime` or `mach_absolute_time`, which are system-boot-time
/// APIs: Apple requires a declared reason for them because the boot instant is a
/// cross-app device-correlation vector. This SDK would only ever transmit a
/// difference, never the absolute value, so the use would be benign and
/// declarable — but "reads no boot-time API at all" is a stronger and simpler
/// thing to be able to say, and what it costs is small:
///
/// - Sleep during a session is already excluded on macOS, because the duration
///   truncates when the app resigns active, and a Mac going to sleep resigns the
///   frontmost app to the login window under the default "require password after
///   sleep" setting.
/// - A clock that jumps is handled by clamping in `SessionManager.end()`, and a
///   duration is bucketed server-side into ranges topping out at 30 minutes, so
///   an inflated value lands in the bucket it would have reached anyway.
///
/// What remains is a narrow case — the lid closed while the app is frontmost on a
/// Mac configured not to ask for a password on wake — where a session's duration
/// counts sleep it should not. That is the price, and it is the right one to pay.
protocol TracklessClock: Sendable {
    /// Wall-clock now.
    var now: Date { get }
}

/// The production clock: `Date()`.
struct SystemClock: TracklessClock {
    var now: Date { Date() }
}
