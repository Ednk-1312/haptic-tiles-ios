import Foundation

/// Sandbox directories used by the app. Everything stays on-device.
enum AppDirectories {
    /// Test override: when set, every directory resolves under it (hermetic
    /// stress tests never touch the real sandbox).
    nonisolated(unsafe) static var testRootOverride: URL?

    /// Application Support root — never subscripts the URL array (a crash
    /// hazard every storage path would inherit); falls back to the temporary
    /// directory if the sandbox URL is somehow unavailable.
    private static func supportRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// Documents root with the same fallback policy.
    private static func documentsRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private static func root(_ name: String) -> URL {
        if let testRootOverride {
            let dir = testRootOverride.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return supportRoot().appendingPathComponent(name, isDirectory: true)
    }

    static var documentsDirectory: URL {
        if AppDirectories.testRootOverride != nil { return root("Documents") }
        return documentsRoot()
    }

    static var songsDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var analysisDirectory: URL {
        if AppDirectories.testRootOverride != nil { return root("Analysis") }
        let dir = supportRoot().appendingPathComponent("Analysis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var chartsDirectory: URL {
        if AppDirectories.testRootOverride != nil { return root("Charts") }
        let dir = supportRoot().appendingPathComponent("Charts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var aiDiagnosticsDirectory: URL {
        if AppDirectories.testRootOverride != nil { return root("AIDiagnostics") }
        let dir = supportRoot().appendingPathComponent("AIDiagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Small deterministic RNG (SplitMix64). Charts use it so regeneration with the
/// same seed always produces the same chart — important for reproducibility.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform value in [0, 1).
    mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

/// `shuffled(using:)` support (deterministic seeded shuffle, used by local
/// playlists). Additive conformance — behavior is unchanged.
extension SplitMix64: RandomNumberGenerator {}

/// Small formatting helpers shared by the UI.
enum Format {
    /// "3:45" style duration.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "847.2k" style compact numbers for scores.
    static func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }
}