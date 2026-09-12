import XCTest
@testable import Music_Haptics

/// Deterministic statistics tests. StatsManager is a pure state machine with
/// JSON persistence — every behavior is reproducible.
final class StatsTests: XCTestCase {
    override func setUpWithError() throws {
        StatsStorage.delete()
    }

    override func tearDownWithError() throws {
        StatsStorage.delete()
    }

    private func result(song: String = "Song", difficulty: DifficultyLevel = .medium,
                        score: Int = 1000, accuracy: Double = 0.9, combo: Int = 50,
                        perfect: Int = 45, great: Int = 5, good: Int = 0, miss: Int = 0,
                        holds: Int = 0, holdsMissed: Int = 0, played: Double = 120,
                        date: Date = Date(timeIntervalSince1970: 1_000)) -> GameplayResult {
        GameplayResult(songTitle: song, difficulty: difficulty, score: score, maxCombo: combo,
                       perfectCount: perfect, greatCount: great, goodCount: good, missCount: miss,
                       accuracy: accuracy, date: date, holdsCompleted: holds, holdsMissed: holdsMissed,
                       playedDuration: played)
    }

    // MARK: - First run

    @MainActor
    func testFirstRunCreatesRecordsAndMilestones() {
        let manager = StatsManager()
        let id = UUID()
        let milestones = manager.record(result(), for: id, chartVersion: 7)

        XCTAssertEqual(milestones.count, 4)   // score, accuracy, combo, difficulty all new
        XCTAssertTrue(milestones.contains { if case .newHighScore = $0 { return true }; return false })
        XCTAssertTrue(milestones.contains { if case .newBestAccuracy = $0 { return true }; return false })
        XCTAssertTrue(milestones.contains { if case .newBestCombo = $0 { return true }; return false })
        XCTAssertTrue(milestones.contains { if case .newBestDifficulty = $0 { return true }; return false })

        let song = manager.stats(for: id)
        XCTAssertEqual(song?.totalAttempts, 1)
        XCTAssertEqual(song?.highestScore, 1000)
        XCTAssertEqual(song?.bestAccuracy ?? 0, 0.9, accuracy: 0.0001)
        XCTAssertEqual(song?.highestCombo, 50)
        XCTAssertEqual(song?.bestDifficulty, .medium)
        XCTAssertEqual(song?.totalPlayTime ?? 0, 120)
        XCTAssertEqual(song?.stats(for: .medium)?.bestChartVersion, 7)
        XCTAssertEqual(manager.global.totalSongsPlayed, 1)
        XCTAssertEqual(manager.global.totalAttempts, 1)
        XCTAssertEqual(manager.global.hardestChartCleared, .medium)
    }

    // MARK: - Improvements and worse results

    @MainActor
    func testBetterRunReplacesBestsAndAccumulatesCounters() {
        let manager = StatsManager()
        let id = UUID()
        _ = manager.record(result(score: 1000, accuracy: 0.9, combo: 50,
                                  perfect: 45, great: 5, miss: 0, played: 120), for: id, chartVersion: 1)

        let better = manager.record(result(score: 1400, accuracy: 0.95, combo: 80,
                                           perfect: 50, great: 2, miss: 1, played: 118),
                                    for: id, chartVersion: 1)
        // Score, accuracy and combo are new; difficulty already cleared.
        XCTAssertEqual(better.count, 3)
        let song = manager.stats(for: id)!
        XCTAssertEqual(song.totalAttempts, 2)
        XCTAssertEqual(song.highestScore, 1400)
        XCTAssertEqual(song.bestAccuracy, 0.95, accuracy: 0.0001)
        XCTAssertEqual(song.highestCombo, 80)
        // Counters accumulate across both runs (totals, not bests).
        let tier = song.stats(for: .medium)!
        XCTAssertEqual(tier.perfectCount, 95)
        XCTAssertEqual(tier.greatCount, 7)
        XCTAssertEqual(tier.missCount, 1)
        XCTAssertEqual(tier.playTime, 238, accuracy: 0.0001)
    }

    @MainActor
    func testWorseRunNeverDowngradesBests() {
        let manager = StatsManager()
        let id = UUID()
        _ = manager.record(result(score: 1400, accuracy: 0.95, combo: 80), for: id, chartVersion: 1)
        let worse = manager.record(result(score: 900, accuracy: 0.7, combo: 30), for: id, chartVersion: 1)

        XCTAssertTrue(worse.isEmpty)   // nothing new
        let song = manager.stats(for: id)!
        XCTAssertEqual(song.highestScore, 1400)
        XCTAssertEqual(song.bestAccuracy, 0.95, accuracy: 0.0001)
        XCTAssertEqual(song.highestCombo, 80)
        XCTAssertEqual(song.totalAttempts, 2)   // attempts still count
    }

    @MainActor
    func testMilestoneCarriesOldAndNewValues() {
        let manager = StatsManager()
        let id = UUID()
        _ = manager.record(result(score: 1000), for: id, chartVersion: 1)
        let milestone = manager.record(result(score: 1500), for: id, chartVersion: 1)
            .compactMap { m -> StatMilestone? in
                if case .newHighScore = m { return m }; return nil
            }
        guard case .newHighScore(let old, let new) = milestone.first else {
            return XCTFail("expected high-score milestone")
        }
        XCTAssertEqual(old, 1000)
        XCTAssertEqual(new, 1500)
    }

    // MARK: - Difficulty separation

    @MainActor
    func testDifficultiesNeverMix() {
        let manager = StatsManager()
        let id = UUID()
        _ = manager.record(result(difficulty: .easy, score: 500, accuracy: 0.8, combo: 20), for: id, chartVersion: 1)
        _ = manager.record(result(difficulty: .expert, score: 3000, accuracy: 0.75, combo: 60), for: id, chartVersion: 1)
        _ = manager.record(result(difficulty: .easy, score: 600, accuracy: 0.85, combo: 30), for: id, chartVersion: 1)

        let song = manager.stats(for: id)!
        let easy = song.stats(for: .easy)!
        let expert = song.stats(for: .expert)!
        XCTAssertEqual(easy.attempts, 2)
        XCTAssertEqual(expert.attempts, 1)
        XCTAssertEqual(easy.highestScore, 600)          // easy best, not expert's 3000
        XCTAssertEqual(expert.highestScore, 3000)
        XCTAssertEqual(easy.bestAccuracy, 0.85, accuracy: 0.0001)
        XCTAssertEqual(expert.bestAccuracy, 0.75, accuracy: 0.0001)
        XCTAssertEqual(easy.highestCombo, 30)
        XCTAssertEqual(expert.highestCombo, 60)
        // Song rollups take the best across tiers; best difficulty is expert.
        XCTAssertEqual(song.highestScore, 3000)
        XCTAssertEqual(song.bestDifficulty, .expert)
        XCTAssertEqual(song.totalAttempts, 3)
        XCTAssertEqual(song.totalPlayTime, 360, accuracy: 0.0001)
    }

    @MainActor
    func testBestDifficultyMilestoneOnlyOnNewMax() {
        let manager = StatsManager()
        let id = UUID()
        _ = manager.record(result(difficulty: .easy), for: id, chartVersion: 1)
        let up = manager.record(result(difficulty: .hard), for: id, chartVersion: 1)
        XCTAssertTrue(up.contains { if case .newBestDifficulty = $0 { return true }; return false })
        // Playing easy again after hard clears nothing new.
        let back = manager.record(result(difficulty: .easy), for: id, chartVersion: 1)
        XCTAssertFalse(back.contains { if case .newBestDifficulty = $0 { return true }; return false })
    }

    // MARK: - Deletion / reimport

    @MainActor
    func testRemoveSongClearsStats() {
        let manager = StatsManager()
        let id = UUID()
        _ = manager.record(result(), for: id, chartVersion: 1)
        manager.removeSong(id)
        XCTAssertNil(manager.stats(for: id))
        XCTAssertEqual(manager.global.totalSongsPlayed, 0)
        // Removing a song without stats is a safe no-op.
        manager.removeSong(UUID())
    }

    @MainActor
    func testReimportedSongStartsFresh() {
        let manager = StatsManager()
        let original = UUID()
        _ = manager.record(result(score: 2000), for: original, chartVersion: 1)
        manager.removeSong(original)

        // A re-import creates a NEW record id → fresh statistics.
        let reimported = UUID()
        let milestones = manager.record(result(score: 500), for: reimported, chartVersion: 1)
        XCTAssertEqual(milestones.count, 4)   // first-run milestones again
        XCTAssertNil(manager.stats(for: original))
        XCTAssertEqual(manager.stats(for: reimported)?.highestScore, 500)
    }

    // MARK: - Globals

    @MainActor
    func testGlobalAggregates() {
        let manager = StatsManager()
        let a = UUID(), b = UUID()
        _ = manager.record(result(song: "A", difficulty: .easy, score: 100, accuracy: 0.8,
                                  combo: 10, perfect: 8, great: 2, miss: 0, played: 60), for: a, chartVersion: 1)
        _ = manager.record(result(song: "B", difficulty: .hard, score: 900, accuracy: 0.5,
                                  combo: 40, perfect: 10, great: 5, good: 5, miss: 20, played: 240), for: b, chartVersion: 1)

        let global = manager.global
        XCTAssertEqual(global.totalSongsPlayed, 2)
        XCTAssertEqual(global.totalAttempts, 2)
        XCTAssertEqual(global.totalNotesHit, 8 + 2 + 10 + 5 + 5)
        XCTAssertEqual(global.totalNotesJudged, 8 + 2 + 10 + 5 + 5 + 20)
        XCTAssertEqual(global.overallAccuracy, 30.0 / 50.0, accuracy: 0.0001)
        XCTAssertEqual(global.highestCombo, 40)
        XCTAssertEqual(global.hardestChartCleared, .hard)
        XCTAssertEqual(global.totalGameplayTime, 300, accuracy: 0.0001)
    }

    @MainActor
    func testGlobalEmpty() {
        let global = StatsManager().global
        XCTAssertEqual(global.totalAttempts, 0)
        XCTAssertEqual(global.totalSongsPlayed, 0)
        XCTAssertNil(global.hardestChartCleared)
        XCTAssertEqual(global.overallAccuracy, 0)
    }

    // MARK: - Persistence

    @MainActor
    func testPersistenceRoundTrip() {
        let manager = StatsManager()
        let id = UUID()
        _ = manager.record(result(song: "Saved", difficulty: .hard, played: 90), for: id, chartVersion: 3)

        let restored = StatsManager(snapshot: StatsStorage.load())
        let song = restored.stats(for: id)
        XCTAssertEqual(song?.title, "Saved")
        XCTAssertEqual(song?.totalAttempts, 1)
        XCTAssertEqual(song?.stats(for: .hard)?.bestChartVersion, 3)
        XCTAssertEqual(restored.global.totalGameplayTime, 90, accuracy: 0.0001)
    }

    @MainActor
    func testCorruptAndNewerDataHandled() {
        // Corrupt file → starts empty, fresh mutations still persist.
        let url = AppDirectories.documentsDirectory.appendingPathComponent("stats.json")
        try? FileManager.default.createDirectory(at: AppDirectories.documentsDirectory,
                                                 withIntermediateDirectories: true)
        try? "garbage{{".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(StatsStorage.load())
        let manager = StatsManager(snapshot: StatsStorage.load())
        _ = manager.record(result(), for: UUID(), chartVersion: 1)
        XCTAssertEqual(StatsManager(snapshot: StatsStorage.load()).global.totalAttempts, 1)

        // Newer schema → rejected entirely.
        let future = StatsSnapshot(schemaVersion: 99, stats: [])
        XCTAssertTrue(StatsManager(snapshot: future).stats.isEmpty)
    }

    @MainActor
    func testRestoreRepairsInvalidCounters() {
        var tier = DifficultyStats(difficulty: .medium)
        tier.attempts = 3
        tier.playTime = -5        // invalid (negative)
        tier.bestAccuracy = 2.0   // invalid (>1)
        let snapshot = StatsSnapshot(schemaVersion: 1, stats: [
            SongStats(songID: UUID(), title: "Bad", perDifficulty: [tier]),
        ])
        let manager = StatsManager(snapshot: snapshot)
        let fixed = manager.stats.values.first?.stats(for: .medium)
        XCTAssertEqual(fixed?.playTime, 0)
        XCTAssertEqual(fixed?.bestAccuracy, 1.0)
        XCTAssertEqual(fixed?.attempts, 3)   // valid data preserved
    }
}