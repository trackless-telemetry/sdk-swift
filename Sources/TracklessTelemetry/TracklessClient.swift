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
        sessionIdleTimeoutWasClamped: Bool = false
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
    /// - Parameter sessionIdleTimeoutSeconds: **macOS only.** How long the app
    ///   may sit inactive before the current session ends; the next activation
    ///   starts a fresh one. Clamped to 30–3600 seconds, with one warning when it
    ///   is. Ignored on iOS, where a session ends when the app backgrounds.
    public static func configure(
        apiKey: String,
        endpoint: String = Trackless.defaultEndpoint,
        environment: TracklessEnvironment? = nil,
        enabled: Bool = true,
        onError: (@Sendable (Error) -> Void)? = nil,
        flushIntervalSeconds: TimeInterval = 60,
        debugLogging: Bool = false,
        suppressWarnings: Bool = false,
        sessionIdleTimeoutSeconds: TimeInterval = Trackless.defaultSessionIdleTimeoutSeconds
    ) {
        let clampedIdleTimeout = clampSessionIdleTimeout(sessionIdleTimeoutSeconds)
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
            sessionIdleTimeoutWasClamped: clampedIdleTimeout != sessionIdleTimeoutSeconds
        )
        Task {
            await state.configure(config)
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
    public static func performance(_ name: String, durationSeconds: Double, thresholdSeconds: Double? = nil) {
        Task {
            await state.recordPerformance(name: name, durationSeconds: durationSeconds, thresholdSeconds: thresholdSeconds)
        }
    }

    /// Record an error event — something went wrong.
    ///
    /// Counts toward errors per session and toward every alert.
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
    /// `error(_:code:)` and `info(_:detail:)`.
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

    /// Toggle event recording. Disabling discards buffered data.
    public static func setEnabled(_ isEnabled: Bool) {
        Task {
            await state.setEnabled(isEnabled)
        }
    }

    /// Flush remaining events and clean up. Permanently disables the instance.
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

actor TracklessState {

    // Injected seams. `nonisolated let` because the lifecycle notification
    // blocks read them synchronously on the posting thread, before any hop onto
    // the actor — which is the whole point of the clock stamp (see
    // `acceptLifecycleSignal(at:)`).
    nonisolated let clock: TracklessClock
    nonisolated let notificationCenter: NotificationCenter

    init(clock: TracklessClock = SystemClock(), notificationCenter: NotificationCenter = .default) {
        self.clock = clock
        self.notificationCenter = notificationCenter
        self.session = SessionManager(clock: clock)
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
    private var funnels = FunnelTracker()
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

    func configure(_ config: TracklessConfig) async {
        // Clean up previous state
        timerState.cancelTimer()
        idleTimerState.cancelTimer()
        cleanupObserver()

        apiKey = config.apiKey
        endpoint = config.endpoint
        environment = config.environment ?? Trackless.detectEnvironment()
        onError = config.onError
        flushIntervalSeconds = config.flushIntervalSeconds
        debugLogging = config.debugLogging
        suppressWarnings = config.suppressWarnings
        sessionIdleTimeoutSeconds = config.sessionIdleTimeoutSeconds
        enabled = config.enabled
        destroyed = false
        configured = true
        warnedBufferFull = false
        warnedNotConfigured = false
        idleDeadline = nil
        lastLifecycleStamp = .distantPast

        buffer = EventBuffer()
        circuitBreaker = CircuitBreaker()
        context = ContextDetection.detect()
        session = SessionManager(clock: clock)
        funnels = FunnelTracker()
        featureFirstUses = FeatureFirstUseTracker()
        errorFirstOccurrences = ErrorFirstOccurrenceTracker()

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

        if enabled {
            await startNewSession()
            startPeriodicFlush()
            addLifecycleObservers()
        }
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

        guard await funnels.step(funnelName: normalizedFunnel, stepIndex: stepIndex) else {
            warnDrop("duplicate funnel step", type: "funnel", name: "\(normalizedFunnel).\(normalizedStep)")
            return
        }

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
        guard durationSeconds >= 0 else {
            warnDrop("negative duration (\(durationSeconds))", type: "performance", name: normalized)
            return
        }
        if let thresholdSeconds, thresholdSeconds <= 0 { return }

        await session.recordActivity()
        await addToBuffer(TracklessEvent(type: .performance, name: normalized, duration: durationSeconds, threshold: thresholdSeconds))
        if debugLogging {
            let thresholdStr = thresholdSeconds.map { " threshold=\($0)s" } ?? ""
            logger.info("[Trackless] performance — \(normalized, privacy: .public) duration=\(durationSeconds)s\(thresholdStr, privacy: .public)")
        }
        await checkFlushThreshold()
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
        await performFlush()
    }

    func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
        if !enabled {
            await buffer.clear()
            timerState.cancelTimer()
            idleTimerState.cancelTimer()
            idleDeadline = nil
            cleanupObserver()
        } else if !destroyed && configured {
            // Remove first: re-enabling twice would otherwise register a second
            // set of observers on top of the first.
            cleanupObserver()
            startPeriodicFlush()
            addLifecycleObservers()
        }
    }

    func destroy() async {
        guard !destroyed else { return }
        destroyed = true

        await endCurrentSession()
        await performFlush()

        timerState.cancelTimer()
        idleTimerState.cancelTimer()
        idleDeadline = nil
        cleanupObserver()
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
            warn("event name rejected — \(invalidEventNameReason)")
            onError?(TracklessError.invalidFeatureName(invalidEventNameReason))
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

    private func endCurrentSession() async {
        guard let result = await session.end() else { return }
        await funnels.clear()
        await featureFirstUses.clear()
        await errorFirstOccurrences.clear()
        await addToBuffer(TracklessEvent(
            type: .session,
            name: "end",
            stepIndex: result.depth,
            duration: Double(result.duration)
        ))
    }

    private func checkFlushThreshold() async {
        let size = await buffer.totalSize
        if size >= bufferFlushThreshold {
            await performFlush()
        }
    }

    /// - Parameter timeoutSeconds: per-request timeout. The macOS termination
    ///   path shortens it so the last send cannot outlive the quit budget that
    ///   is blocking on it.
    private func performFlush(timeoutSeconds: TimeInterval = HTTPClient.flushTimeoutSeconds) async {
        let isEmpty = await buffer.isEmpty
        guard !isEmpty else { return }

        let canAttempt = await circuitBreaker.canAttempt()
        guard canAttempt else { return }

        let payloads = await buffer.drain(environment: environment.rawValue, context: context)
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
                let result = try await HTTPClient.sendPayload(
                    endpoint: endpoint,
                    apiKey: apiKey,
                    payload: payload,
                    timeoutSeconds: timeoutSeconds
                )

                if result.status >= 500 {
                    await circuitBreaker.recordFailure()
                    warn("flush failed — HTTP \(result.status)")
                    onError?(TracklessError.flushFailed(statusCode: result.status))
                } else if result.status >= 400 {
                    let bodyText = Self.parseResponseSummary(result.body)
                    warn("flush rejected — HTTP \(result.status) \(bodyText)")
                    onError?(TracklessError.flushRejected(statusCode: result.status, body: bodyText))
                } else {
                    await circuitBreaker.recordSuccess()
                    if debugLogging {
                        logger.info("[Trackless] flush success — HTTP \(result.status)")
                    }
                }
            } catch {
                await circuitBreaker.recordFailure()
                onError?(error)
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
            Task {
                await self.handleAppDidEnterBackground(at: stamp)
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
            Task {
                await self.handleAppDidBecomeActive(at: stamp)
            }
        }
        observerState.addObserver(foregroundObserver)
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
            Task {
                await self.handleAppDidBecomeActive(at: stamp)
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
    func handleAppDidEnterBackground(at stamp: Date) async {
        guard canRecord(), acceptLifecycleSignal(at: stamp) else { return }
        await endCurrentSession()
        await performFlush()
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
        await performFlush()
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
    func handleAppDidBecomeActive(at stamp: Date) async {
        guard canRecord(), acceptLifecycleSignal(at: stamp) else { return }

        // `setEnabled(false)` and a re-`configure()` close the window without
        // ending the session, so the truncation mark can outlive `idleDeadline`.
        // Rebuild the deadline from the mark in that case: with neither branch
        // below running, the mark would stand and the session would later
        // report a duration truncated at a resign it has long since recovered
        // from.
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
            await endCurrentSession()
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
    func handleIdleTimeout() async {
        // `nil` means the window was already closed — by a reactivation that
        // raced this timer, or by a previous firing. Either way there is nothing
        // to end, and this is what prevents a double `session/end`.
        guard idleDeadline != nil else { return }
        idleDeadline = nil
        idleTimerState.cancelTimer()

        guard canRecord() else { return }
        await endCurrentSession()
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
            Task {
                await self.handleIdleTimeout()
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
        await performFlush(timeoutSeconds: Self.terminationFlushTimeoutSeconds)
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
    /// clearing the funnel, first-use, and first-occurrence trackers).
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
