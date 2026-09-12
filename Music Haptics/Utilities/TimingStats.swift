import Foundation

/// Tiny rolling statistics for frame/judgment telemetry (Debug diagnostics).
/// Uses an incremental mean, so it never stores the full sample history.
struct RollingStats: Sendable {
    private(set) var count = 0
    private(set) var mean: Double = 0
    private(set) var max: Double = 0

    mutating func add(_ value: Double) {
        count += 1
        let n = Double(count)
        // Incremental mean: mean += (value − mean) / n
        mean = mean + (value - mean) / n
        if value > max { max = value }
    }

    mutating func reset() {
        count = 0
        mean = 0
        max = 0
    }
}