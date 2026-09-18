// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TracklessTelemetry",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "TracklessTelemetry", targets: ["TracklessTelemetry"]),
    ],
    targets: [
        .target(
            name: "TracklessTelemetry",
            path: "Sources/TracklessTelemetry",
            // Apple privacy manifest. `.copy` keeps the file verbatim — it must
            // ship as `PrivacyInfo.xcprivacy`, not be processed or renamed.
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "TracklessTelemetryTests", dependencies: ["TracklessTelemetry"]),
    ]
)
