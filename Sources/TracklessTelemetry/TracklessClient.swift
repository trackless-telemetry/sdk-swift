import Foundation
import os
#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Internal configuration container for the Trackless SDK.
///
/// Every field has a default so that adding one does not touch the test
/// builders that construct this type directly.
struct TracklessConfig: Sendable {
    let apiKey: String
    let endpoint: String
    let environment: TracklessEnvironment?
    let enabled: Bool
    let onError: (@Sendable (Error) -> Void)?
    let flushIntervalSeconds: TimeInterval
    let debugLogging: Bool
    let suppressWarnings: Bool
    /// macOS only. **Not** clamped here — the clamp lives at the public boundary
    /// (`Trackless.configure`), so tests constructing this type directly can
    /// drive the idle state machine with sub-second values.
    let sessionIdleTimeoutSeconds: TimeInterval
    /// Set by `Trackless.configure` when the caller's value fell outside the
    /// supported range, so the state actor can warn through the normal
    /// suppression-aware path rather than logging from a static method.
    let sessionIdleTimeoutWasClamped: Bool
    /// Send `trackless.launch` once per process. Off by default.
    let measureLaunch: Bool
    /// Threshold for `trackless.launch`; nil sends none. Validated at the
    /// public boundary, like the idle timeout.
    let launchThresholdSeconds: Double?
    /// Set by `Trackless.configure` when the caller's launch threshold was not
    /// a positive number and was ignored, so the state actor can warn.
    let launchThresholdWasIgnored: Bool
    /// Send `trackless.hang` samples from the main-thread watchdog. Off by default.
    let detectHangs: Bool
    /// Count uncaught `NSException`s as `trackless.uncaught`. Off by default.
    let captureUncaught: Bool

    init(
        apiKey: String = "",
        endpoint: String = Trackless.defaultEndpoint,
        environment: TracklessEnvironment? = nil,
        enabled: Bool = true,
        onError: (@Sendable (Error) -> Void)? = nil,
        flushIntervalSeconds: TimeInterval = 60,
        debugLogging: Bool = false,
        suppressWarnings: Bool = false,
        sessionIdleTimeoutSeconds: TimeInterval = Trackless.defaultSessionIdleTimeoutSeconds,
        sessionIdleTimeoutWasClamped: Bool = false,
        measureLaunch: Bool = false,
        launchThresholdSeconds: Double? = nil,
        launchThresholdWasIgnored: Bool = false,
        detectHangs: Bool = false,
        captureUncaught: Bool = false
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.environment = environment
        self.enabled = enabled
        self.onError = onError
        self.flushIntervalSeconds = flushIntervalSeconds
        self.debugLogging = debugLogging
        self.suppressWarnings = suppressWarnings
        self.sessionIdleTimeoutSeconds = sessionIdleTimeoutSeconds
        self.sessionIdleTimeoutWasClamped = sessionIdleTimeoutWasClamped
        self.measureLaunch = measureLaunch
        self.launchThresholdSeconds = launchThresholdSeconds
        self.launchThresholdWasIgnored = launchThresholdWasIgnored
        self.detectHangs = detectHangs
        self.captureUncaught = captureUncaught
    }
}

/// Trackless — privacy-first analytics SDK for iOS.
///
/// Static singleton API. Zero third-party dependencies — Apple system
/// frameworks only (Foundation, UIKit/AppKit). In-memory only
/// (no UserDefaults, no Keychain, no file system writes). No IDFA, no IDFV,
/// no device identifiers.
///
/// Usage:
/// ```swift
/// Trackless.configure(apiKey: "tl_xxxxxxxxxxxxxxxx")
///
/// Trackless.view("Home")
/// Trackless.feature("export", detail: "csv")
/// Trackless.error("api_timeout", code: "TIMEOUT_500")
/// Trackless.info("tier", detail: "paid")
/// ```
public final class Trackless: Sendable {

    /// Default production ingest endpoint.
    public static let defaultEndpoint = "https://api.tracklesstelemetry.com"

    /// Default macOS session idle timeout: 5 minutes.
    ///
    /// Not 30 minutes (the web convention): at that length a macOS "session"
    /// means "a workday", and every session lands in the unbounded top duration
    /// bucket. iOS's effective timeout is zero — the session ends at background.
    public static let defaultSessionIdleTimeoutSeconds: TimeInterval = 300

    /// Names starting with this are reserved for what the SDK sends itself.
    /// `performance()`, `startTimer`, `measure`, `error()` and `info()` warn
    /// once per process when given one, and send it anyway.
    static let reservedNamePrefix = "trackless."

    /// The metric `measureLaunch` sends.
    static let launchMetricName = "trackless.launch"

    /// The metric `detectHangs` sends.
    static let hangMetricName = "trackless.hang"

    /// The error name `captureUncaught` sends.
    static let uncaughtErrorName = "trackless.uncaught"

    /// Supported range for `sessionIdleTimeoutSeconds`. Values outside it are
    /// clamped, with one warning.
    static let minSessionIdleTimeoutSeconds: TimeInterval = 30
    static let maxSessionIdleTimeoutSeconds: TimeInterval = 3600

    /// Clamp a caller-supplied idle timeout into the supported range.
    ///
    /// A non-finite value is not clamped toward a bound — there is no sensible
    /// one — so it falls back to the default.
    static func clampSessionIdleTimeout(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return defaultSessionIdleTimeoutSeconds }
        return min(max(seconds, minSessionIdleTimeoutSeconds), maxSessionIdleTimeoutSeconds)
    }

    // MARK: - Singleton State

    private static let state = TracklessState()

    // MARK: - State

    /// Whether the SDK has been configured and is ready to record events.
    public static var isConfigured: Bool {
        get async { await state.isConfigured }
    }

    // MARK: - Configure

    /// Configure the SDK and start a new session.
    ///
    /// Call it once at launch. Calling it again with a different API key (or any
    /// other setting) ends the current session and sends its buffered events
    /// under the previous key before the new settings take effect; calling it
    /// again with identical settings keeps the current session and only
    /// replaces `onError`.
    ///
    /// - Parameter sessionIdleTimeoutSeconds: **macOS only.** How long the app
    ///   may sit inactive before the current session ends; the next activation
    ///   starts a fresh one. Clamped to 30–3600 seconds, with one warning when it
    ///   is. Ignored on iOS, where a session ends when the app backgrounds.
    /// - Parameter measureLaunch: Send the launch time once per process, as the
    ///   performance metric `trackless.launch`: seconds from this
    ///   `configure()` call to the app's first `didBecomeActive`. Nothing is
    ///   sent when `configure()` runs after the app is already active, or when
    ///   the launch is longer than 60 seconds, which is dropped, not clipped;
    ///   that cap is also what leaves out a background launch the user opens
    ///   later, while one opened within 60 seconds still counts. Off by
    ///   default; turning it on means declaring Performance Data on the App
    ///   Store privacy label.
    /// - Parameter launchThresholdSeconds: Optional threshold for
    ///   `trackless.launch`, so the breach count and performance alerts work on
    ///   it. A value that is not a positive number is ignored, with a warning.
    /// - Parameter detectHangs: Send each main-thread hang of 250 ms or more as
    ///   one `trackless.hang` sample, in seconds, when the main thread
    ///   recovers. The watchdog runs only while the app is active. Off by
    ///   default; turning it on means declaring Performance Data on the App
    ///   Store privacy label.
    /// - Parameter captureUncaught: Count each `NSException` the app did not
    ///   catch as `error("trackless.uncaught", code: <exception name>)`, sent
    ///   with the session's end before the process exits (waiting at most
    ///   1.5 s), then handed on to the previously installed handler. Only the
    ///   exception's name is read — no reason, user info or call stack. Most
    ///   Swift crashes (force-unwrap, `fatalError`, an index out of range) are
    ///   signals, not exceptions, and are not counted; on macOS, AppKit catches
    ///   exceptions raised during event handling. Off by default; turning it on
    ///   means declaring Crash Data on the App Store privacy label.
    public static func configure(
        apiKey: String,
        endpoint: String = Trackless.defaultEndpoint,
        environment: TracklessEnvironment? = nil,
        enabled: Bool = true,
        onError: (@Sendable (Error) -> Void)? = nil,
        flushIntervalSeconds: TimeInterval = 60,
        debugLogging: Bool = false,
        suppressWarnings: Bool = false,
        sessionIdleTimeoutSeconds: TimeInterval = Trackless.defaultSessionIdleTimeoutSeconds,
        measureLaunch: Bool = false,
        launchThresholdSeconds: Double? = nil,
        detectHangs: Bool = false,
        captureUncaught: Bool = false
    ) {
        let clampedIdleTimeout = clampSessionIdleTimeout(sessionIdleTimeoutSeconds)
        let validThreshold = launchThresholdSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        // Before the task: the launch clock starts at this call, on this thread.
        if measureLaunch {
            state.armLaunch()
        }
        let config = TracklessConfig(
            apiKey: apiKey,
            endpoint: endpoint,
            environment: environment,
            enabled: enabled,
            onError: onError,
            flushIntervalSeconds: flushIntervalSeconds,
            debugLogging: debugLogging,
            suppressWarnings: suppressWarnings,
            sessionIdleTimeoutSeconds: clampedIdleTimeout,
            sessionIdleTimeoutWasClamped: clampedIdleTimeout != sessionIdleTimeoutSeconds,
            measureLaunch: measureLaunch,
            launchThresholdSeconds: validThreshold,
            launchThresholdWasIgnored: launchThresholdSeconds != nil && validThreshold == nil,
            detectHangs: detectHangs,
            captureUncaught: captureUncaught
        )
        let timerCutoff = state.timers.currentSequence
        Task {
            await state.configure(config, timerCutoff: timerCutoff)
        }
    }

    // MARK: - Event Recording

    /// Record a view event.
    public static func view(_ name: String, detail: String? = nil) {
        Task {
            await state.recordEvent(type: .view, name: name, detail: detail)
        }
    }

    /// Record a feature usage event.
    public static func feature(_ name: String, detail: String? = nil) {
        Task {
            await state.recordEvent(type: .feature, name: name, detail: detail)
        }
    }

    /// Record a funnel step.
    public static func funnel(_ funnelName: String, stepIndex: Int, step stepName: String) {
        Task {
            await state.recordFunnel(funnelName: funnelName, stepIndex: stepIndex, stepName: stepName)
        }
    }

    /// Record a performance measurement.
    ///
    /// Names starting with `trackless.` are reserved for what the SDK sends
    /// itself (`trackless.launch`, `trackless.hang`). Passing one logs a
    /// warning once per process; the measurement is still sent.
    public static func performance(_ name: String, durationSeconds: Double, thresholdSeconds: Double? = nil) {
        Task {
            await state.recordPerformance(name: name, durationSeconds: durationSeconds, thresholdSeconds: thresholdSeconds)
        }
    }

    // MARK: - Timers

    /// Start a timer for a performance measurement.
    ///
    /// The name is normalized here, exactly as `performance(_:durationSeconds:thresholdSeconds:)`
    /// normalizes its name, so `stopTimer("Checkout")` closes `startTimer("checkout")`.
    /// Starting a name that is already open restarts it. At most 50 timers are
    /// open at once; a start past that is ignored, with one warning per session.
    ///
    /// Open timers live in memory only. **Session end discards every open
    /// timer** — on iOS the session ends when the app backgrounds, on macOS when
    /// the idle timeout expires — as do `setEnabled(false)`, a `configure()` with
    /// changed settings and `destroy()`, so a timer never measures time the app
    /// was not running.
    public static func startTimer(_ name: String) {
        state.startTimer(name)
    }

    /// Stop the timer `name` and send its elapsed time, in seconds, as
    /// `performance(name, durationSeconds: elapsed, thresholdSeconds: thresholdSeconds)`.
    ///
    /// Does nothing when no timer of that name is open: never started, already
    /// stopped or cancelled, or discarded when the session ended. Elapsed time
    /// is wall-clock time; a value below zero or above a day means the clock
    /// changed while the timer ran, and is dropped.
    public static func stopTimer(_ name: String, thresholdSeconds: Double? = nil) {
        state.stopTimer(name, thresholdSeconds: thresholdSeconds)
    }

    /// Drop the timer `name` without sending anything — the operation was
    /// abandoned, or failed in a way its duration should not describe.
    public static func cancelTimer(_ name: String) {
        state.cancelTimer(name)
    }

    /// Time a synchronous closure and send its duration as a performance
    /// measurement, returning the closure's result.
    ///
    /// The measurement is sent **only when `body` returns normally**. If it
    /// throws, nothing is sent and the error is rethrown unchanged. Nothing is
    /// sent either when the session ended while `body` ran. `measure` does not
    /// use the open-timer map, so it never counts toward the 50-timer cap and
    /// any number can nest.
    ///
    /// ```swift
    /// let rows = try Trackless.measure("csv_parse", thresholdSeconds: 0.5) {
    ///     try parser.parse(file)
    /// }
    /// ```
    @discardableResult
    public static func measure<T>(
        _ name: String,
        thresholdSeconds: Double? = nil,
        _ body: () throws -> T
    ) rethrows -> T {
        try measure(on: state, name, thresholdSeconds: thresholdSeconds, body)
    }

    /// Time an asynchronous closure and send its duration as a performance
    /// measurement, returning the closure's result.
    ///
    /// The measurement is sent **only when `body` returns normally**. If it
    /// throws — including a `CancellationError` — nothing is sent and the error
    /// is rethrown unchanged. Nothing is sent either when the session ended
    /// while `body` was suspended (the app backgrounded mid-request, say).
    /// `body` runs on the caller's actor.
    ///
    /// ```swift
    /// let feed = try await Trackless.measure("feed_load", thresholdSeconds: 2.0) {
    ///     try await api.fetchFeed()
    /// }
    /// ```
    @discardableResult
    public static func measure<T>(
        _ name: String,
        thresholdSeconds: Double? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await measure(on: state, name, thresholdSeconds: thresholdSeconds, body)
    }

    /// `measure` against a given state. `onSend` receives the task recording
    /// the measurement (nil when nothing is sent), so tests can await it.
    static func measure<T>(
        on state: TracklessState,
        _ name: String,
        thresholdSeconds: Double?,
        onSend: ((Task<Void, Never>?) -> Void)? = nil,
        _ body: () throws -> T
    ) rethrows -> T {
        let start = state.timers.mark()
        let result = try body()
        let send = state.finishMeasure(name, start: start, thresholdSeconds: thresholdSeconds)
        onSend?(send)
        return result
    }

    static func measure<T>(
        on state: TracklessState,
        _ name: String,
        thresholdSeconds: Double?,
        onSend: ((Task<Void, Never>?) -> Void)? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let start = state.timers.mark()
        let result = try await body()
        let send = state.finishMeasure(name, start: start, thresholdSeconds: thresholdSeconds)
        onSend?(send)
        return result
    }

    /// Record an error event — something went wrong.
    ///
    /// Counts toward errors per session and toward every alert. Names starting
    /// with `trackless.` are reserved for what the SDK sends itself
    /// (`trackless.uncaught`): passing one logs a warning once per process,
    /// and the event is still sent.
    public static func error(_ name: String, code: String? = nil) {
        Task {
            await state.recordError(name: name, severity: .error, code: code)
        }
    }

    /// Record an error event with an explicit severity.
    @available(*, deprecated, message: "The severity parameter is deprecated. Call error(_:code:) for something that went wrong and info(_:detail:) for something that did not. `info` and `debug` are sent as `info`; every other value is sent as `error`.")
    public static func error(_ name: String, severity: TracklessErrorSeverity, code: String? = nil) {
        Task {
            await state.recordError(name: name, severity: severity, code: code)
        }
    }

    /// Record an info event — something worth counting that the user did not do
    /// and that did not go wrong.
    ///
    /// Counted separately from errors: an info event never contributes to errors
    /// per session and never triggers an alert. Report configuration many
    /// sessions share (a tier, a unit preference, a fallback path that fired),
    /// never anything about the person. Do not share a name between
    /// `error(_:code:)` and `info(_:detail:)`. Names starting with `trackless.`
    /// are reserved, as for `error(_:code:)`.
    public static func info(_ name: String, detail: String? = nil) {
        Task {
            await state.recordError(name: name, severity: .info, code: detail)
        }
    }

    /// Map a severity a caller passed to the one that goes on the wire.
    ///
    /// Mirrors `storedSeverity()` in `@trackless/shared-config`, which ingest
    /// applies on the write path — the SDK has no dependencies, so the rule
    /// lives twice on purpose. Matching on `rawValue` rather than the cases
    /// keeps the SDK's own code clear of the deprecated ones.
    static func storedSeverity(_ sent: TracklessErrorSeverity) -> TracklessErrorSeverity {
        (sent.rawValue == "info" || sent.rawValue == "debug") ? .info : .error
    }

    // MARK: - Control

    /// Force flush pending events to the ingest endpoint.
    public static func flush() async {
        await state.flush()
    }

    /// Toggle event recording. Disabling discards buffered data and drops the session without
    /// sending its end; enabling again starts a new session.
    public static func setEnabled(_ isEnabled: Bool) {
        let timerCutoff = state.timers.currentSequence
        Task {
            await state.setEnabled(isEnabled, timerCutoff: timerCutoff)
        }
    }

    /// End the session, flush remaining events and clean up. Events are dropped until `configure()` is called again.
    public static func destroy() async {
        await state.destroy()
    }

    // MARK: - Environment Auto-Detection

    /// Auto-detect from build configuration.
    static func detectEnvironment() -> TracklessEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

// MARK: - Internal State Actor

/// Manages all mutable SDK state with actor isolation for thread safety.
/// Reason text for a name that fails normalization.
///
/// Used both for the developer warning and as the associated value of
/// `TracklessError.invalidFeatureName`. It deliberately describes *why* the
/// name was rejected rather than quoting the name: normalization only fails
/// after PII stripping has run, so no PII-stripped form of the name survives.
private let invalidEventNameReason =
    "it normalized to an empty or disallowed value (raw name omitted: it may contain PII)"

/// Sends one payload to the ingest endpoint. Production uses
/// `HTTPClient.sendPayload`; tests inject a recorder.
typealias TracklessTransport = @Sendable (
    _ endpoint: String,
    _ apiKey: String,
    _ payload: TracklessEventPayload,
    _ timeoutSeconds: TimeInterval
) async throws -> SendResult

actor TracklessState {

    // Injected seams. `nonisolated let` because the lifecycle notification
    // blocks read them synchronously on the posting thread, before any hop onto
    // the actor — which is the whole point of the clock stamp (see
    // `acceptLifecycleSignal(at:)`).
    nonisolated let clock: TracklessClock
    nonisolated let notificationCenter: NotificationCenter
    nonisolated let transport: TracklessTransport
    /// Whether the app is active: `AppActivity.current` in production, which
    /// answers nil off the main thread.
    nonisolated let appIsActive: @Sendable () -> Bool?
    /// Runs a block on the main queue. Shared by the hang watchdog's ping and
    /// the main-thread re-reads of `appIsActive`.
    nonisolated let postToMain: HangWatchdog.MainScheduler

    init(
        clock: TracklessClock = SystemClock(),
        notificationCenter: NotificationCenter = .default,
        transport: @escaping TracklessTransport = { endpoint, apiKey, payload, timeoutSeconds in
            try await HTTPClient.sendPayload(
                endpoint: endpoint,
                apiKey: apiKey,
                payload: payload,
                timeoutSeconds: timeoutSeconds
            )
        },
        appIsActive: @escaping @Sendable () -> Bool? = AppActivity.current,
        postToMain: @escaping HangWatchdog.MainScheduler = HangWatchdog.mainQueue,
        hangTicker: @escaping HangWatchdog.Ticker = HangWatchdog.dispatchTicker,
        uncaughtSender: @escaping UncaughtExceptionCapture.Sender = UncaughtExceptionCapture.urlSessionSender,
        uncaughtWaitSeconds: TimeInterval = UncaughtExceptionCapture.defaultWaitSeconds,
        uncaughtHandlerSlot: any UncaughtHandlerSlot = ProcessUncaughtHandlerSlot()
    ) {
        self.clock = clock
        self.notificationCenter = notificationCenter
        self.transport = transport
        self.appIsActive = appIsActive
        self.postToMain = postToMain
        self.session = SessionManager(clock: clock)
        self.timers = OpenTimers(clock: clock)
        self.hangs = HangWatchdog(clock: clock, postToMain: postToMain, ticker: hangTicker)
        self.uncaught = UncaughtExceptionCapture(
            clock: clock,
            sender: uncaughtSender,
            waitSeconds: uncaughtWaitSeconds,
            slot: uncaughtHandlerSlot
        )
    }

    /// Open timers. Read synchronously on the caller's thread — see
    /// `OpenTimers` for why they are not actor state.
    nonisolated let timers: OpenTimers

    /// The `measureLaunch` probe. Belongs to the state, which production
    /// creates once, so it measures once per process.
    nonisolated let launch = LaunchProbe()

    /// The `detectHangs` watchdog. Started and stopped synchronously from the
    /// lifecycle notification blocks, on the main thread.
    nonisolated let hangs: HangWatchdog

    /// The `captureUncaught` handler. Its snapshot is replaced synchronously by
    /// `refreshUncaughtCapture()` whenever what a send goes out under changes.
    nonisolated let uncaught: UncaughtExceptionCapture

    /// The observer for the launch probe's first activation. Separate from
    /// `observerState`, which a reconfigure tears down: the launch clock must
    /// keep running across one.
    private nonisolated let launchObserverState = ObserverState()

    /// Set once a reserved-prefix warning has been logged (once per process).
    private nonisolated let reservedPrefixWarned = OnceFlag()

    /// Everything one flush sends under, read in a single synchronous step.
    ///
    /// A flush suspends on every send, and a `configure()` can run in that gap.
    /// Reading the key, endpoint and context once, up front, is what keeps a
    /// batch drained under one configuration from going out under the next —
    /// and it is how a re-`configure()` flushes the configuration it retires.
    private struct FlushTarget {
        let buffer: EventBuffer
        let circuitBreaker: CircuitBreaker
        let apiKey: String
        let endpoint: String
        let environment: TracklessEnvironment
        let context: TracklessEventContext
        let onError: (@Sendable (Error) -> Void)?
    }

    /// How long `applicationWillTerminate` may block the main thread waiting on
    /// the final flush.
    static let terminationWaitSeconds: TimeInterval = 2

    /// Request timeout for that final send. Shorter than the wait above, so a
    /// hung socket is never the reason the quit budget expires.
    static let terminationFlushTimeoutSeconds: TimeInterval = 1.5

    // Configuration
    private var apiKey: String = ""
    private var endpoint: String = ""
    private var environment: TracklessEnvironment = .production
    private var onError: (@Sendable (Error) -> Void)?
    private var flushIntervalSeconds: TimeInterval = 60
    private var debugLogging: Bool = false
    private var suppressWarnings: Bool = false

    /// macOS idle timeout. Unused on iOS, where background ends the session.
    private var sessionIdleTimeoutSeconds: TimeInterval = Trackless.defaultSessionIdleTimeoutSeconds

    // Opt-in SDK metrics
    private var measureLaunch: Bool = false
    private var launchThresholdSeconds: Double?
    private var detectHangs: Bool = false
    private var captureUncaught: Bool = false

    // Idle-window state (macOS)

    /// Wall-clock instant at which the open idle window expires; `nil` whenever
    /// no window is open — because the app is active, or because the window
    /// already closed and the session already ended.
    private var idleDeadline: Date?

    /// Wall-clock stamp of the most recently *processed* lifecycle signal.
    private var lastLifecycleStamp: Date = .distantPast

    // State flags
    private var enabled: Bool = false
    private var destroyed: Bool = false
    private var configured: Bool = false

    // One-shot warning flags
    private var warnedBufferFull = false
    private var warnedNotConfigured = false

    /// Test-only hook — receives each warning message that passes the suppression check.
    private var onWarning: (@Sendable (String) -> Void)?

    // Components
    private var buffer = EventBuffer()
    private var circuitBreaker = CircuitBreaker()
    private var context = TracklessEventContext(platform: ContextDetection.platform)
    private var session: SessionManager
    private var featureFirstUses = FeatureFirstUseTracker()
    private var errorFirstOccurrences = ErrorFirstOccurrenceTracker()

    // Timer and observer (non-isolated for Sendable)
    private let timerState = TimerState()
    /// A **second** timer holder for the macOS idle window. `TimerState.setTimer`
    /// cancels whatever it held, so reusing `timerState` would silently kill the
    /// periodic flush on the first resign.
    private let idleTimerState = TimerState()
    private let observerState = ObserverState()

    private let logger = Logger(subsystem: "com.trackless.sdk", category: "telemetry")

    /// Buffer flush threshold
    private let bufferFlushThreshold = 100

    var isConfigured: Bool {
        configured && !destroyed
    }

    /// Apply a configuration.
    ///
    /// A first call (or the first after `destroy()`) starts a session. A repeat
    /// call is one of two things:
    ///
    /// - **Identical settings** — an app calling `configure()` from a view or
    ///   scene that re-runs. The session and buffer stay; only `onError` is
    ///   replaced, since closures cannot be compared. Starting a new session
    ///   here would inflate the session count.
    /// - **Anything different** — typically a new API key when the user
    ///   switches organization. The running session ends, and it and everything
    ///   buffered under it are flushed under the *previous* key, endpoint,
    ///   environment, context and circuit breaker; then a new session starts
    ///   under the new settings exactly as a first call does.
    ///
    /// The previous configuration is captured and the new one installed with no
    /// suspension point in between, so an event recorded while this method is
    /// suspended always lands in the new buffer, under the new session. The
    /// retired flush is awaited last, after the new session, timer and
    /// observers are live: the actor is released while it waits on the network,
    /// so nothing recorded meanwhile is delayed, dropped or misattributed.
    ///
    /// - Parameter timerCutoff: the open-timer sequence number captured when the
    ///   caller invoked `Trackless.configure`. A changed configuration discards
    ///   the timers started up to it; nil discards every one.
    func configure(_ config: TracklessConfig, timerCutoff: UInt64? = nil) async {
        let resolvedEnvironment = config.environment ?? Trackless.detectEnvironment()

        var retired: (target: FlushTarget, session: SessionManager)?
        if configured && !destroyed {
            if hasSameSettings(config, environment: resolvedEnvironment) {
                onError = config.onError
                if debugLogging {
                    logger.info("[Trackless] configure — settings unchanged, keeping the current session")
                }
                return
            }
            // The running session is ending, so its open timers go with it.
            timers.discardAll(through: timerCutoff)
            // A disabled configuration has nothing to report: its buffer was
            // discarded, and its session must not send an end.
            if enabled {
                retired = (currentFlushTarget(), session)
            }
        }

        // Clean up previous state
        timerState.cancelTimer()
        idleTimerState.cancelTimer()
        cleanupObserver()
        hangs.disable()

        apiKey = config.apiKey
        endpoint = config.endpoint
        environment = resolvedEnvironment
        onError = config.onError
        flushIntervalSeconds = config.flushIntervalSeconds
        debugLogging = config.debugLogging
        suppressWarnings = config.suppressWarnings
        sessionIdleTimeoutSeconds = config.sessionIdleTimeoutSeconds
        measureLaunch = config.measureLaunch
        launchThresholdSeconds = config.launchThresholdSeconds
        detectHangs = config.detectHangs
        captureUncaught = config.captureUncaught
        enabled = config.enabled
        destroyed = false
        configured = true
        warnedBufferFull = false
        warnedNotConfigured = false
        idleDeadline = nil
        lastLifecycleStamp = .distantPast

        buffer = EventBuffer()
        circuitBreaker = CircuitBreaker()
        let detected = ContextDetection.detectReportingOmissions()
        context = detected.context
        for field in detected.omitted { warn(ContextDetection.omittedWarning(field)) }
        session = SessionManager(clock: clock)
        featureFirstUses = FeatureFirstUseTracker()
        errorFirstOccurrences = ErrorFirstOccurrenceTracker()
        // Before the first suspension point: from here an uncaught exception
        // goes out under the new settings and the new session, or not at all.
        refreshUncaughtCapture()

        if debugLogging {
            logger.info("[Trackless] configured — env=\(self.environment.rawValue, privacy: .public) flush=\(Int(self.flushIntervalSeconds))s")
        }

        if config.sessionIdleTimeoutWasClamped {
            warn(
                "sessionIdleTimeoutSeconds is outside \(Int(Trackless.minSessionIdleTimeoutSeconds))–"
                    + "\(Int(Trackless.maxSessionIdleTimeoutSeconds))s — clamped to "
                    + "\(Int(sessionIdleTimeoutSeconds))s"
            )
        }
        if config.launchThresholdWasIgnored {
            warn("launchThresholdSeconds is not a positive number — trackless.launch is sent without a threshold")
        }

        if enabled {
            await startNewSession()
            startPeriodicFlush()
            addLifecycleObservers()
            startHangDetectionIfWanted()
        }
        // A launch the probe measured before this configure ran (the tasks
        // behind configure and the activation are unordered) is delivered now.
        await deliverLaunch()

        if let retired {
            if let result = await retired.session.end() {
                _ = await retired.target.buffer.add(Self.sessionEndEvent(result))
            }
            await performFlush(retired.target)
            if debugLogging {
                logger.info("[Trackless] reconfigured — previous session ended and flushed under the previous settings")
            }
        }
    }

    /// Whether `config` matches the running configuration in every comparable
    /// setting. `onError` is not compared: closures have no equality.
    private func hasSameSettings(_ config: TracklessConfig, environment resolved: TracklessEnvironment) -> Bool {
        config.apiKey == apiKey
            && config.endpoint == endpoint
            && resolved == environment
            && config.enabled == enabled
            && config.flushIntervalSeconds == flushIntervalSeconds
            && config.debugLogging == debugLogging
            && config.suppressWarnings == suppressWarnings
            && config.sessionIdleTimeoutSeconds == sessionIdleTimeoutSeconds
            && config.measureLaunch == measureLaunch
            && config.launchThresholdSeconds == launchThresholdSeconds
            && config.detectHangs == detectHangs
            && config.captureUncaught == captureUncaught
    }

    private func currentFlushTarget() -> FlushTarget {
        FlushTarget(
            buffer: buffer,
            circuitBreaker: circuitBreaker,
            apiKey: apiKey,
            endpoint: endpoint,
            environment: environment,
            context: context,
            onError: onError
        )
    }

    func recordEvent(type: TracklessEventType, name: String, detail: String? = nil) async {
        guard canRecord() else {
            warnNotRecording(type: type.rawValue)
            return
        }
        guard let normalized = normalizeName(name) else { return }

        let normalizedDetail: String? = if let detail, !detail.isEmpty {
            FeatureValidator.normalize(detail)
        } else {
            nil
        }

        // Mark the first use of each feature name within the session (session reach).
        // Dedup is on the normalized name only (not name+detail) — see spec §25.4.1 —
        // so only feature events ever carry firstUses.
        var firstUses: Int?
        if type == .feature, await featureFirstUses.markFirstUse(name: normalized) {
            firstUses = 1
        }

        await session.recordActivity()
        await addToBuffer(TracklessEvent(type: type, name: normalized, firstUses: firstUses, detail: normalizedDetail))
        if debugLogging {
            if let normalizedDetail {
                logger.info("[Trackless] \(type.rawValue, privacy: .public) — \(normalized, privacy: .public) detail=\(normalizedDetail, privacy: .public)")
            } else {
                logger.info("[Trackless] \(type.rawValue, privacy: .public) — \(normalized, privacy: .public)")
            }
        }
        await checkFlushThreshold()
    }

    func recordFunnel(funnelName: String, stepIndex: Int, stepName: String) async {
        guard canRecord() else {
            warnNotRecording(type: "funnel")
            return
        }
        guard stepIndex >= 0 else { return }
        guard let normalizedFunnel = normalizeName(funnelName),
              let normalizedStep = normalizeName(stepName) else { return }

        // Every call counts, like feature(): no per-session dedup. The event is
        // never rolled up (EventBuffer appends funnel events one by one), so it
        // carries no `count` and ingest's limit of 1 on funnels holds.
        await session.recordActivity()
        await addToBuffer(TracklessEvent(
            type: .funnel,
            name: normalizedFunnel,
            step: normalizedStep,
            stepIndex: stepIndex
        ))
        if debugLogging {
            logger.info("[Trackless] funnel — \(normalizedFunnel, privacy: .public) step=\(normalizedStep, privacy: .public) index=\(stepIndex)")
        }
        await checkFlushThreshold()
    }

    func recordPerformance(name: String, durationSeconds: Double, thresholdSeconds: Double? = nil) async {
        guard canRecord() else {
            warnNotRecording(type: "performance")
            return
        }
        guard let normalized = normalizeName(name) else { return }
        warnIfReserved(normalized)
        guard durationSeconds >= 0 else {
            warnDrop("negative duration (\(durationSeconds))", type: "performance", name: normalized)
            return
        }
        await appendPerformance(normalized: normalized, durationSeconds: durationSeconds, thresholdSeconds: thresholdSeconds)
    }

    // MARK: - Timers

    /// Start (or restart) the open timer for `name`. Synchronous: the clock is
    /// read on the caller's thread, so a `stopTimer` called after it always
    /// finds it.
    ///
    /// - Returns: the task delivering a warning, when there is one (tests await
    ///   it; `Trackless.startTimer` discards it).
    @discardableResult
    nonisolated func startTimer(_ name: String) -> Task<Void, Never>? {
        guard let normalized = FeatureValidator.normalize(name) else {
            return Task { await self.reportRejectedName() }
        }
        let reserved = claimReservedWarning(normalized)
        var capWarning = false
        if case .capReached(let shouldWarn) = timers.start(normalized) {
            capWarning = shouldWarn
        }
        guard reserved || capWarning else { return nil }
        return Task {
            if reserved { await self.warnReserved(normalized) }
            if capWarning {
                await self.warn(
                    "timer \"\(normalized)\" not started — \(OpenTimers.maxOpen) timers are already open "
                        + "(logged once per session)"
                )
            }
        }
    }

    /// Close the open timer for `name` and send its elapsed time as a
    /// performance measurement. Nothing is sent when no timer of that name is
    /// open — never started, already stopped or cancelled, or discarded at
    /// session end.
    ///
    /// - Returns: the task that records the measurement, or nil when nothing is
    ///   sent.
    @discardableResult
    nonisolated func stopTimer(_ name: String, thresholdSeconds: Double? = nil) -> Task<Void, Never>? {
        guard let normalized = FeatureValidator.normalize(name),
              let elapsed = timers.stop(normalized) else { return nil }
        return Task {
            await self.recordTimer(normalizedName: normalized, elapsedSeconds: elapsed, thresholdSeconds: thresholdSeconds)
        }
    }

    /// Drop the open timer for `name` without sending anything.
    nonisolated func cancelTimer(_ name: String) {
        guard let normalized = FeatureValidator.normalize(name) else { return }
        timers.cancel(normalized)
    }

    /// Send the measurement for one `measure` call whose body returned.
    /// Nothing is sent when the session ended while the body ran.
    @discardableResult
    nonisolated func finishMeasure(
        _ name: String,
        start: OpenTimers.Start,
        thresholdSeconds: Double?
    ) -> Task<Void, Never>? {
        guard let elapsed = timers.elapsed(since: start) else { return nil }
        guard let normalized = FeatureValidator.normalize(name) else {
            return Task { await self.reportRejectedName() }
        }
        let reserved = claimReservedWarning(normalized)
        return Task {
            if reserved { await self.warnReserved(normalized) }
            await self.recordTimer(normalizedName: normalized, elapsedSeconds: elapsed, thresholdSeconds: thresholdSeconds)
        }
    }

    /// The send behind `stopTimer` and `measure`: `performance()` with an
    /// elapsed time the SDK measured. An elapsed time below zero or above a day
    /// can only come from the wall clock moving, and is dropped.
    func recordTimer(normalizedName name: String, elapsedSeconds: Double, thresholdSeconds: Double?) async {
        guard canRecord() else {
            warnNotRecording(type: "performance")
            return
        }
        guard elapsedSeconds >= 0, elapsedSeconds <= OpenTimers.maxElapsedSeconds else {
            warnDrop(
                "timer elapsed time \(elapsedSeconds)s is outside 0–\(Int(OpenTimers.maxElapsedSeconds))s "
                    + "(the clock changed while it ran)",
                type: "performance",
                name: name
            )
            return
        }
        await appendPerformance(normalized: name, durationSeconds: elapsedSeconds, thresholdSeconds: thresholdSeconds)
    }

    /// Warn and notify `onError` for a timer name that failed normalization,
    /// exactly as `performance()` does for its name.
    private func reportRejectedName() {
        warn("event name rejected — \(invalidEventNameReason)")
        onError?(TracklessError.invalidFeatureName(invalidEventNameReason))
    }

    /// Buffer one performance measurement whose name is already normalized.
    ///
    /// - Parameter countsAsActivity: false for the metrics the SDK measures
    ///   itself, which describe the app rather than anything the user did, so
    ///   they leave the session's depth alone.
    private func appendPerformance(
        normalized: String,
        durationSeconds: Double,
        thresholdSeconds: Double?,
        countsAsActivity: Bool = true
    ) async {
        if let thresholdSeconds, thresholdSeconds <= 0 { return }

        if countsAsActivity {
            await session.recordActivity()
        }
        await addToBuffer(TracklessEvent(type: .performance, name: normalized, duration: durationSeconds, threshold: thresholdSeconds))
        if debugLogging {
            let thresholdStr = thresholdSeconds.map { " threshold=\($0)s" } ?? ""
            logger.info("[Trackless] performance — \(normalized, privacy: .public) duration=\(durationSeconds)s\(thresholdStr, privacy: .public)")
        }
        await checkFlushThreshold()
    }

    // MARK: - Reserved names

    /// Whether `normalized` is a reserved name whose once-per-process warning
    /// has not been logged yet. Claims the warning when it is.
    nonisolated func claimReservedWarning(_ normalized: String) -> Bool {
        normalized.hasPrefix(Trackless.reservedNamePrefix) && reservedPrefixWarned.claim()
    }

    /// `performance()` path: warn once per process for a reserved name.
    private func warnIfReserved(_ normalized: String) {
        if claimReservedWarning(normalized) { warnReserved(normalized) }
    }

    /// - Parameter kind: the call that was given the name: "performance"
    ///   (also `startTimer` and `measure`), "error" or "info".
    private func warnReserved(_ normalized: String, kind: String = "performance") {
        warn(
            "\(kind) name \"\(normalized)\" starts with \"\(Trackless.reservedNamePrefix)\", which is "
                + "reserved for names the SDK sends itself — sent anyway (logged once)"
        )
    }

    // MARK: - Uncaught exceptions

    /// Bring the uncaught-exception handler in line with the current state:
    /// a snapshot of what a send needs while `captureUncaught` is on and the
    /// SDK is recording, none otherwise. Installs the handler the first time
    /// it is wanted; never removes it (see `UncaughtExceptionCapture`).
    ///
    /// Synchronous on purpose: callers run it with no suspension point between
    /// the state change and this, so the handler never sends under settings
    /// the SDK has already left.
    private func refreshUncaughtCapture() {
        guard captureUncaught, canRecord() else {
            uncaught.update(nil)
            return
        }
        uncaught.update(UncaughtSendSnapshot(
            endpoint: endpoint,
            apiKey: apiKey,
            environment: environment,
            context: context,
            session: session
        ))
        uncaught.installIfNeeded()
    }

    // MARK: - Launch time

    /// Arm the launch probe. Called synchronously from `Trackless.configure`
    /// on the caller's thread, so the clock starts at the call and the
    /// activation observer is in place before the configure task runs.
    ///
    /// When the app is already active, this is a late configure: the next
    /// activation would be a return from the background, so nothing is
    /// measured this process. Off the main thread the app's state cannot be
    /// read synchronously; it is re-read on the main queue, which also runs
    /// the activation notification, so the two cannot be misordered.
    nonisolated func armLaunch() {
        guard let activationName = AppActivity.didBecomeActive,
              launch.arm(at: clock.now) else { return }

        let observer = notificationCenter.addObserver(
            forName: activationName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.launchActivated()
        }
        launchObserverState.addObserver(observer)

        switch appIsActive() {
        case .some(true):
            launchWasLate()
        case .some(false):
            break
        case .none:
            postToMain { [weak self] in
                guard let self, self.appIsActive() == true else { return }
                self.launchWasLate()
            }
        }
    }

    /// The first activation after the probe armed.
    private nonisolated func launchActivated() {
        let now = clock.now
        removeLaunchObserver()
        guard launch.activated(at: now) else { return }
        Task { await self.deliverLaunch() }
    }

    private nonisolated func launchWasLate() {
        launch.markLate()
        removeLaunchObserver()
    }

    private nonisolated func removeLaunchObserver() {
        for observer in launchObserverState.removeAllObservers() {
            notificationCenter.removeObserver(observer)
        }
    }

    /// Send the launch time the probe measured, once.
    ///
    /// Before the first configure has run, the measurement is left for the
    /// configure to deliver. After that it is taken exactly once, and sent only
    /// while recording with `measureLaunch` on: a launch measured while
    /// recording is disabled, or after a reconfigure turned the option off, is
    /// dropped.
    func deliverLaunch() async {
        guard configured || destroyed else { return }
        guard let seconds = launch.takeMeasurement() else { return }
        guard canRecord(), measureLaunch else { return }
        await appendSDKMetric(Trackless.launchMetricName, seconds: seconds, thresholdSeconds: launchThresholdSeconds)
    }

    // MARK: - Hangs

    /// Switch the watchdog on when `detectHangs` is set, and start it now when
    /// the app is already active (a configure or re-enable while on screen);
    /// otherwise it starts at the next activation.
    private func startHangDetectionIfWanted() {
        guard detectHangs else { return }
        hangs.enable { [weak self] seconds in
            guard let self else { return }
            Task { await self.recordHang(seconds) }
        }
        let hangs = self.hangs
        let appIsActive = self.appIsActive
        switch appIsActive() {
        case .some(true):
            hangs.appBecameActive()
        case .some(false):
            break
        case .none:
            postToMain {
                if appIsActive() == true { hangs.appBecameActive() }
            }
        }
    }

    func recordHang(_ seconds: TimeInterval) async {
        guard canRecord(), detectHangs else { return }
        await appendSDKMetric(Trackless.hangMetricName, seconds: seconds, thresholdSeconds: nil)
    }

    /// Buffer one SDK-measured metric. Same bounds as a timer; no reserved-name
    /// warning, and no session activity.
    private func appendSDKMetric(_ name: String, seconds: TimeInterval, thresholdSeconds: Double?) async {
        guard seconds >= 0, seconds <= OpenTimers.maxElapsedSeconds else {
            warnDrop(
                "measured \(seconds)s is outside 0–\(Int(OpenTimers.maxElapsedSeconds))s (the clock changed)",
                type: "performance",
                name: name
            )
            return
        }
        await appendPerformance(
            normalized: name,
            durationSeconds: seconds,
            thresholdSeconds: thresholdSeconds,
            countsAsActivity: false
        )
    }

    /// Shared path behind `Trackless.error(_:code:)`, the deprecated
    /// `error(_:severity:code:)` and `Trackless.info(_:detail:)`.
    ///
    /// The severity is mapped to one of the two stored levels here — the single
    /// choke point — so the buffer's rollup key collapses one name reported at
    /// several legacy severities into a single entry, and nothing but `error` or
    /// `info` ever reaches the wire.
    func recordError(name: String, severity: TracklessErrorSeverity, code: String?) async {
        guard canRecord() else {
            warnNotRecording(type: "error")
            return
        }
        guard let normalized = normalizeName(name) else { return }

        let stored = Trackless.storedSeverity(severity)
        if claimReservedWarning(normalized) {
            warnReserved(normalized, kind: stored == .info ? "info" : "error")
        }

        let normalizedCode: String? = if let code, !code.isEmpty {
            FeatureValidator.normalize(code)
        } else {
            nil
        }

        // Mark the first occurrence of each name within the session (session
        // reach). Dedup is on the normalized name only (not name+severity+code),
        // mirroring feature first-use dedup — so only error events ever carry
        // firstOccurrences. `error()` and `info()` share the tracker, which is
        // why a name must not be shared between them.
        var firstOccurrences: Int?
        if await errorFirstOccurrences.markFirstOccurrence(name: normalized) {
            firstOccurrences = 1
        }

        await session.recordActivity()
        await addToBuffer(TracklessEvent(
            type: .error,
            name: normalized,
            firstOccurrences: firstOccurrences,
            severity: stored,
            code: normalizedCode
        ))
        if debugLogging {
            if let normalizedCode {
                logger.info("[Trackless] \(stored.rawValue, privacy: .public) — \(normalized, privacy: .public) code=\(normalizedCode, privacy: .public)")
            } else {
                logger.info("[Trackless] \(stored.rawValue, privacy: .public) — \(normalized, privacy: .public)")
            }
        }
        await checkFlushThreshold()
    }

    func flush() async {
        await performFlush(currentFlushTarget())
    }

    /// - Parameter timerCutoff: the open-timer sequence number captured when the
    ///   caller invoked `Trackless.setEnabled`. Disabling discards the timers
    ///   started up to it; nil discards every one.
    func setEnabled(_ enabled: Bool, timerCutoff: UInt64? = nil) async {
        self.enabled = enabled
        // Synchronously, before any suspension: disabling must stop an uncaught
        // send at once, and re-enabling points it at the configuration again.
        refreshUncaughtCapture()
        if !enabled {
            // Drop the session rather than end it: an opt-out must not lead to a later send.
            timers.discardAll(through: timerCutoff)
            await buffer.clear()
            await session.destroy()
            await featureFirstUses.clear()
            await errorFirstOccurrences.clear()
            timerState.cancelTimer()
            idleTimerState.cancelTimer()
            idleDeadline = nil
            cleanupObserver()
            hangs.disable()
        } else if !destroyed && configured {
            // Remove first: re-enabling twice would otherwise register a second
            // set of observers on top of the first.
            cleanupObserver()
            await startNewSession()
            startPeriodicFlush()
            addLifecycleObservers()
            startHangDetectionIfWanted()
        }
    }

    func destroy() async {
        guard !destroyed else { return }
        destroyed = true
        refreshUncaughtCapture()

        await endCurrentSession()
        await performFlush(currentFlushTarget())

        timerState.cancelTimer()
        idleTimerState.cancelTimer()
        idleDeadline = nil
        cleanupObserver()
        hangs.disable()
        await session.destroy()
        configured = false
    }

    // MARK: - Private Helpers

    private func canRecord() -> Bool {
        enabled && !destroyed && configured
    }

    private func warn(_ message: String) {
        guard !suppressWarnings else { return }
        onWarning?(message)
        logger.warning("[Trackless] \(message, privacy: .public)")
    }

    /// `name` must be a normalized (PII-stripped) value — it is emitted to the
    /// unified log as `.public`, so raw caller input must never reach it.
    private func warnDrop(_ reason: String, type: String, name: String) {
        warn("dropped \(type) \"\(name)\" — \(reason)")
    }

    /// Warn when an event is dropped because the SDK is not recording.
    /// Pre-configure drops warn once; disabled or destroyed drops warn per event.
    /// The event name is omitted here: it is raw, pre-normalization input.
    private func warnNotRecording(type: String) {
        if !configured && !destroyed {
            guard !warnedNotConfigured else { return }
            warnedNotConfigured = true
            warn("event dropped — SDK is not configured (call Trackless.configure() first)")
        } else {
            warn("dropped \(type) event — not recording")
        }
    }

    /// Add an event to the buffer, warning once per session when the buffer is full.
    private func addToBuffer(_ event: TracklessEvent) async {
        let accepted = await buffer.add(event)
        if !accepted, !warnedBufferFull {
            warnedBufferFull = true
            warn("event buffer full — dropping new events until the next flush (logged once per session)")
        }
    }

    /// Normalize a caller-supplied event name, warning when it is rejected.
    ///
    /// The name is omitted from both the warning and the error. Normalization
    /// only fails *after* PII stripping has run, so no PII-stripped form of the
    /// name survives to report. The inputs that actually reach this branch are
    /// the ones the PII guard does *not* recognize — anything it does recognize
    /// is replaced with the literal "[REDACTED]", which normalizes to a
    /// non-empty "redacted" and is accepted. What is left is chiefly
    /// non-Latin-script text, which includes personal names.
    ///
    /// `warn` emits to the unified log as `.public` (see the invariant on
    /// `warnDrop`), where a sysdiagnose bundle would collect it, and `onError`
    /// is commonly forwarded to a crash reporter.
    private func normalizeName(_ name: String) -> String? {
        guard let normalized = FeatureValidator.normalize(name) else {
            reportRejectedName()
            return nil
        }
        return normalized
    }

    private func startNewSession() async {
        let started = await session.start()
        if started {
            warnedBufferFull = false
            await addToBuffer(TracklessEvent(type: .session, name: "start"))
        }
    }

    /// - Parameter timerCutoff: the open-timer sequence number captured at the
    ///   moment the end was decided — in the lifecycle notification block or
    ///   the idle timer's handler, before its task. Only timers started up to
    ///   it are discarded, so one started after the app came back, but before
    ///   this task ran, survives. Nil discards every one.
    private func endCurrentSession(timerCutoff: UInt64? = nil) async {
        // Before the guard: a destroy() after setEnabled(false) has no session
        // to end, but may still hold timers started since.
        timers.discardAll(through: timerCutoff)
        guard let result = await session.end() else { return }
        await featureFirstUses.clear()
        await errorFirstOccurrences.clear()
        await addToBuffer(Self.sessionEndEvent(result))
    }

    /// The `session/end` event for an ended session. Shared with the
    /// uncaught-exception send.
    static func sessionEndEvent(_ result: (duration: Int, depth: Int)) -> TracklessEvent {
        TracklessEvent(
            type: .session,
            name: "end",
            stepIndex: result.depth,
            duration: Double(result.duration)
        )
    }

    private func checkFlushThreshold() async {
        let size = await buffer.totalSize
        if size >= bufferFlushThreshold {
            await performFlush(currentFlushTarget())
        }
    }

    /// - Parameters:
    ///   - target: what to flush and what to send it under — normally
    ///     `currentFlushTarget()`, read by the caller before its first
    ///     suspension point; a re-`configure()` passes the retired one.
    ///   - timeoutSeconds: per-request timeout. The macOS termination path
    ///     shortens it so the last send cannot outlive the quit budget that is
    ///     blocking on it.
    private func performFlush(
        _ target: FlushTarget,
        timeoutSeconds: TimeInterval = HTTPClient.flushTimeoutSeconds
    ) async {
        let isEmpty = await target.buffer.isEmpty
        guard !isEmpty else { return }

        let canAttempt = await target.circuitBreaker.canAttempt()
        guard canAttempt else { return }

        let payloads = await target.buffer.drain(environment: target.environment.rawValue, context: target.context)
        guard !payloads.isEmpty else { return }

        // Enforce the server's request body size limit on each chunk before sending.
        var sizedPayloads: [TracklessEventPayload] = []
        for payload in payloads {
            let split = EventBuffer.splitBySize(payload)
            sizedPayloads.append(contentsOf: split.payloads)
            for dropped in split.dropped {
                warnDrop(
                    "single-event payload exceeds \(EventBuffer.maxPayloadBytes / 1024)KB limit",
                    type: dropped.type.rawValue,
                    name: dropped.name
                )
            }
        }

        for payload in sizedPayloads {
            do {
                let result = try await transport(target.endpoint, target.apiKey, payload, timeoutSeconds)

                if result.status >= 500 {
                    await target.circuitBreaker.recordFailure()
                    warn("flush failed — HTTP \(result.status)")
                    target.onError?(TracklessError.flushFailed(statusCode: result.status))
                } else if result.status >= 400 {
                    let bodyText = Self.parseResponseSummary(result.body)
                    warn("flush rejected — HTTP \(result.status) \(bodyText)")
                    target.onError?(TracklessError.flushRejected(statusCode: result.status, body: bodyText))
                } else {
                    await target.circuitBreaker.recordSuccess()
                    if debugLogging {
                        logger.info("[Trackless] flush success — HTTP \(result.status)")
                    }
                }
            } catch {
                await target.circuitBreaker.recordFailure()
                target.onError?(error)
            }
        }
    }

    private static func parseResponseSummary(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "(no body)" }
        guard let text = String(data: data, encoding: .utf8) else { return "(unreadable body)" }
        if text.count <= 200 { return text }
        return String(text.prefix(200)) + "..."
    }

    // MARK: - Periodic Flush

    private func startPeriodicFlush() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        // `leeway` lets the system coalesce this wake-up with others. A telemetry
        // flush has no deadline worth waking a sleeping CPU for, and on macOS an
        // exact repeating timer is precisely what App Nap is meant to defeat.
        timer.schedule(
            deadline: .now() + flushIntervalSeconds,
            repeating: flushIntervalSeconds,
            leeway: .seconds(max(1, Int(flushIntervalSeconds / 10)))
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.flush()
            }
        }
        timerState.setTimer(timer)
        timer.resume()
    }

    // MARK: - Lifecycle Observers

    /// Register this platform's lifecycle observers.
    ///
    /// A dispatcher, not the wiring: UIKit and AppKit post different
    /// notifications with different meanings, so each gets its own registration
    /// function, and both funnel into the platform-neutral handlers below. On a
    /// platform with no wiring (watchOS, a Linux build) this does nothing and
    /// everything downstream still compiles.
    private func addLifecycleObservers() {
        #if os(iOS) || os(tvOS)
        addUIKitLifecycleObservers()
        #elseif os(macOS)
        addAppKitLifecycleObservers()
        #endif
    }

    #if os(iOS) || os(tvOS)
    private func addUIKitLifecycleObservers() {
        let backgroundObserver = notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let stamp = self.clock.now
            let timerCutoff = self.timers.currentSequence
            self.hangs.appResignedActive()
            Task {
                await self.handleAppDidEnterBackground(at: stamp, timerCutoff: timerCutoff)
            }
        }
        observerState.addObserver(backgroundObserver)

        let foregroundObserver = notificationCenter.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let stamp = self.clock.now
            let timerCutoff = self.timers.currentSequence
            Task {
                await self.handleAppDidBecomeActive(at: stamp, timerCutoff: timerCutoff)
            }
        }
        observerState.addObserver(foregroundObserver)

        // The hang watchdog follows active / resign-active rather than
        // foreground / background: it runs only while the app takes input.
        // `queue: nil`, so it starts and stops on the posting (main) thread.
        let activeObserver = notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.hangs.appBecameActive()
        }
        observerState.addObserver(activeObserver)

        let resignObserver = notificationCenter.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.hangs.appResignedActive()
        }
        observerState.addObserver(resignObserver)
    }
    #endif

    #if os(macOS)
    /// Native macOS (AppKit) wiring.
    ///
    /// `queue: nil` on purpose: each block then runs synchronously on the thread
    /// that posted the notification. That is what makes the wiring testable
    /// without a running main run loop, and it is what lets
    /// `handleWillTerminate()` block the terminating thread at all.
    private func addAppKitLifecycleObservers() {
        let resignObserver = notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let stamp = self.clock.now
            self.hangs.appResignedActive()
            Task {
                await self.handleAppDidResignActive(at: stamp)
            }
        }
        observerState.addObserver(resignObserver)

        let becomeActiveObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let stamp = self.clock.now
            let timerCutoff = self.timers.currentSequence
            self.hangs.appBecameActive()
            Task {
                await self.handleAppDidBecomeActive(at: stamp, timerCutoff: timerCutoff)
            }
        }
        observerState.addObserver(becomeActiveObserver)

        let terminateObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleWillTerminate()
        }
        observerState.addObserver(terminateObserver)
    }
    #endif

    // MARK: - Lifecycle Handlers (platform-neutral)

    /// Accept a lifecycle signal only when it is not older than the last one
    /// already processed.
    ///
    /// Every notification block captures `clock.now` **synchronously** and then
    /// hands the work to an unstructured `Task`. Swift does not guarantee that
    /// two tasks begin in creation order, so a fast Cmd-Tab bounce
    /// (resign → become-active) can be processed become-active first and then
    /// resign — which would arm an idle timer while the app is frontmost, and
    /// end a live session a few minutes later. Comparing the captured stamps is
    /// what makes the order of the *notifications*, not of the tasks, decide.
    private func acceptLifecycleSignal(at stamp: Date) -> Bool {
        guard stamp >= lastLifecycleStamp else { return false }
        lastLifecycleStamp = stamp
        return true
    }

    /// iOS/tvOS: the app entered the background. The session ends there and the
    /// end event is flushed immediately — iOS's effective idle timeout is zero.
    ///
    /// - Parameter timerCutoff: `timers.currentSequence` read in the
    ///   notification block; see `endCurrentSession(timerCutoff:)`.
    func handleAppDidEnterBackground(at stamp: Date, timerCutoff: UInt64? = nil) async {
        guard canRecord(), acceptLifecycleSignal(at: stamp) else { return }
        await endCurrentSession(timerCutoff: timerCutoff)
        await performFlush(currentFlushTarget())
    }

    /// macOS: the app resigned active.
    ///
    /// Records where the duration truncates, opens the idle window and flushes.
    /// **Nothing is buffered** — resigning is not an event and is not observable
    /// in the data.
    ///
    /// The duration truncates here rather than at the timeout boundary. Adding
    /// the timeout would give every macOS session exactly `T` extra seconds,
    /// making a measurement a function of a config knob — and it would shift the
    /// moment anyone changed it. With duration buckets at
    /// 10/30/60/180/600/1800s, a flat +300s would permanently empty the bottom
    /// three on macOS.
    func handleAppDidResignActive(at stamp: Date) async {
        guard canRecord(), acceptLifecycleSignal(at: stamp) else { return }

        // A second resign with no activation between them is not a second idle
        // window. `markInactive()` is idempotent, so the truncation point would
        // hold either way — but re-arming would push the session's end out by
        // the gap between the two signals, which is the one part of this a
        // repeat could still get wrong.
        guard idleDeadline == nil else { return }

        await session.markInactive()
        idleDeadline = stamp.addingTimeInterval(sessionIdleTimeoutSeconds)
        armIdleTimer(after: sessionIdleTimeoutSeconds)

        if debugLogging {
            logger.info("[Trackless] resigned active — session ends in \(Int(self.sessionIdleTimeoutSeconds))s if still idle")
        }
        await performFlush(currentFlushTarget())
    }

    /// The app became active (macOS) or returned to the foreground (iOS).
    ///
    /// Three outcomes, discriminated by whether an idle window is open and
    /// whether this signal lands inside it:
    ///
    /// - **No window open** — iOS (the session already ended at background), or
    ///   a macOS session the idle timer already ended. Start a new session.
    ///   `startNewSession()` is a no-op while one is running, so a spurious
    ///   activation cannot double-start.
    /// - **Inside the window** — the session continues; only the truncation mark
    ///   is dropped, so the interior gap counts toward the duration.
    /// - **Past the window** — the timer was deferred (App Nap, or the machine
    ///   slept through the wake-up). End the session that should already have
    ///   ended — still reporting the duration truncated at resign — then start a
    ///   new one. Two events in one turn.
    ///
    /// - Parameter timerCutoff: `timers.currentSequence` read in the
    ///   notification block, for the past-the-window end.
    func handleAppDidBecomeActive(at stamp: Date, timerCutoff: UInt64? = nil) async {
        guard canRecord(), acceptLifecycleSignal(at: stamp) else { return }

        // Defensive: a window closed without ending the session would leave
        // the truncation mark outliving `idleDeadline`. Rebuild the deadline
        // from the mark in that case: with neither branch below running, the
        // mark would stand and the session would later report a duration
        // truncated at a resign it has long since recovered from.
        let inactiveSince = await session.inactiveSince
        let deadline =
            idleDeadline ?? inactiveSince.map { $0.addingTimeInterval(sessionIdleTimeoutSeconds) }
        idleDeadline = nil
        idleTimerState.cancelTimer()

        guard let deadline else {
            await startNewSession()
            if debugLogging {
                logger.info("[Trackless] became active — started new session")
            }
            return
        }

        if stamp >= deadline {
            await endCurrentSession(timerCutoff: timerCutoff)
            await startNewSession()
            if debugLogging {
                logger.info("[Trackless] became active past the idle boundary — ended and restarted the session")
            }
        } else {
            await session.clearInactiveMark()
            if debugLogging {
                logger.info("[Trackless] became active within the idle window — session continues")
            }
        }
    }

    /// The idle window expired with the app still inactive: end the session.
    ///
    /// No new session — one starts on the next activation. **No flush** either:
    /// the end event rides the next periodic flush. Waking the network on a Mac
    /// the user has walked away from, to post one counter, is exactly what App
    /// Nap exists to stop.
    ///
    /// - Parameter timerCutoff: `timers.currentSequence` read in the idle
    ///   timer's handler, when the end was decided.
    func handleIdleTimeout(timerCutoff: UInt64? = nil) async {
        // `nil` means the window was already closed — by a reactivation that
        // raced this timer, or by a previous firing. Either way there is nothing
        // to end, and this is what prevents a double `session/end`.
        guard idleDeadline != nil else { return }
        idleDeadline = nil
        idleTimerState.cancelTimer()

        guard canRecord() else { return }
        await endCurrentSession(timerCutoff: timerCutoff)
        if debugLogging {
            logger.info("[Trackless] idle timeout — session ended")
        }
    }

    /// Arm the one-shot idle timer.
    ///
    /// **`wallDeadline:`, not `deadline:`.** `DispatchTime` does not advance
    /// while the system is asleep, so a mach-based deadline armed before the lid
    /// closes fires that many *awake* seconds later — which can be days. Wall
    /// time is what removes the need for any `NSWorkspace` sleep/wake observer.
    ///
    /// The timer is best-effort: `handleAppDidBecomeActive(at:)` re-checks the
    /// deadline, so a wake-up the system defers past its boundary is corrected
    /// on the next activation rather than lost.
    private func armIdleTimer(after seconds: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(wallDeadline: .now() + seconds, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let timerCutoff = self.timers.currentSequence
            Task {
                await self.handleIdleTimeout(timerCutoff: timerCutoff)
            }
        }
        idleTimerState.setTimer(timer)
        timer.resume()
    }

    #if os(macOS)
    /// macOS: the process is about to exit.
    ///
    /// Ends the session and flushes behind a **bounded** wait on the posting
    /// (main) thread, because once `applicationWillTerminate` returns the process
    /// is gone and an unstructured `Task` simply never resumes.
    ///
    /// Honest failure modes: quit is delayed by up to `terminationWaitSeconds` on
    /// a bad network, and a send that outruns that budget loses its batch. iOS
    /// has the same hole at `didEnterBackground` today.
    ///
    /// `nonisolated` so it can block its caller — hopping onto the actor first
    /// would be the very thing it is waiting for.
    ///
    /// The deterministic alternative is documented for integrators: call
    /// `await Trackless.destroy()` from `applicationWillTerminate(_:)`.
    /// `destroy()` is idempotent, so both firing is harmless.
    nonisolated func handleWillTerminate() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await self.endSessionForTermination()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + Self.terminationWaitSeconds)
    }

    private func endSessionForTermination() async {
        guard canRecord() else { return }
        await endCurrentSession()
        await performFlush(currentFlushTarget(), timeoutSeconds: Self.terminationFlushTimeoutSeconds)
    }
    #endif

    /// Unconditional: `ObserverState` is Foundation-only and on a platform that
    /// registered no observers the loop simply does nothing.
    private func cleanupObserver() {
        for observer in observerState.removeAllObservers() {
            notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Test Support

    /// Test-only: observe warnings that pass the suppression check.
    func setOnWarningForTesting(_ handler: (@Sendable (String) -> Void)?) {
        onWarning = handler
    }

    /// Test-only: the context that the next drain will stamp onto its payloads.
    func contextForTesting() -> TracklessEventContext {
        context
    }

    /// Test-only: replace the event buffer with one of a given capacity.
    func replaceBufferForTesting(maxItems: Int) {
        buffer = EventBuffer(maxItems: maxItems)
    }

    /// Test-only: current number of unique items in the buffer.
    func bufferSizeForTesting() async -> Int {
        await buffer.totalSize
    }

    /// Test-only: drain the buffer and return its flattened events. Reproduces the
    /// buffer drain a flush performs, without any network I/O — used to assert that
    /// the first-use set survives a mid-session flush.
    func drainBufferForTesting() async -> [TracklessEvent] {
        let payloads = await buffer.drain(environment: environment.rawValue, context: context)
        return payloads.flatMap { $0.events }
    }

    /// Test-only: end the current session (mirrors the lifecycle/destroy reset path,
    /// clearing the first-use and first-occurrence trackers).
    func endSessionForTesting() async {
        await endCurrentSession()
    }

    /// Test-only: the open idle window's wall-clock deadline, or nil if none.
    func idleDeadlineForTesting() -> Date? {
        idleDeadline
    }

    /// Test-only: whether a one-shot idle timer is currently armed.
    func hasIdleTimerForTesting() -> Bool {
        idleTimerState.hasTimer
    }

    /// Test-only: the idle timeout this instance was configured with, post-clamp.
    func sessionIdleTimeoutForTesting() -> TimeInterval {
        sessionIdleTimeoutSeconds
    }

    /// Test-only: whether a session is currently running.
    func isSessionActiveForTesting() async -> Bool {
        await session.isActive
    }

    /// Test-only: whether the session's duration is currently truncated at a
    /// resign mark.
    func isSessionMarkedInactiveForTesting() async -> Bool {
        await session.isMarkedInactive
    }

    /// Test-only: start a session without going through `configure`.
    func startSessionForTesting() async {
        await startNewSession()
    }
}

// MARK: - Timer State (thread-safe)

final class TimerState: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    func setTimer(_ newTimer: DispatchSourceTimer) {
        lock.lock()
        timer?.cancel()
        timer = newTimer
        lock.unlock()
    }

    func cancelTimer() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    /// Whether a timer is currently held (test support).
    var hasTimer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil
    }
}

// MARK: - Observer State (thread-safe)

final class ObserverState: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    func addObserver(_ observer: NSObjectProtocol) {
        lock.lock()
        observers.append(observer)
        lock.unlock()
    }

    func removeAllObservers() -> [NSObjectProtocol] {
        lock.lock()
        let current = observers
        observers = []
        lock.unlock()
        return current
    }
}

// MARK: - Once Flag (thread-safe)

/// A flag that can be claimed once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

// MARK: - Errors

/// Internal error types for the SDK.
public enum TracklessError: Error, Sendable {
    /// An event name was rejected by normalization.
    ///
    /// The associated value is the *reason* for the rejection, not the name.
    /// The raw, pre-normalization name may contain PII and is never carried
    /// here — see `invalidEventNameReason`.
    case invalidFeatureName(String)
    case flushFailed(statusCode: Int)
    case flushRejected(statusCode: Int, body: String)
}
