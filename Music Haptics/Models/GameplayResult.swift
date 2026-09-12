import Foundation

/// Results of one playthrough, shown on the results screen.
struct GameplayResult: Codable, Sendable {
    var songTitle: String
    var difficulty: DifficultyLevel
    var score: Int
    var maxCombo: Int
    var perfectCount: Int
    var greatCount: Int
    var goodCount: Int
    var missCount: Int
    var accuracy: Double   // 0…1
    var date: Date
    /// Holds sustained to their tail (bonus scored) / released early.
    var holdsCompleted: Int
    var holdsMissed: Int
    /// Seconds of audio actually played this run (authoritative clock at
    /// finish). Contributes to total play time statistics.
    var playedDuration: Double = 0

    var judgedCount: Int { perfectCount + greatCount + goodCount + missCount }
}