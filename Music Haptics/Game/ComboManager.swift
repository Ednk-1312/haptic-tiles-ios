import Foundation

/// Combo + multiplier. Multiplier steps: 1–9 → 1×, 10–24 → 2×, 25–49 → 3×, 50+ → 4×.
struct ComboManager {
    struct Config: Sendable {
        var thresholds: [(combo: Int, multiplier: Int)] = [(9, 1), (24, 2), (49, 3), (Int.max, 4)]
    }

    private let config: Config
    private(set) var combo = 0
    private(set) var maxCombo = 0

    init(config: Config = Config()) { self.config = config }

    var multiplier: Int {
        for t in config.thresholds where combo <= t.combo { return t.multiplier }
        return config.thresholds.last?.multiplier ?? 1
    }

    mutating func registerHit() {
        combo += 1
        maxCombo = max(maxCombo, combo)
    }

    mutating func registerMiss() {
        combo = 0
    }
}