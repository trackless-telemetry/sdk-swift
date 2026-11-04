import Foundation

/// The open timers behind `Trackless.startTimer(_:)` / `stopTimer(_:thresholdSeconds:)`,
/// in memory only.
///
/// **Synchronous and lock-guarded, not actor-isolated.** Every other public
/// method hands its work to an unstructured `Task`, and Swift does not run two
/// tasks in creation order — harmless for counters, fatal for a timer: a
/// `stopTimer` task that ran before its `startTimer` task would find nothing,
/// and the start would then leave a timer open forever. Reading the clock and
/// the map on the caller's thread is what makes start, stop and cancel happen
/// in the order they were called. Only the send that follows a stop hops onto
/// the state actor.
///
/// **Clock.** The same wall clock the session reads (`TracklessClock`, which is
/// `Date()` in production). A monotonic source on Apple platforms is a
/// required-reason boot-time API; see `TracklessClock` for why the SDK reads
/// none. A clock that jumps can make an elapsed time negative or huge, which is
/// why the state actor drops anything outside `0...maxElapsedSeconds`.
///
/// **Discard.** Session end, `setEnabled(false)`, a reconfigure and `destroy()`
/// discard every open timer: a timer that spans a background would measure time
/// the app was not running. Each start (and each `measure` call) takes a
/// sequence number; a discard records the highest sequence number it covers, so
/// a `measure` whose body was running when the session ended is dropped too.
final class OpenTimers: @unchecked Sendable {

    /// At most this many timers are open at once. A start past it is ignored.
    static let maxOpen = 50

    /// Elapsed times above this — one day — are dropped as a clock jump.
    static let maxElapsedSeconds: TimeInterval = 86_400

    /// A started timer, or the start of one `measure` call.
    struct Start: Sendable {
        let at: Date
        let sequence: UInt64
    }

    enum StartResult: Equatable {
        case started
        case restarted
        /// The cap was reached and the start ignored. `shouldWarn` is true the
        /// first time this happens since the last discard.
        case capReached(shouldWarn: Bool)
    }

    private let lock = NSLock()
    private let clock: TracklessClock
    private var open: [String: Start] = [:]
    private var sequence: UInt64 = 0
    private var discardedThrough: UInt64 = 0
    private var warnedCap = false

    init(clock: TracklessClock) {
        self.clock = clock
    }

    /// Start (or restart) the timer for an already-normalized name.
    func start(_ name: String) -> StartResult {
        lock.lock()
        defer { lock.unlock() }
        let restarting = open[name] != nil
        if !restarting, open.count >= Self.maxOpen {
            let shouldWarn = !warnedCap
            warnedCap = true
            return .capReached(shouldWarn: shouldWarn)
        }
        sequence &+= 1
        open[name] = Start(at: clock.now, sequence: sequence)
        return restarting ? .restarted : .started
    }

    /// Close the timer for an already-normalized name and return its elapsed
    /// seconds, or nil when no timer of that name is open.
    func stop(_ name: String) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let start = open.removeValue(forKey: name) else { return nil }
        return clock.now.timeIntervalSince(start.at)
    }

    /// Drop the timer for an already-normalized name, if one is open.
    func cancel(_ name: String) {
        lock.lock()
        open.removeValue(forKey: name)
        lock.unlock()
    }

    /// Start one `measure` call. It does not enter the map and does not count
    /// toward the cap.
    func mark() -> Start {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        return Start(at: clock.now, sequence: sequence)
    }

    /// Elapsed seconds since `start`, or nil when a discard has happened since.
    func elapsed(since start: Start) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard start.sequence > discardedThrough else { return nil }
        return clock.now.timeIntervalSince(start.at)
    }

    /// The sequence number of the most recent start, for a discard that must
    /// cover only what was started before a given moment.
    var currentSequence: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return sequence
    }

    /// Discard every open timer and invalidate every `measure` in progress.
    ///
    /// - Parameter cutoff: when given, only starts with a sequence number at or
    ///   below it are discarded. `configure()` and `setEnabled(false)` capture
    ///   it on the caller's thread, so a timer started right after the call —
    ///   but before the state actor ran it — survives.
    func discardAll(through cutoff: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let through = cutoff.map { min($0, sequence) } ?? sequence
        discardedThrough = max(discardedThrough, through)
        open = open.filter { $0.value.sequence > through }
        warnedCap = false
    }

    /// Number of open timers (test support).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return open.count
    }
}
