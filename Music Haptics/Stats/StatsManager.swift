import Foundation
import Observation

/// One difficulty tier's statistics for a song. Easy and Expert records are
/// NEVER mixed — every aggregation is per difficulty first, rolled up per song.
struct DifficultyStats: Codable, Sendable, Equatable {
    var difficulty: DifficultyLevel
    var attempts: Int = 0
    var highestScore: Int = 0
    var bestAccuracy: Double = 0        // 0…1
    var highestCombo: Int = 0
    var perfectCount: Int = 0
    var greatCount: Int = 0
    var goodCount: Int = 0
    var missCount: Int = 0
    var bestHoldsCompleted: Int = 0
    var lastPlayed: Date?
    var playTime: Double = 0
    /// Chart version the best run used (informational; a chart regeneration
    /// does NOT reset statistics).
    var bestChartVersion: Int?

    var notesHit: Int { perfectCount + greatCount + goodCount }
    var notesJudged: Int { notesHit + missCount }
    var accuracy: Double {
        notesJudged > 0 ? Double(notesHit) / Double(notesJudged) : 0
    }
}

/// Rolled-up statistics for one song (across all difficulties).
struct SongStats: Codable, Sendable, Equatable {
    var songID: UUID
    var title: String
    var perDifficulty: [DifficultyStats] = []

    var totalAttempts: Int { perDifficulty.reduce(0) { $0 + $1.attempts } }
    var highestScore: Int { perDifficulty.map(\.highestScore).max() ?? 0 }
    var bestAccuracy: Double { perDifficulty.map(\.bestAccuracy).max() ?? 0 }
    var highestCombo: Int { perDifficulty.map(\.highestCombo).max() ?? 0 }
    var totalNotesHit: Int { perDifficulty.reduce(0) { $0 + $1.notesHit } }
    var totalNotesJudged: Int { perDifficulty.reduce(0) { $0 + $1.notesJudged } }
    var overallAccuracy: Double {
        totalNotesJudged > 0 ? Double(totalNotesHit) / Double(totalNotesJudged) : 0
    }
    var lastPlayed: Date? { perDifficulty.compactMap(\.lastPlayed).max() }
    var totalPlayTime: Double { perDifficulty.reduce(0) { $0 + $1.playTime } }
    var bestDifficulty: DifficultyLevel? {
        perDifficulty.filter { $0.attempts > 0 }.map(\.difficulty).max()
    }

    func stats(for difficulty: DifficultyLevel) -> DifficultyStats? {
        perDifficulty.first { $0.difficulty == difficulty }
    }
}

/// Aggregates across every song (the statistics screen's headline numbers).
struct GlobalStats: Codable, Sendable, Equatable {
    var totalSongsPlayed: Int
    var totalAttempts: Int
    var totalNotesHit: Int
    var totalNotesJudged: Int
    var overallAccuracy: Double
    var highestCombo: Int
    var hardestChartCleared: DifficultyLevel?
    var totalGameplayTime: Double

    static func compute(from songs: [SongStats]) -> GlobalStats {
        GlobalStats(
            totalSongsPlayed: songs.filter { $0.totalAttempts > 0 }.count,
            totalAttempts: songs.reduce(0) { $0 + $1.totalAttempts },
            totalNotesHit: songs.reduce(0) { $0 + $1.totalNotesHit },
            totalNotesJudged: songs.reduce(0) { $0 + $1.totalNotesJudged },
            overallAccuracy: {
                let judged = songs.reduce(0) { $0 + $1.totalNotesJudged }
                let hit = songs.reduce(0) { $0 + $1.totalNotesHit }
                return judged > 0 ? Double(hit) / Double(judged) : 0
            }(),
            highestCombo: songs.map(\.highestCombo).max() ?? 0,
            hardestChartCleared: songs.compactMap(\.bestDifficulty).max(),
            totalGameplayTime: songs.reduce(0) { $0 + $1.totalPlayTime }
        )
    }
}

/// A personal record broken by the latest run (displayed on the results
/// screen right after the run).
enum StatMilestone: Sendable, Equatable {
    case newHighScore(old: Int, new: Int)
    case newBestAccuracy(old: Double, new: Double)
    case newBestCombo(old: Int, new: Int)
    case newBestDifficulty(old: DifficultyLevel?, new: DifficultyLevel)

    var title: String {
        switch self {
        case .newHighScore: return "New High Score"
        case .newBestAccuracy: return "New Best Accuracy"
        case .newBestCombo: return "New Best Combo"
        case .newBestDifficulty: return "New Best Difficulty"
        }
    }
}

/// Local statistics: per-song + per-difficulty records, personal-record
/// detection, global aggregates. Pure state machine with versioned JSON
/// persistence (`stats.json`) — statistics never leave the device.
@MainActor
@Observable
final class StatsManager {
    private(set) var stats: [UUID: SongStats] = [:]

    // Workaround for swiftlang/swift#87316: an inferred MainActor-isolated
    // deinit crashes in swift_task_deinitOnExecutorImpl/StopLookupScope when
    // the last reference is released off the main thread (XCTest hosts and
    // background completion paths). An explicit empty nonisolated deinit
    // sidesteps the buggy executor-hop teardown.
    deinit {}

    init(snapshot: StatsSnapshot? = nil) {
        if let snapshot {
            restore(snapshot)
        }
    }

    // MARK: - Recording

    /// Records a completed run, returns the personal records it broke.
    /// - Parameters:
    ///   - result: the finished run (practice/autoplay runs are filtered by
    ///     the caller).
    ///   - songID: stable song record ID.
    ///   - chartVersion: version of the chart that was played (informational).
    @discardableResult
    func record(_ result: GameplayResult, for songID: UUID, chartVersion: Int?) -> [StatMilestone] {
        var song = stats[songID] ?? SongStats(songID: songID, title: result.songTitle)
        song.title = result.songTitle

        let old = song.stats(for: result.difficulty)
        var tier = old ?? DifficultyStats(difficulty: result.difficulty)

        var milestones: [StatMilestone] = []
        if result.score > tier.highestScore {
            milestones.append(.newHighScore(old: tier.highestScore, new: result.score))
        }
        if result.accuracy > tier.bestAccuracy {
            milestones.append(.newBestAccuracy(old: tier.bestAccuracy, new: result.accuracy))
        }
        if result.maxCombo > tier.highestCombo {
            milestones.append(.newBestCombo(old: tier.highestCombo, new: result.maxCombo))
        }
        let bestBefore = song.bestDifficulty
        if result.difficulty > (bestBefore ?? .easy) {
            milestones.append(.newBestDifficulty(old: bestBefore, new: result.difficulty))
        }

        // Cumulative counters always accumulate (they are totals, not bests).
        tier.attempts += 1
        tier.perfectCount += result.perfectCount
        tier.greatCount += result.greatCount
        tier.goodCount += result.goodCount
        tier.missCount += result.missCount
        tier.playTime += max(0, result.playedDuration)
        tier.lastPlayed = result.date
        if result.holdsCompleted > tier.bestHoldsCompleted {
            tier.bestHoldsCompleted = result.holdsCompleted
        }
        tier.highestScore = max(tier.highestScore, result.score)
        tier.bestAccuracy = max(tier.bestAccuracy, result.accuracy)
        tier.highestCombo = max(tier.highestCombo, result.maxCombo)
        // The best belongs to this run when it matched or beat the previous
        // best (ties keep the newer chart version).
        if result.score >= tier.highestScore {
            tier.bestChartVersion = chartVersion
        }

        song.perDifficulty.removeAll { $0.difficulty == result.difficulty }
        song.perDifficulty.append(tier)
        stats[songID] = song
        persist()
        return milestones
    }

    // MARK: - Queries

    func stats(for songID: UUID) -> SongStats? {
        stats[songID]
    }

    func difficultyStats(for songID: UUID, difficulty: DifficultyLevel) -> DifficultyStats? {
        stats[songID]?.stats(for: difficulty)
    }

    var global: GlobalStats {
        GlobalStats.compute(from: Array(stats.values))
    }

    /// Songs that have at least one attempt, newest-last-played first.
    var playedSongs: [SongStats] {
        stats.values
            .filter { $0.totalAttempts > 0 }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    /// Removes a song's statistics (app-side song deletion keeps the store
    /// clean; re-importing starts fresh statistics for the new record).
    func removeSong(_ songID: UUID) {
        guard stats[songID] != nil else { return }
        stats[songID] = nil
        persist()
    }

    // MARK: - Persistence

    func snapshot() -> StatsSnapshot {
        StatsSnapshot(schemaVersion: StatsSnapshot.currentSchemaVersion,
                      stats: Array(stats.values))
    }

    private func restore(_ snapshot: StatsSnapshot) {
        guard snapshot.schemaVersion <= StatsSnapshot.currentSchemaVersion else { return }
        var restored: [UUID: SongStats] = [:]
        for song in snapshot.stats {
            var fixed = song
            // Defensive: drop records with invalid difficulty raws or negative
            // counters (hand-edited/corrupt files never crash or skew totals).
            fixed.perDifficulty.removeAll { $0.difficulty.rawValue.isEmpty || $0.attempts < 0 }
            fixed.perDifficulty = fixed.perDifficulty.map {
                var tier = $0
                tier.playTime = max(0, tier.playTime)
                tier.bestAccuracy = min(max(0, tier.bestAccuracy), 1)
                return tier
            }
            restored[song.songID] = fixed
        }
        stats = restored
    }

    private func persist() {
        StatsStorage.save(snapshot())
    }
}

/// Codable on-disk state for statistics (versioned like the queue/playlists).
struct StatsSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var stats: [SongStats]
}

/// JSON persistence (application support directory, on-device only).
enum StatsStorage {
    private static var url: URL {
        AppDirectories.documentsDirectory.appendingPathComponent("stats.json")
    }

    static func save(_ snapshot: StatsSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    /// nil on missing/corrupt/incompatible data — callers start empty.
    static func load() -> StatsSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(StatsSnapshot.self, from: data),
              snapshot.schemaVersion <= StatsSnapshot.currentSchemaVersion else {
            return nil
        }
        return snapshot
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}