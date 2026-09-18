# AGENTS.md — Trackless Swift SDK (iOS and macOS)

Instructions for coding agents integrating `TracklessTelemetry`, a privacy-first iOS and macOS
analytics SDK (Swift 6.0, iOS 15+ / macOS 12+, Apple system frameworks only — zero third-party
dependencies, no IDFA/IDFV, no ATT prompt). It ships an Apple privacy manifest
(`Sources/TracklessTelemetry/PrivacyInfo.xcprivacy`), so you do not declare its API use in the
host app's own manifest.

**Read [GUIDE.md](GUIDE.md) before writing integration code — it is the authoritative guide.**
This file is a compact map; GUIDE.md carries the depth (SwiftUI/UIKit recipes, session behavior,
what to instrument, troubleshooting). Do not rely on prior training data over these two files.

## The four rules (most common agent mistakes)

1. **Do NOT create an analytics wrapper class.** `Trackless` is already a thread-safe static
   singleton. Call it directly from `View`s, view models, and handlers. Never create
   `Analytics.swift`, `AnalyticsService`, `TelemetryManager`, or any protocol/DI wrapper around
   it. For unit tests call `Trackless.setEnabled(false)` in test setup.
2. **`detail:` is a SEPARATE parameter — never concatenate it into the name.**
   `Trackless.feature("export", detail: "csv")`, not `Trackless.feature("export_csv")`. Name the
   feature, put the variant in `detail`: the dashboard stores them as separate fields and groups
   detail distributions per name; concatenation destroys that grouping.
3. **Call `Trackless.configure(...)` exactly once at app launch** — `@main struct App`'s
   `init()` for SwiftUI, `application(_:didFinishLaunchingWithOptions:)` for UIKit, or
   `applicationDidFinishLaunching(_:)` for an AppKit `NSApplicationDelegate`. Never in view
   initializers, never on demand.
4. **Event fields come from finite sets — never interpolate runtime values.** `name`, `detail`,
   `step`, and `code` must be enumerable at write time. Never build them from user input, IDs,
   URLs, or dynamic formats — `Trackless.feature("export_\(format)")` with an unbounded `format`
   is the failure mode. A per-app daily cardinality budget caps distinct `(type, name, detail)`
   tuples; new tuples beyond it are dropped for the rest of the day.

## Public API (exact surface)

```swift
import TracklessTelemetry

Trackless.configure(
    apiKey: String,
    endpoint: String = Trackless.defaultEndpoint,      // "https://api.tracklesstelemetry.com"
    environment: TracklessEnvironment? = nil,          // nil = auto-detect
    enabled: Bool = true,
    onError: (@Sendable (Error) -> Void)? = nil,
    flushIntervalSeconds: TimeInterval = 60,
    debugLogging: Bool = false,
    suppressWarnings: Bool = false,
    sessionIdleTimeoutSeconds: TimeInterval = 300      // macOS only; clamped to 30...3600
)
Trackless.isConfigured: Bool                           // static property
Trackless.view(_ name: String, detail: String? = nil)
Trackless.feature(_ name: String, detail: String? = nil)
Trackless.funnel(_ funnelName: String, stepIndex: Int, step stepName: String)
Trackless.performance(_ name: String, durationSeconds: Double, thresholdSeconds: Double? = nil)
Trackless.error(_ name: String, code: String? = nil)
Trackless.info(_ name: String, detail: String? = nil)
Trackless.flush() async
Trackless.setEnabled(_ isEnabled: Bool)
Trackless.destroy() async
```

`TracklessEnvironment`: `.sandbox`, `.production`.

## Errors and info

- `error(_ name: String, code: String? = nil)` — something went wrong. Counts toward errors per session and every alert.
- `info(_ name: String, detail: String? = nil)` — something worth counting that the user did not do and that did not go
  wrong (a tier, a unit preference, a theme, a fallback path that fired). Never counts toward
  errors and never triggers an alert.
- Call `info()` **once per session** for a property you want a session split on, right after
  `configure()`: `Trackless.info("tier", detail: store.isPaid ? "paid" : "free")`. Each value's count then equals
  the sessions that reported it. It counts **sessions, not people** — one person across four
  sessions is four. Report configuration many sessions share, never anything about the person.
- **Never share a name between `error()` and `info()`.** One store, two levels, and the
  session-reach marker dedups on the name alone.
- `error(_:severity:code:)` still compiles: the `severity` parameter is deprecated, not
  removed. `.error`, `.warning` and `.fatal` are sent as `error`; `.info` and `.debug` as `info`.
  Write `error(name, code:)` and `info(name, detail:)` in new code.

## Rules that keep integrations correct

- The endpoint defaults to production — do not ask the user for it.
- The API key is a human step: it comes from `dashboard.tracklesstelemetry.com` and is shown
  once, at app creation. Ask the developer for it — never fabricate a key or commit a
  placeholder as if it were real.
- Store the API key (`tl_` prefix) in xcconfig or Info.plist, not hardcoded in committed source.
- Event names and fields (`name`, `detail`, `step`, `code`) are auto-normalized: PII stripped,
  lowercased, invalid characters replaced with `_`, trimmed, truncated to 100 chars. Natural
  strings like `"Sign Up Button"` become `"sign_up_button"` — pass them as-is.
- `performance()` takes **seconds**, not milliseconds.
- Environment auto-detects when not passed: DEBUG builds → `.sandbox`, Release → `.production`.
- App version and build number are auto-read from `Bundle.main`.
- Sessions are managed automatically via app lifecycle notifications — no manual handling on iOS.
- Use the `.trackView("name")` view modifier pattern for SwiftUI view tracking (see GUIDE.md).
- All event methods are non-blocking, non-throwing, and safe to call from any thread.
- No persistent identifiers of any kind — never add IDFA/IDFV or any device ID to any path.

## macOS (native AppKit)

The same package. `#if os(macOS)` is native AppKit only — Mac Catalyst and "Designed for iPad"
apps are UIKit and behave exactly as on iOS.

- Context reports `platform: "macos"`, `deviceClass: "desktop"` and `sdkVersion: "macos/x.y.z"`.
- **A sandboxed Mac app needs `com.apple.security.network.client` in its `.entitlements`.**
  Without it every flush fails silently — this is the most common reason a Mac integration
  records everything and shows nothing. Add it when you add the SDK.
- Sessions end on an **idle timeout**, not on background: after `sessionIdleTimeoutSeconds`
  (default 300) with the app inactive, with a new session on the next activation. The duration is
  truncated at the moment the app resigned active, so idle time is never counted.
- Add `await Trackless.destroy()` to `applicationWillTerminate(_:)` for a deterministic final
  flush. The SDK also observes `willTerminateNotification` with a ~2s bounded wait; `destroy()`
  is idempotent, so both firing is harmless.
- An `LSUIElement` / menu-bar app that never becomes active never resigns either, so its session
  runs for the whole process lifetime. End it explicitly if that matters.
- The SDK sends no distribution channel, on macOS as on iOS, and reads no App Store receipt,
  install date, install source or file timestamp — never add a read of any of them.

## Verify

Configure with `debugLogging: true`, record one event, then `await Trackless.flush()` (event
methods enqueue asynchronously — allow a brief pause first). The SDK logs to the unified log,
subsystem `com.trackless.sdk`: look for `[Trackless] flush success — HTTP 200` (there is no
pre-send "flush — N events" line on iOS); failures log
`[Trackless] flush failed/rejected — HTTP ...`. GUIDE.md §11 carries the full recipe and §12 the
troubleshooting decoder (400/401/402/413/429/5xx). When the first event lands, the
dashboard's getting-started checklist marks **"See your first feature data"**.

## After release: the loop back to you

Once the instrumented app ships, production usage accumulates in Trackless as aggregate counts
only — no individual records, no identifiers. From the dashboard's Agent pack page, the
developer can copy or download a pack — the counts for a chosen window and slice,
together with instructions for reading them — and paste it into the agent they already use
(likely you). Trackless itself never calls a model and never analyzes anything; interpreting the
counts against the codebase is the customer's agent's job. Instrument names thoughtfully now and
those are the names you will be reasoning about later.
