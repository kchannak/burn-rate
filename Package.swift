// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Burnrate",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BurnrateApp", targets: ["BurnrateApp"]),
        .executable(name: "burnrate", targets: ["burnrate-cli"]),
        .library(name: "UsageCore", targets: ["UsageCore"]),
    ],
    targets: [
        // Log parsing and aggregation. Foundation only, so it is testable without a UI.
        .target(name: "UsageCore"),
        // Command-line report over the same data, handy for checking numbers.
        .executableTarget(name: "burnrate-cli", dependencies: ["UsageCore"]),
        // The macOS menu bar + window app.
        .executableTarget(name: "BurnrateApp", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
