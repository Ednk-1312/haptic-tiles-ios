import Foundation

/// Difficulty presets. Each level carries its own chart-generation parameters
/// so difficulty is reproducible and tuned in one place.
enum DifficultyLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case easy, casual, medium, hard, expert, extreme

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .easy: return "Easy"
        case .casual: return "Casual"
        case .medium: return "Medium"
        case .hard: return "Hard"
        case .expert: return "Expert"
        case .extreme: return "Extreme"
        }
    }

    /// Target average notes-per-second for this difficulty.
    var targetNPS: Double {
        switch self {
        case .easy: return 1.2
        case .casual: return 2.0
        case .medium: return 3.0
        case .hard: return 4.2
        case .expert: return 5.5
        case .extreme: return 7.0
        }
    }

    /// Stable visual-speed multiplier for gameplay. Chart density and timing
    /// remain the primary difficulty differences; this adds a measurable,
    /// bounded movement distinction without changing the scoring timeline.
    var visualSpeedMultiplier: Double {
        switch self {
        case .easy: return 0.88
        case .casual: return 0.94
        case .medium: return 1.00
        case .hard: return 1.08
        case .expert: return 1.16
        case .extreme: return 1.25
        }
    }

    /// Scales how strongly this difficulty responds to the prepared intensity
    /// curve. It changes visual pacing only; note timestamps, hit windows and
    /// scoring remain identical at every level.
    var dynamicSpeedResponse: Double {
        switch self {
        case .easy: return 0.72
        case .casual: return 0.84
        case .medium: return 1.00
        case .hard: return 1.10
        case .expert: return 1.20
        case .extreme: return 1.28
        }
    }

    /// Minimum-to-maximum visual-speed range remains intentionally bounded.
    /// Keeping this value explicit makes the difficulty/profile contract easy
    /// to test and prevents a future tuning change from creating runaway speed.
    var dynamicSpeedRange: ClosedRange<Double> {
        switch self {
        case .easy: return 0.80...1.08
        case .casual: return 0.82...1.12
        case .medium: return 0.78...1.22
        case .hard: return 0.78...1.30
        case .expert: return 0.76...1.40
        case .extreme: return 0.74...1.48
        }
    }

    /// Minimum gap between two notes (seconds). Prevents unplayable clusters.
    var minSpacing: Double {
        switch self {
        case .easy: return 0.32
        case .casual: return 0.24
        case .medium: return 0.18
        case .hard: return 0.14
        case .expert: return 0.11
        case .extreme: return 0.09
        }
    }

    /// Maximum notes that may overlap in time.
    var maxSimultaneous: Int {
        switch self {
        case .easy, .casual: return 1
        case .medium, .hard, .expert, .extreme: return 2
        }
    }

    /// Maps a 0–10 difficulty score to a level label.
    static func level(forScore score: Double) -> DifficultyLevel {
        switch score {
        case ..<2.0: return .easy
        case ..<3.5: return .casual
        case ..<5.0: return .medium
        case ..<6.5: return .hard
        case ..<8.0: return .expert
        default: return .extreme
        }
    }
}

/// Declaration-order comparison (easy < casual < … < extreme). Raw-value
/// ordering would be alphabetical and wrong ("casual" < "easy").
extension DifficultyLevel: Comparable {
    static func < (lhs: DifficultyLevel, rhs: DifficultyLevel) -> Bool {
        let l = Self.allCases.firstIndex(of: lhs) ?? 0
        let r = Self.allCases.firstIndex(of: rhs) ?? 0
        return l < r
    }
}

/// Measurable difficulty features of a chart. The calculation is deterministic:
/// the same chart always produces the same score.
struct DifficultyMetrics: Codable, Sendable {
    var score10: Double
    var label: DifficultyLevel
    var notesPerSecond: Double
    var averageInterval: Double
    var maxBurstNPS: Double       // max notes in any 1s window
    var simultaneityRatio: Double
    var averageJumpDistance: Double
    var alternationRatio: Double
    var intervalStdDev: Double
    var spikeRatio: Double        // burst vs overall NPS (difficulty spikes)
    var sustainedNPS: Double
}