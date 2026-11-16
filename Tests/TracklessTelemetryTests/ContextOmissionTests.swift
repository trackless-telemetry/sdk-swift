import Testing
@testable import TracklessTelemetry

// A context value ingest would reject is left out, so the rest of the payload
// is accepted. Ingest validates the whole payload: one bad value used to cost
// the app every batch.
@Suite("Invalid context values are left out")
struct ContextOmissionTests {

    @Test("An empty value and a value with a space are omitted and named")
    func omitsInvalidValues() {
        let result = ContextDetection.omittingInvalid(TracklessEventContext(
            platform: "ios",
            osVersion: "18",
            deviceClass: "phone",
            appVersion: "1.0 (42)",
            buildNumber: "",
            sdkVersion: "ios/0.0.0"
        ))
        #expect(result.context.appVersion == nil)
        #expect(result.context.buildNumber == nil)
        #expect(result.context.osVersion == "18")
        #expect(result.context.deviceClass == "phone")
        #expect(result.context.sdkVersion == "ios/0.0.0")
        #expect(result.omitted == ["appVersion", "buildNumber"])
    }

    @Test("Valid values pass through unchanged")
    func keepsValidValues() {
        let context = TracklessEventContext(
            platform: "macos",
            osVersion: "15.3.1",
            appVersion: "2.4.1-beta_3",
            buildNumber: "42"
        )
        let result = ContextDetection.omittingInvalid(context)
        #expect(result.context == context)
        #expect(result.omitted.isEmpty)
    }

    @Test("Absent values are not reported")
    func absentValuesAreNotReported() {
        #expect(ContextDetection.omittingInvalid(TracklessEventContext()).omitted.isEmpty)
    }

    @Test("The app version rule is 1 to 50 ASCII letters, digits, dot, underscore or hyphen")
    func appVersionRule() {
        #expect(ContextDetection.isValidAppVersion(String(repeating: "a", count: 50)))
        #expect(!ContextDetection.isValidAppVersion(String(repeating: "a", count: 51)))
        #expect(!ContextDetection.isValidAppVersion(""))
        #expect(!ContextDetection.isValidAppVersion("1.0+build"))
        #expect(!ContextDetection.isValidAppVersion("1.0\n"))
        #expect(!ContextDetection.isValidAppVersion("١.٠"))
        #expect(!ContextDetection.isValidAppVersion("версия"))
    }

    @Test("The OS version rule is one to three dot-separated numbers")
    func osVersionRule() {
        #expect(ContextDetection.isValidOsVersion("18"))
        #expect(ContextDetection.isValidOsVersion("15.3.1"))
        #expect(!ContextDetection.isValidOsVersion("15.3.1.2"))
        #expect(!ContextDetection.isValidOsVersion("15."))
        #expect(!ContextDetection.isValidOsVersion("10_15"))
        #expect(!ContextDetection.isValidOsVersion(""))
    }

    @Test("An omitted osVersion is named in the result")
    func omitsInvalidOsVersion() {
        let result = ContextDetection.omittingInvalid(TracklessEventContext(osVersion: "10_15"))
        #expect(result.context.osVersion == nil)
        #expect(result.omitted == ["osVersion"])
    }

    @Test("The warning names the field and its Info.plist key")
    func warningNamesTheField() {
        #expect(ContextDetection.omittedWarning("appVersion").contains("CFBundleShortVersionString"))
        #expect(ContextDetection.omittedWarning("buildNumber").contains("CFBundleVersion"))
        #expect(ContextDetection.omittedWarning("osVersion").contains("osVersion"))
    }

    @Test("The detected context never carries a value ingest would reject")
    func detectedContextIsValid() {
        let context = ContextDetection.detect()
        if let value = context.appVersion { #expect(ContextDetection.isValidAppVersion(value)) }
        if let value = context.buildNumber { #expect(ContextDetection.isValidAppVersion(value)) }
        if let value = context.osVersion { #expect(ContextDetection.isValidOsVersion(value)) }
    }
}
