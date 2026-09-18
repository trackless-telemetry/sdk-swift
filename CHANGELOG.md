# Changelog

All notable changes to the Trackless Telemetry Swift SDK (iOS and macOS) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-09-18

### Added

- **Native macOS support.** A native AppKit app now reports `platform: "macos"` (and `sdkVersion: "macos/x.y.z"`) instead of masquerading as an iPhone, and registers real lifecycle observers — it previously registered none, so a Mac session started at `configure()` and ended only at `destroy()`. `deviceClass` was already `"desktop"`. **Mac Catalyst and "Designed for iPad" apps are unchanged**: they are UIKit, they keep reporting `ios`, and they keep iOS's lifecycle.
- **macOS session lifecycle — an idle timeout.** A Mac app is not backgrounded when you switch away from it, so a macOS session ends after the app has been inactive for a configurable period, with a new session on the next activation. Resigning active is not an event and is not observable in the data: the SDK notes the moment, flushes, and opens the idle window. Returning inside the window continues the session; returning after it ends the old one and starts a new one. **The duration is truncated at the moment the app resigned active**, never extended to the timeout boundary — otherwise every macOS duration would carry exactly the timeout as a constant and would shift the moment anyone changed it.
- **`sessionIdleTimeoutSeconds: TimeInterval = 300`** on `Trackless.configure(...)`, appended last so no existing call site changes. macOS only; ignored on iOS, where a session ends at background. Clamped to 30–3600 seconds, with one warning when it is. 300s rather than the web's 30-minute convention: at 30 minutes a macOS "session" means "a workday" and every one lands in the top duration bucket.
- **macOS quit handling.** The SDK observes `NSApplication.willTerminateNotification` and ends + flushes the session behind a bounded ~2s wait with a shortened request timeout. Honest failure modes, now documented: quit can be delayed by up to that budget on a bad network, and a send that outruns it loses its batch — the same hole iOS has at `didEnterBackground`. `await Trackless.destroy()` in `applicationWillTerminate(_:)` is the deterministic path and is now in GUIDE.md; `destroy()` is idempotent, so both firing is harmless.
- **`Trackless.info(_ name: String, detail: String? = nil)`** — records something worth counting that the user did not do and that did not go wrong: a tier, a unit preference, a theme, a notification permission state, a fallback path that fired. It is sugar over the existing error path — same normalization, PII guard, session-reach marker, session-depth increment and client-side rollup — sent with severity `info` and the detail in `code`. An info event never counts toward errors per session and never triggers an alert. Called once per session, each value's count equals the number of sessions that reported it; it counts sessions, not people.
- **`Trackless.error(_ name: String, code: String? = nil)`** — the documented error signature, as a new two-argument overload. `Trackless.error("api_timeout", code: "TIMEOUT_500")` reads the way it looks.
- **An Apple privacy manifest.** The package now ships `Sources/TracklessTelemetry/PrivacyInfo.xcprivacy`, registered in `Package.swift` as a target resource. Previously there was none, so a customer's App Store submission could draw a missing-API-declaration notice for the file-timestamp read earlier versions made — and the *app developer* received that email for the SDK's behavior. It declares `NSPrivacyTracking: false`, no tracking domains, the three data types already documented under "App Store Privacy Labels" (all Not Linked, Not Used for Tracking; Analytics and App Functionality), and **no required-reason APIs** — `NSPrivacyAccessedAPITypes` is empty, because this release removes the one file-timestamp read (see Removed). Nothing is declared because nothing is used — no file timestamps, no `UserDefaults`, no system boot time, no disk space, no active keyboards.

### Changed

- **The repository is now [`trackless-telemetry/sdk-swift`](https://github.com/trackless-telemetry/sdk-swift)**, renamed from `sdk-ios` because the package covers iOS and macOS. GitHub redirects the old URL, so existing `Package.swift` entries and `Package.resolved` pins keep resolving; new integrations should use the new URL. The package, product and module are still `TracklessTelemetry`, and nothing in your code changes. If you switch a `Package.swift` to the new URL, change the product reference with it, from `package: "sdk-ios"` to `package: "sdk-swift"`: that argument is the package's identity, which SwiftPM takes from the last component of the URL. Use one URL throughout a dependency graph: SwiftPM takes a package's identity from the last component of its URL, so the old and new URLs together would count as two packages.
- **Session durations are clamped, on iOS as well as macOS.** Duration still comes from the wall clock, but is now clamped to `[0, 86400]` seconds: a clock change (NTP correction, time zone, manual adjustment) previously could report a negative duration or one lasting a year, and now cannot. A monotonic clock would have fixed the same defect more directly and was rejected on purpose — every monotonic source on Apple platforms is a system-boot-time API that Apple requires a declared reason for, and reading no such API is worth more to this SDK than the narrow case it would fix.
- **Two stored levels.** The SDK maps whatever severity a caller passes to one of two values before the event is buffered: `.error`, `.warning` and `.fatal` are sent as `error`; `.info` and `.debug` are sent as `info`. Nothing downstream ever read `fatal` or `warning` differently from `error`, and `fatal` promised what no SDK delivers — none captures crashes. The ingest endpoint applies the same mapping, so an older SDK build is handled identically. One consequence to expect: a name previously reported at several severities in one flush window now rolls up into a single buffered entry instead of one per level.
- **The `severity:` parameter on `error()` is deprecated** — the severity-taking overload carries `@available(*, deprecated, message:)` pointing at `error(_:code:)` and `info(_:detail:)`. It still compiles and still records, so no published call breaks. `TracklessErrorSeverity` stays public, with `.debug`, `.warning` and `.fatal` individually deprecated; `.error` and `.info` are not, because they are the two levels the wire carries — and the only way to pass either to `error()` is through the deprecated parameter, so a caller gets a warning either way.

### Removed

- **Every install-metadata read.** The SDK now stores nothing on the device and reads nothing stored there: it uses only runtime properties the OS exposes to every app (OS version, device class, locale, language) and constants compiled into the app itself (version, build number, the `DEBUG` flag). Concretely:
  - **`daysSinceInstall` is no longer sent.** 0.4.x derived it from the Documents directory's creation date — which, in a non-sandboxed Mac app, is the real `~/Documents` and so reported the age of the person's macOS account. That read, and every other install-date source, is gone. Ingest accepts and discards the field from older SDK builds.
  - **`distributionChannel` is no longer sent**, on iOS or macOS. The SDK no longer reads `Bundle.main.appStoreReceiptURL` or checks for a receipt file, and without the install source the only thing left to report was the `DEBUG` flag, which `environment` already carries. Ingest accepts and discards the field from older SDK builds.
  - **No StoreKit, no App Store receipt, no file timestamps.** The SDK links only Foundation and UIKit or AppKit.
  - **The privacy manifest therefore carries no file-timestamp required-reason declaration** (`NSPrivacyAccessedAPICategoryFileTimestamp`, `C617.1`), which 0.4.x's creation-date read would have needed; `NSPrivacyAccessedAPITypes` is empty.

### Documentation

- **The App Store privacy label for `error()` / `info()` is corrected to Diagnostics — Other Diagnostic Data.** It previously said Crash Data, which Apple defines as crash logs and stack traces. The SDK captures neither: `error()` is a method your code calls, and nothing in the SDK installs a crash handler. Over-declaring is still misdeclaring, so the label, the shipped privacy manifest and the guidance in README.md, GUIDE.md and `docs/requirements/sdks.md` §22.7 now agree. **If you declared Crash Data on the strength of the old guidance, update it in App Store Connect.**
- **Session lifecycle is documented per platform.** GUIDE.md §5 previously opened with "Sessions are managed automatically. No code needed" and described background/foreground boundaries — every sentence of which was false on macOS. It now has an iOS section, a macOS section, and a new §5.1 covering the two things that are not automatic on macOS: the **App Sandbox `com.apple.security.network.client` entitlement** (without it every flush fails silently — the most common reason a Mac integration records everything and shows nothing), and the `applicationWillTerminate` / `await Trackless.destroy()` recipe. §2 gains an `NSApplicationDelegate` configure snippet. Also noted: an `LSUIElement` menu-bar app never becomes active and so never resigns, meaning its session runs for the lifetime of the process.
- README.md and GUIDE.md §9 gain a Privacy manifest section, written to agree with the App Store privacy-label table beside it; .cursorrules tells integrating agents not to duplicate the SDK's declaration in the host app's manifest. README.md, GUIDE.md, AGENTS.md and .cursorrules state that the SDK reads nothing about the installation and sends no distribution channel.
- README.md, AGENTS.md and .cursorrules state the macOS platform value, the idle timeout and the entitlement; the context table carries both `platform` values and both `sdkVersion` prefixes.
- The five-level severity table is gone from README.md, GUIDE.md, AGENTS.md and .cursorrules, replaced by the two methods and a migration note carrying the mapping. New guidance: do not share a name between `error()` and `info()` — they share one store and one session-reach marker.
- The feature example leads with `feature("export", detail: "csv")` rather than `feature("export_clicked")`: name the feature, put the variant in `detail`. Names are permanent once data exists.
- Session depth has one definition everywhere — **events per session**, incremented by every non-session event including `info()`.
- The App Store privacy-label guidance now reads "error and info events (name, level, code)".

## [0.4.1] - 2026-08-26

### Added

- **AGENTS.md** — a README for coding agents, following the [agents.md](https://agents.md) convention: the critical integration rules, the exact public API surface, naming and environment rules in brief, and a pointer to GUIDE.md as the authoritative guide.
- **Verification and troubleshooting documentation** — GUIDE.md gains a "Verify the Integration" section (the exact unified-log signal strings an agent can check unattended — subsystem `com.trackless.sdk`, ending at `[Trackless] flush success — HTTP 200` — plus the dashboard's "See your first feature data" checklist confirmation) and a troubleshooting table decoding the ingest endpoint's deliberately generic responses (401 wrong/regenerated key, 402 quota reached, 429 rate limit, 5xx/network with the circuit breaker's actual behavior — failed batches are not re-sent; backoff only pauses future flushes, 30s → 60m). AGENTS.md gains a matching compact "Verify" block.
- **Anti-interpolation rule documented** — event fields must come from finite sets enumerable at write time; never interpolate runtime values (`Trackless.feature("export_\(format)")` is the failure mode). Stated as a fourth critical rule in AGENTS.md and a subsection under GUIDE.md's event-naming rules, including the per-app daily cardinality budget that drops new `(type, name, detail)` tuples beyond it.
- **.cursorrules completes the critical rules** — now states the no-wrapper rule and the detail-is-a-separate-parameter rule alongside the existing guidance.
- **API key provenance documented** — GUIDE.md and AGENTS.md now state that the key comes from the dashboard, is shown once at app creation, and must be obtained from the developer — never fabricated or committed as a placeholder posing as real.

### Fixed

- **.cursorrules no longer pins a stale version** — the install line said "v0.2.2+"; it now says "latest release" so the file no longer needs a bump on every release.

- **Name-rejection warnings no longer echo raw caller input** — when an event name fails normalization, the warning and the `onError` value now omit the name entirely and explain why it was rejected. Previously both carried the raw, pre-normalization string; because `warn` emits to the unified log with `privacy: .public`, that value was not redacted and persisted in the unified log, where a sysdiagnose bundle would collect it. This is the path the 0.3.0 "Drop warnings never include raw input" entry described but did not actually cover — that change fixed the sibling `warnDrop` path only. `TracklessError.invalidFeatureName` keeps its associated value, but that value is now the *reason* for the rejection rather than the name — the signature is unchanged, so existing `case .invalidFeatureName(let value)` call sites keep compiling. No telemetry was ever affected: nothing here is buffered or transmitted, and PII stripping still runs before any event reaches the wire.

## [0.4.0] - 2026-08-21

### Added

- **Session reach for errors** — the first `error(...)` call for a given name within a session now carries `firstOccurrences: 1`, letting the dashboard compute what share of sessions hit each error (session reach), not just raw counts. This mirrors the existing `firstUses` marker for feature events: dedup is keyed on the normalized error **name only** (not `name` + `severity` + `code`), so a session that raises the same error at several severities or with several codes still contributes exactly one first occurrence. The per-session first-occurrence set is in-memory only and resets on session end; it deliberately survives buffer flushes, so a rolled-up event spanning a session boundary may report `firstOccurrences` greater than 1. Repeats within a session and non-error events send no `firstOccurrences` field. Fully backward compatible: older backends ignore the field.

## [0.3.0] - 2026-07-21

### Added

- **Session reach for features** — the first `feature(...)` call for a given name within a session now carries `firstUses: 1`, letting the dashboard compute what share of sessions used each feature (session reach), not just raw counts. Dedup is keyed on the normalized feature **name only** (not `name` + `detail`), so a session that exercises several detail variants still contributes exactly one first-use. The per-session first-use set is in-memory only and resets on session end (mirroring funnel-step dedup); it deliberately survives buffer flushes, so a rolled-up event spanning a session boundary may report `firstUses` greater than 1. Repeats within a session, non-feature events, and detail variants after the first use send no `firstUses` field. Fully backward compatible: older backends ignore the field.

### Fixed

- **Request body size limit** — flush now checks each serialized payload against the ingest endpoint's 50 KB body limit. Oversized payloads are split in half recursively until each request fits; a single event that exceeds the limit on its own is dropped with a warning. Previously oversized batches were rejected server-side and the whole batch was lost.
- **Buffer-full visibility** — when the event buffer reaches its 1000-item cap and starts rejecting new events, the SDK now logs a warning (at most once per session, re-armed when a new session starts, respects `suppressWarnings`) instead of dropping data silently.
- **Pre-configure visibility** — event methods called before `configure()` now log a one-time warning (respects `suppressWarnings`) instead of dropping events silently.

### Changed

- **Drop warnings never include raw input** — warnings for events dropped *after* validation (the `warnDrop` path) only ever contain normalized (PII-stripped) event names, and warnings for events dropped before validation omit the name entirely. **Correction:** as originally worded this entry overstated the scope. It did not cover the name-rejection warning in `normalizeName`, which kept emitting raw caller input until the fix listed under Unreleased.

## [0.2.4] - 2026-04-18

### Changed

- **More defensive `distributionChannel` detection** — sessions where `Bundle.main.appStoreReceiptURL` is missing, or points at the production receipt path but no receipt file is present, are now reported as `"unknown"` instead of `"app_store"`. This prevents misclassifying Apple Beta App Review sessions (whose reviewer environment doesn't always produce a normal sandbox receipt) as real App Store installs. `"testflight"` and `"app_store"` now require positive evidence — a `sandboxReceipt` path or a present receipt file, respectively.

## [0.2.3] - 2026-04-16

### Added

- **Distribution channel detection** — new `distributionChannel` context field automatically detects how the app was installed: `"testflight"` for TestFlight builds (via App Store sandbox receipt), `"app_store"` for App Store builds, and `"debug"` for debug builds. Enables filtering and grouping by distribution channel in the dashboard.

## [0.2.2] - 2026-03-24

### Added

- Include SDK version (`ios/0.2.2`) in event context for server-side diagnostics
- Add `language` to event context — ISO 639-1 code detected from `Locale.current`

### Changed

- **App Store privacy label guidance updated** — documentation now declares Diagnostics — Crash Data and Diagnostics — Performance Data in addition to Usage Data — Product Interaction, reflecting the error and performance event types. All categories remain Not Linked to User Identity and Not Used for Tracking.
- **Privacy guarantees clarified** — explicitly documents that error tracking collects no stack traces, crash logs, or error messages, and that performance tracking stores no individual duration measurements (server-side t-digest aggregation only).

## [0.2.1] - 2026-03-19

### Changed

- **Graceful field normalization** — `name`, `detail`, `step`, and `code` fields are now automatically normalized before buffering: lowercased, invalid characters replaced with underscores, leading/trailing underscores and dots trimmed, consecutive dots collapsed. Developers can now pass natural strings like `"Sign Up Button"` (becomes `"sign_up_button"`) or `"ERR_001"` (becomes `"err_001"`) instead of having them silently rejected.
- **PII stripping extended** — PII auto-stripping (emails, phone numbers, SSN patterns) now applies to `detail`, `step`, and `code` fields in addition to `name`.
- **Abuse detection extended** — anti-identifier patterns (UUID, long hex, long numeric, all-hex) now apply to `detail`, `step`, and `code` fields. Fields matching abuse patterns are omitted rather than rejecting the entire event.
- Empty `detail` or `code` values no longer cause the entire event to be dropped — the event is recorded without the optional field.

## [0.2.0] - 2026-03-19

### Added

- Static singleton API: `Trackless.configure(apiKey:endpoint:)` with typed event methods
- Event types: `view(name:detail:)`, `feature(name:detail:)`, `funnel(name:stepIndex:stepName:)`, `performance(name:duration:threshold:)`, `error(name:severity:code:)`
- Automatic session lifecycle management with duration and screen depth tracking via `UIApplication` lifecycle notifications (`didEnterBackground`, `willEnterForeground`)
- Client-side event rollup — count-aggregatable events deduplicated and counted by key, performance durations collected into arrays
- Periodic flush every 60 seconds with auto-flush at 100 unique items
- Forced flush on app backgrounding and `destroy()`
- Circuit breaker with exponential backoff (30s → 1m → 5m → 15m → 60m) on 5xx/network errors; 4xx errors discard the batch without backoff
- Coarse context detection: platform, OS major version, device class (phone/tablet/desktop via UIDevice idiom), region, app version, build number, days since install
- Swift actor-based concurrency for thread-safe state management
- PII guard strips emails, phone numbers, and SSN patterns from event names before buffering
- Identifier rejection for UUIDs, long hex sequences, numeric-only strings, and hex-dominant strings
- Event name validation: lowercase alphanumeric with `_`, `-`, `.` (1–100 chars)
- Automatic environment detection via `#if DEBUG` (sandbox in debug builds, production otherwise)
- Conditional compilation support for macOS, tvOS, and visionOS
- Zero external dependencies (Foundation only)
- No IDFA/IDFV collection
- No client-side persistence
- Max buffer size of 1,000 unique items; max 100 events per HTTP request
- Published as Swift Package: `https://github.com/trackless-telemetry/sdk-ios`
