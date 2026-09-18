import Foundation
#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

/// Detects coarse device context from system APIs.
///
/// Privacy invariants enforced:
/// - NO IDFA collection (no AdSupport framework)
/// - NO IDFV collection (no UIDevice.identifierForVendor)
/// - NO device name or model string (Invariant 2)
/// - NO carrier info or telephony data
/// - NO IP-based geolocation (Invariant 4)
/// - Region from system Locale only, never from network info
/// - NO record about this installation or its acquisition: no install date, no
///   App Store receipt, no file timestamps. Only runtime properties the OS
///   exposes to every app and constants compiled into the app itself.
enum ContextDetection {

    /// The version this build reports, without the platform prefix.
    private static let version = "0.5.0"

    /// The `platform` dimension for this build.
    ///
    /// `#if os(macOS)` is true only for a **native AppKit** build. Mac Catalyst
    /// and "Designed for iPad" apps compile as `os(iOS)` and so keep reporting
    /// `"ios"` — which is correct: they are UIKit apps with UIKit's lifecycle,
    /// and the SDK behaves as it does on an iPad there.
    #if os(macOS)
    static let platform = "macos"
    #else
    static let platform = "ios"
    #endif

    /// `<platform>/<version>`, e.g. `"macos/0.5.0"`. One Swift package publishes
    /// both, so the version after the slash is the same on either platform.
    static let sdkVersion = "\(platform)/\(version)"

    /// Detect coarse device context. Captured once at configure time.
    static func detect() -> TracklessEventContext {
        TracklessEventContext(
            platform: platform,
            osVersion: detectOsVersion(),
            deviceClass: detectDeviceClass(),
            region: detectRegion(),
            language: detectLanguage(),
            appVersion: detectAppVersion(),
            buildNumber: detectBuildNumber(),
            sdkVersion: sdkVersion
        )
    }

    // MARK: - Private

    /// Extract major OS version only.
    private static func detectOsVersion() -> String? {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion)"
    }

    /// Detect device class from UIDevice.current.userInterfaceIdiom.
    private static func detectDeviceClass() -> String? {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let idiom = UIDevice.current.userInterfaceIdiom
        switch idiom {
        case .phone:
            return "phone"
        case .pad:
            return "tablet"
        case .mac:
            return "desktop"
        case .tv:
            return "desktop"
        case .carPlay:
            return nil
        case .unspecified:
            return nil
        @unknown default:
            return nil
        }
        #elseif os(macOS)
        return "desktop"
        #else
        return nil
        #endif
    }

    /// Extract country code from system Locale (e.g., "US").
    /// Derived from system setting, NOT from IP address.
    private static func detectRegion() -> String? {
        if #available(iOS 16, macOS 13, *) {
            return Locale.current.region?.identifier
        } else {
            // iOS 15 / macOS 12 fallback
            return Locale.current.regionCode
        }
    }

    /// Extract ISO 639-1 language code from system Locale (e.g., "en", "fr").
    /// Derived from system setting only.
    private static func detectLanguage() -> String? {
        if #available(iOS 16, macOS 13, *) {
            return Locale.current.language.languageCode?.identifier.lowercased()
        } else {
            // iOS 15 / macOS 12 fallback — extract language from locale identifier
            let identifier = Locale.current.identifier
            let language = identifier.components(separatedBy: CharacterSet(charactersIn: "_-")).first
            return language?.lowercased()
        }
    }

    /// App version from Bundle.main (e.g., "1.2.3").
    private static func detectAppVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Build number from Bundle.main (e.g., "42").
    private static func detectBuildNumber() -> String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }
}
