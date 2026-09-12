import Foundation

enum GameplayState: String, Sendable {
    case ready, playing, paused, finished
}

/// Quality of a hit; points are defined in ScoreManager.
enum Judgment: String, Codable, Sendable, CaseIterable {
    case perfect, great, good, miss
    var displayName: String { rawValue.capitalized }
}

/// Per-note gameplay state.
struct NoteHitState: Sendable {
    var judgment: Judgment?
    /// Audio-clock time of the judgment (for the 80–150 ms hit effect).
    var judgedAt: Double?
}

/// A transient judgment popup shown near the hit line.
struct JudgmentFeedback: Identifiable, Sendable {
    let id = UUID()
    let judgment: Judgment
    let lane: Int
    let time: Double

    init(judgment: Judgment, lane: Int, time: Double) {
        self.judgment = judgment
        self.lane = lane
        self.time = time
    }
}

/// A short lane flash after a strong hit.
struct LaneFlash: Identifiable, Sendable {
    let id = UUID()
    let lane: Int
    let time: Double
    let intensity: Double

    init(lane: Int, time: Double, intensity: Double) {
        self.lane = lane
        self.time = time
        self.intensity = intensity
    }
}

/// A transient "+HOLD" bonus popup shown after a hold is sustained to its tail.
struct HoldPopup: Identifiable, Sendable {
    let id = UUID()
    let lane: Int
    let time: Double
    let points: Int

    init(lane: Int, time: Double, points: Int) {
        self.lane = lane
        self.time = time
        self.points = points
    }
}

/// Everything needed to start a play session (passed into GameView).
struct GameSession: Identifiable, Sendable {
    let id = UUID()
    let chart: Chart
    let analysis: AudioAnalysis?
    let audioURL: URL
    let title: String
    /// Non-nil when this is a practice session. The chart is untouched;
    /// practice adds a speed/section/loop configuration on top of it.
    var practice: PracticeConfig?
}