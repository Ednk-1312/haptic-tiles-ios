import Foundation

/// Straightforward scoring: Perfect 1000, Great 750, Good 500, Miss 0,
/// multiplied by the combo multiplier.
struct ScoreManager {
    struct Config: Sendable {
        var points: [Judgment: Int] = [.perfect: 1000, .great: 750, .good: 500, .miss: 0]
    }

    private var combo = ComboManager()
    private let config: Config
    private(set) var score = 0
    private(set) var counts: [Judgment: Int] = [:]
    private(set) var holdsCompleted = 0
    private(set) var holdsMissed = 0

    init(config: Config = Config()) { self.config = config }

    var maxCombo: Int { combo.maxCombo }
    var comboCount: Int { combo.combo }
    var multiplier: Int { combo.multiplier }

    mutating func apply(_ judgment: Judgment) {
        counts[judgment, default: 0] += 1
        if judgment == .miss {
            combo.registerMiss()
            return
        }
        let base = config.points[judgment] ?? 0
        score += base * combo.multiplier
        combo.registerHit()
    }

    /// A hold was sustained to its tail: configurable bonus at the current
    /// multiplier. The head tap already counted as a normal hit; the bonus
    /// rewards keeping the finger down. No combo change (the combo already
    /// grew on the head).
    mutating func completeHold(bonus: Int = 500) {
        holdsCompleted += 1
        score += max(0, bonus) * combo.multiplier
    }

    /// A hold was released before its tail (or its head was never hit).
    mutating func missHold() {
        holdsMissed += 1
        combo.registerMiss()
    }

    /// A hold was released early but genuinely sustained: bank the partial
    /// progress as a proportional bonus. No combo break and no miss — the
    /// player is rewarded for what they held instead of double-penalized.
    mutating func bankPartialHold(progress: Double, bonus: Int = 500) {
        let fraction = min(1, max(0, progress))
        guard fraction > 0 else { return }
        holdsCompleted += 1
        score += Int(Double(max(0, bonus)) * fraction) * combo.multiplier
    }

    /// 0…1 weighted accuracy over judged notes.
    var accuracy: Double {
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return 0 }
        let weighted = Double(counts[.perfect] ?? 0)
            + 0.75 * Double(counts[.great] ?? 0)
            + 0.5 * Double(counts[.good] ?? 0)
        return weighted / Double(total)
    }
}