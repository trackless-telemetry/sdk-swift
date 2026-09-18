import Foundation

/// Event types supported by Trackless.
enum TracklessEventType: String, Codable, Sendable {
    case session
    case view
    case feature
    case funnel
    case performance
    case error
}

/// Severity values for the deprecated `severity` parameter on
/// `Trackless.error(_:severity:code:)`.
///
/// The SDK sends two of them — `.error` and `.info` — and the ingest endpoint
/// stores two. The other three are accepted for installed apps and mapped
/// before the event is buffered: `.debug` becomes `.info`, `.warning` and
/// `.fatal` become `.error`.
///
/// `.debug`, `.warning` and `.fatal` are deprecated because nothing reads them.
/// `.info` and `.error` are not, because they are the two levels the wire
/// carries and the SDK constructs them itself — but the only way to pass either
/// to `error()` is through its deprecated `severity` parameter, so a caller who
/// does gets a warning either way.
public enum TracklessErrorSeverity: String, Codable, Sendable {
    @available(*, deprecated, message: "Nothing reads `debug` — it is sent as `info`. Call Trackless.info(_:detail:) instead.")
    case debug
    /// The level `Trackless.info(_:detail:)` sends. Call that rather than passing this to `error()`.
    case info
    @available(*, deprecated, message: "Nothing reads `warning` — it is sent as `error`. Call Trackless.error(_:code:) instead.")
    case warning
    /// The level `Trackless.error(_:code:)` sends.
    case error
    @available(*, deprecated, message: "Nothing reads `fatal` — it is sent as `error`, and no SDK captures crashes. Call Trackless.error(_:code:) instead.")
    case fatal
}

/// Environment for the SDK payload.
public enum TracklessEnvironment: String, Codable, Sendable {
    case sandbox
    case production
}

/// Coarse device context — no fingerprinting data.
///
/// Privacy invariants enforced:
/// - NO IDFA or IDFV (Invariant 1)
/// - NO device name or model string (Invariant 2)
/// - NO IP-based geolocation (Invariant 4)
/// - Region derived from system Locale only
struct TracklessEventContext: Codable, Sendable, Equatable {
    let platform: String
    let osVersion: String?
    let deviceClass: String?
    let region: String?
    let language: String?
    let appVersion: String?
    let buildNumber: String?
    let sdkVersion: String?

    /// The `platform` default is the literal `"ios"`, **not**
    /// `ContextDetection.platform`, on purpose: this is a plain data struct and a
    /// host-dependent default would make every test that constructs a bare
    /// `TracklessEventContext()` assert a different value on a macOS host than on
    /// an iOS one. Production code never relies on the default — `detect()` and
    /// the pre-configure placeholder in `TracklessState` both pass
    /// `ContextDetection.platform` explicitly.
    init(
        platform: String = "ios",
        osVersion: String? = nil,
        deviceClass: String? = nil,
        region: String? = nil,
        language: String? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        sdkVersion: String? = nil
    ) {
        self.platform = platform
        self.osVersion = osVersion
        self.deviceClass = deviceClass
        self.region = region
        self.language = language
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.sdkVersion = sdkVersion
    }
}

/// A single event in the payload.
struct TracklessEvent: Codable, Sendable, Equatable {
    let type: TracklessEventType
    let name: String
    var count: Int?
    /// Number of sessions in which this feature was used for the first time within
    /// this buffer window. Meaningful only for `type == .feature`. Set to 1 on the
    /// first use of a feature name per session (see feature-reach spec §25.4). The
    /// synthesized `Codable` conformance omits the key entirely when this is `nil`,
    /// and the buffer never stores 0 — so `firstUses` reaches the wire only when >= 1
    /// (the backend rejects `firstUses: 0`).
    var firstUses: Int?
    /// Number of sessions in which this error occurred for the first time within this
    /// buffer window. Meaningful only for `type == .error`. Set to 1 on the first
    /// occurrence of an error name per session — the error-side mirror of `firstUses`.
    /// The synthesized `Codable` conformance omits the key entirely when this is `nil`,
    /// and the buffer never stores 0 — so `firstOccurrences` reaches the wire only when
    /// >= 1 (the backend rejects `firstOccurrences: 0`).
    var firstOccurrences: Int?
    var detail: String?
    var step: String?
    var stepIndex: Int?
    var duration: Double?
    var durations: [Double]?
    var threshold: Double?
    var severity: TracklessErrorSeverity?
    var code: String?

    init(
        type: TracklessEventType,
        name: String,
        count: Int? = nil,
        firstUses: Int? = nil,
        firstOccurrences: Int? = nil,
        detail: String? = nil,
        step: String? = nil,
        stepIndex: Int? = nil,
        duration: Double? = nil,
        durations: [Double]? = nil,
        threshold: Double? = nil,
        severity: TracklessErrorSeverity? = nil,
        code: String? = nil
    ) {
        self.type = type
        self.name = name
        self.count = count
        self.firstUses = firstUses
        self.firstOccurrences = firstOccurrences
        self.detail = detail
        self.step = step
        self.stepIndex = stepIndex
        self.duration = duration
        self.durations = durations
        self.threshold = threshold
        self.severity = severity
        self.code = code
    }
}

/// Full event payload sent to the ingest endpoint.
struct TracklessEventPayload: Codable, Sendable, Equatable {
    let date: String
    let environment: String?
    let context: TracklessEventContext
    let events: [TracklessEvent]

    init(date: String, environment: String?, context: TracklessEventContext, events: [TracklessEvent]) {
        self.date = date
        self.environment = environment
        self.context = context
        self.events = events
    }
}

/// Response from the ingest endpoint.
struct TracklessIngestResponse: Codable, Sendable {
    let accepted: Int?
    let rejected: Int?
}
