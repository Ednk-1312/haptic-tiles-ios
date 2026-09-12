// swift-tools-version: 6.0
// Logic-test package: compiles the app's platform-neutral analysis/chart/game
// sources (via symlinks — single source of truth) and runs the unit tests on
// macOS, since this repo's machine can't drive the iOS simulator from CLI.
import PackageDescription

let package = Package(
    name: "HapticPianoLogicTests",
    platforms: [.macOS(.v14)],
    products: [
        // Module name matches the iOS app module so @testable import works unchanged.
        .library(name: "Music_Haptics", targets: ["Music_Haptics"])
    ],
    targets: [
        .target(name: "Music_Haptics", path: "Sources/Music_Haptics"),
        .testTarget(name: "MusicHapticsTests",
                    dependencies: ["Music_Haptics"],
                    path: "Tests/MusicHapticsTests"),
        // Generates labeled training data (JSONL) from the real pipeline.
        // Run: swift run TrainingExport [outDir] [songCount]
        .executableTarget(name: "TrainingExport",
                          dependencies: ["Music_Haptics"],
                          path: "Sources/TrainingExport"),
        // Before/after chart-quality report (v3 legacy vs v4 patterns).
        // Run: swift run ChartStats
        .executableTarget(name: "ChartStats",
                          dependencies: ["Music_Haptics"],
                          path: "Sources/ChartStats")
    ]
)