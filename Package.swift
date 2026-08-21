// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PowerTelemetry",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PowerTelemetry",
            path: "Sources/PowerTelemetry"
        ),
        .testTarget(
            name: "PowerTelemetryTests",
            dependencies: ["PowerTelemetry"],
            path: "Tests/PowerTelemetryTests"
        )
    ]
)
