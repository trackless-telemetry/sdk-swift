import Testing
import Foundation
@testable import TracklessTelemetry

@Suite("ContextDetection Tests")
struct ContextDetectionTests {

    // MARK: - Platform

    /// The platform this test bundle is running on. `swift test` is a macOS host
    /// build, so this is `"macos"` locally and `"ios"` in a simulator run — which
    /// is the point: both values are exercised, and neither is written twice.
    ///
    /// Mac Catalyst and "Designed for iPad" builds are `os(iOS)` and so report
    /// `"ios"`, by design.
    private static let expectedPlatform: String = {
        #if os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }()

    @Test("Platform is macos on a native macOS build and ios elsewhere")
    func platformMatchesBuild() {
        let ctx = ContextDetection.detect()
        #expect(ctx.platform == Self.expectedPlatform)
    }

    // MARK: - OS Version

    @Test("OS version is major version only")
    func osVersionExtracted() {
        let ctx = ContextDetection.detect()
        #expect(ctx.osVersion != nil)
        if let osVersion = ctx.osVersion {
            #expect(Int(osVersion) != nil)
            // Should match ProcessInfo major version
            let expectedMajor = String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
            #expect(osVersion == expectedMajor)
        }
    }

    // MARK: - Device Class

    @Test("Device class is a valid value or nil")
    func deviceClassValid() {
        let ctx = ContextDetection.detect()
        let validValues: Set<String?> = ["phone", "tablet", "desktop", nil]
        #expect(validValues.contains(ctx.deviceClass))
    }

    // MARK: - Region

    @Test("Region is non-empty country code or nil")
    func regionDetected() {
        let ctx = ContextDetection.detect()
        if let region = ctx.region {
            #expect(!region.isEmpty)
            // Country codes are 2 uppercase letters
            #expect(region.count == 2)
            #expect(region == region.uppercased())
        }
    }

    // MARK: - Language

    @Test("Language is non-empty lowercase code or nil")
    func languageDetected() {
        let ctx = ContextDetection.detect()
        if let language = ctx.language {
            #expect(!language.isEmpty)
            // Language codes are 2-3 lowercase letters (ISO 639-1)
            #expect(language.count >= 2 && language.count <= 3)
            #expect(language == language.lowercased())
        }
    }

    // MARK: - No Identifiers

    @Test("Context struct does not contain any identifiers")
    func noIdentifiers() {
        let ctx = ContextDetection.detect()
        #expect(ctx.platform == Self.expectedPlatform)
        if let osVersion = ctx.osVersion {
            #expect(Int(osVersion) != nil)
        }
        if let dc = ctx.deviceClass {
            let allowed = ["phone", "tablet", "desktop"]
            #expect(allowed.contains(dc))
        }
    }

    // MARK: - No install metadata, no distribution channel

    /// The SDK reads nothing the OS, the filesystem or the App Store keeps about
    /// this installation. Before 0.5.0 it read an install date (App Store
    /// receipt, then a file creation date) and sent it as `daysSinceInstall`,
    /// and sent the install source as `distributionChannel`. If either key
    /// ever reappears on the wire, an install-metadata read came back.
    @Test("The encoded context carries no daysSinceInstall or distributionChannel, only runtime/compiled fields")
    func encodedContextHasNoInstallAgeOrChannel() throws {
        let data = try JSONEncoder().encode(ContextDetection.detect())
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["daysSinceInstall"] == nil)
        #expect(object["distributionChannel"] == nil)
        let allowed: Set<String> = [
            "platform", "osVersion", "deviceClass", "region", "language",
            "appVersion", "buildNumber", "sdkVersion",
        ]
        #expect(Set(object.keys).isSubset(of: allowed))
    }

    // MARK: - SDK Version

    @Test("SDK version is present and prefixed with this build's platform")
    func sdkVersionPresent() {
        let ctx = ContextDetection.detect()
        #expect(ctx.sdkVersion != nil)
        if let sdkVersion = ctx.sdkVersion {
            #expect(sdkVersion.hasPrefix("\(Self.expectedPlatform)/"))
            // One Swift package, one changelog, one tag: the version after the
            // slash must not vary by platform.
            #expect(sdkVersion.split(separator: "/").last?.split(separator: ".").count == 3)
        }
    }

    // MARK: - Environment Auto-Detection

    @Test("Environment auto-detection returns sandbox in DEBUG builds")
    func environmentAutoDetection() {
        let env = Trackless.detectEnvironment()
        #if DEBUG
        #expect(env == .sandbox)
        #else
        #expect(env == .production)
        #endif
    }
}
