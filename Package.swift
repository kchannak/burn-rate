// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageTracker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeUsageTracker", targets: ["ClaudeUsageTracker"]),
        .executable(name: "claude-usage", targets: ["claude-usage"]),
        .library(name: "UsageCore", targets: ["UsageCore"]),
    ],
    targets: [
        // Log parsing and aggregation. Foundation only, so it is testable without a UI.
        .target(name: "UsageCore"),
        // Command-line report over the same data, handy for checking numbers.
        .executableTarget(name: "claude-usage", dependencies: ["UsageCore"]),
        // The macOS menu bar + window app.
        .executableTarget(name: "ClaudeUsageTracker", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
