import Foundation
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The launch-time measurement behind `measureLaunch`, once per process.
///
/// **Definition.** From the first `configure(measureLaunch: true)` to the app's
/// first `didBecomeActive` — `UIApplication.didBecomeActiveNotification` on iOS,
/// `NSApplication.didBecomeActiveNotification` on macOS. True process start
/// would need `sysctl` on the process record, which this version does not read.
///
/// **Once per process.** The probe arms at most once and measures at most once.
/// A `configure()` that runs when the app is already active (a late configure)
/// marks it finished without a measurement, because the next activation would
/// be a return from the background, not a launch.
///
/// **Cap.** A launch longer than `maxLaunchSeconds`, or one that is negative or
/// not a finite number, is dropped, not clipped, and the probe finishes. The
/// cap is also what catches a background launch: `applicationState` is not
/// read for it, because under UIScene and SwiftUI lifecycles it is not a dependable
/// signal at `configure()`, and macOS apps are routinely inactive at launch. A
/// process launched in the background (a silent push, a background refresh)
/// is suspended by iOS within about 30 seconds, so when the user opens it later
/// the first activation comes more than 60 seconds after `configure()` and
/// nothing is sent. A background launch the user opens within 60 seconds still
/// counts.
///
/// Synchronous and lock-guarded, for the same reason as `OpenTimers`: the clock
/// is read on the thread that called `configure()` and on the thread that posted
/// the activation, never inside an unordered `Task`.
final class LaunchProbe: @unchecked Sendable {

    /// A launch longer than this many seconds is dropped, not clipped.
    static let maxLaunchSeconds: TimeInterval = 60

    private enum Phase {
        case idle
        case armed(at: Date)
        case measured(TimeInterval)
        case finished
    }

    private let lock = NSLock()
    private var phase: Phase = .idle

    /// Arm the probe at `now`, unless it was ever armed this process.
    /// - Returns: true when this call armed it.
    func arm(at now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .idle = phase else { return false }
        phase = .armed(at: now)
        return true
    }

    /// The app was already active when the probe armed: nothing is measured.
    func markLate() {
        lock.lock()
        defer { lock.unlock() }
        if case .armed = phase { phase = .finished }
    }

    /// The app's first activation, at `now`. A launch outside 0 to
    /// `maxLaunchSeconds` finishes the probe with no measurement.
    /// - Returns: true when this call measured the launch.
    func activated(at now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .armed(let start) = phase else { return false }
        let seconds = now.timeIntervalSince(start)
        guard seconds.isFinite, seconds >= 0, seconds <= Self.maxLaunchSeconds else {
            phase = .finished
            return false
        }
        phase = .measured(seconds)
        return true
    }

    /// The measured launch time, handed out once.
    func takeMeasurement() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard case .measured(let seconds) = phase else { return nil }
        phase = .finished
        return seconds
    }

    /// Whether the probe is armed and waiting for the first activation (test support).
    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .armed = phase { return true }
        return false
    }
}

/// Whether the app is active, for the late-configure check and for starting the
/// hang watchdog when `configure()` runs while the app is already on screen.
enum AppActivity {

    /// Reads the state on the main thread; nil when called off it, where the
    /// caller re-reads it on the main queue instead.
    static let current: @Sendable () -> Bool? = {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { isActiveOnMain() }
    }

    /// The notification the SDK treats as "the app became active".
    static var didBecomeActive: Notification.Name? {
        #if os(iOS) || os(tvOS)
        UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        nil
        #endif
    }

    @MainActor
    private static func isActiveOnMain() -> Bool {
        #if os(iOS) || os(tvOS)
        // Looked up dynamically: `UIApplication.shared` is unavailable in app
        // extensions, and an extension has no app lifecycle to measure.
        guard let app = UIApplication.perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? UIApplication else { return false }
        return app.applicationState == .active
        #elseif os(macOS)
        // `NSApp` is nil until the shared application exists.
        guard let app = NSApp else { return false }
        return app.isActive
        #else
        return false
        #endif
    }
}
