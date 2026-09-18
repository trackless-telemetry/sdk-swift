import Foundation
import Testing

@testable import TracklessTelemetry

/// The Apple privacy manifest is a shipped artifact with no compiler checking it
/// and no runtime reading it, so nothing else would notice if it were malformed,
/// dropped from `Package.swift`, or drifted away from the App Store privacy-label
/// guidance in README.md and GUIDE.md.
///
/// These tests read the file from the source tree (via `#filePath`) rather than
/// from `Bundle.module`, so they assert the thing that actually gets copied into
/// a customer's app and synced to the standalone repo.
@Suite("PrivacyInfo.xcprivacy")
struct PrivacyManifestTests {

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // TracklessTelemetryTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root

    private static let manifestURL = packageRoot
        .appendingPathComponent("Sources/TracklessTelemetry/PrivacyInfo.xcprivacy")

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.manifestURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    @Test("The manifest exists at the path Apple expects and parses as a plist")
    func manifestParses() throws {
        #expect(FileManager.default.fileExists(atPath: Self.manifestURL.path))
        _ = try manifest()
    }

    @Test("Package.swift ships it as a target resource")
    func packageManifestDeclaresTheResource() throws {
        let packageSwift = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        // Without this line SwiftPM silently leaves the file out of the built
        // product and every customer's App Store submission loses the
        // declaration.
        #expect(packageSwift.contains(#".copy("PrivacyInfo.xcprivacy")"#))
    }

    @Test("Tracking is declared false with no tracking domains")
    func noTracking() throws {
        let manifest = try manifest()
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        let domains = try #require(manifest["NSPrivacyTrackingDomains"] as? [String])
        #expect(domains.isEmpty)
    }

    /// The SDK reads no file metadata (0.5.0 removed the install-date read that
    /// needed `C617.1`), so the manifest declares no required-reason API at all.
    /// A declaration reappearing here is the first sign that a read came back.
    @Test("No required-reason API is declared — not even file timestamps")
    func noRequiredReasonAPIs() throws {
        let manifest = try manifest()
        let apiTypes = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        #expect(apiTypes.isEmpty)
    }

    /// The SDK writes nothing to disk and reads no monotonic clock. Declaring
    /// either would be a false statement about the SDK, and would also be the
    /// first sign that someone added persistence or a boot-time clock.
    @Test("No UserDefaults or system-boot-time declarations")
    func noStorageOrBootTimeDeclarations() throws {
        let manifest = try manifest()
        let apiTypes = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let declared = apiTypes.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }

        #expect(!declared.contains("NSPrivacyAccessedAPICategoryUserDefaults"))
        #expect(!declared.contains("NSPrivacyAccessedAPICategorySystemBootTime"))
        #expect(!declared.contains("NSPrivacyAccessedAPICategoryDiskSpace"))
        #expect(!declared.contains("NSPrivacyAccessedAPICategoryActiveKeyboards"))
    }

    /// These three must stay in step with the "App Store Privacy Labels" table
    /// in README.md and GUIDE.md §9 — a customer reading one and submitting
    /// against the other is exactly the failure this is here to prevent.
    @Test("Collected data types match the documented App Store privacy labels")
    func collectedDataTypesMatchTheDocs() throws {
        let manifest = try manifest()
        let collected = try #require(
            manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
        )

        let types = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        #expect(
            types == [
                "NSPrivacyCollectedDataTypeProductInteraction",
                "NSPrivacyCollectedDataTypeOtherDiagnosticData",
                "NSPrivacyCollectedDataTypePerformanceData",
            ]
        )
    }

    @Test("Nothing collected is linked to the user or used for tracking")
    func nothingLinkedOrTracking() throws {
        let manifest = try manifest()
        let collected = try #require(
            manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
        )
        #expect(!collected.isEmpty)

        for entry in collected {
            let name = entry["NSPrivacyCollectedDataType"] as? String ?? "<unnamed>"
            #expect(
                entry["NSPrivacyCollectedDataTypeLinked"] as? Bool == false,
                "\(name) must be Not Linked to User Identity"
            )
            #expect(
                entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false,
                "\(name) must be Not Used for Tracking"
            )

            let purposes = entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []
            #expect(!purposes.isEmpty, "\(name) must declare at least one purpose")
            let allowed: Set<String> = [
                "NSPrivacyCollectedDataTypePurposeAnalytics",
                "NSPrivacyCollectedDataTypePurposeAppFunctionality",
            ]
            #expect(Set(purposes).isSubset(of: allowed), "\(name) declares an unexpected purpose")
        }
    }
}
