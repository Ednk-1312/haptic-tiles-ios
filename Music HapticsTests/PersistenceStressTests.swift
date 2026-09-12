import XCTest
@testable import Music_Haptics

/// Persistence stress: many save/load cycles, corrupt files injected at every
/// layer, missing charts, deleted artifacts, and version mismatches — the app
/// must never crash and must always recover to a usable state.
@MainActor
final class PersistenceStressTests: XCTestCase {

    nonisolated(unsafe) private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceStress-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        AppDirectories.testRootOverride = tempRoot
        ReplayStorage.customDirectory = tempRoot.appendingPathComponent("Replays")
    }

    override func tearDown() {
        AppDirectories.testRootOverride = nil
        ReplayStorage.customDirectory = nil
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func makeChart(songID: UUID, difficulty: DifficultyLevel = .medium) -> Chart {
        Chart(songID: songID, difficulty: difficulty, chartVersion: ChartStorage.chartVersion,
              seed: 1, notes: [ChartNote(id: 0, time: 1, lane: 0, duration: 0, type: .tap, strength: 1)],
              generatedAt: Date(), nps: 1, duration: 10, difficultyScore: 3,
              validationWarnings: [], generationDuration: 0)
    }

    // MARK: - Chart storage

    func testManySaveLoadCyclesRoundTrip() throws {
        let songID = UUID()
        for i in 0..<150 {
            var chart = makeChart(songID: songID)
            chart.seed = UInt64(i)
            try ChartStorage.save(chart, for: songID)
            let loaded = try ChartStorage.loadChart(for: songID, difficulty: .medium)
            XCTAssertEqual(loaded?.seed, UInt64(i))
            XCTAssertEqual(loaded?.difficulty, .medium)
        }
    }

    func testCorruptChartFilesNeverCrash() throws {
        let songID = UUID()
        // Fresh corrupt file at every difficulty + legacy path.
        for difficulty in ChartStorage.generatedDifficulties {
            let url = ChartStorage.chartURLForTesting(songID: songID, difficulty: difficulty)!
            try Data("{{{ not a chart".utf8).write(to: url)
        }
        for difficulty in ChartStorage.generatedDifficulties {
            // Decode throws (callers catch) — never returns garbage.
            do {
                let loaded = try ChartStorage.loadChart(for: songID, difficulty: difficulty)
                XCTAssertNil(loaded, "corrupt file must not decode")
            } catch {
                // Expected: decode failure.
            }
        }
        // Saving over the corruption recovers cleanly.
        try ChartStorage.save(makeChart(songID: songID), for: songID)
        XCTAssertNotNil(try ChartStorage.loadChart(for: songID, difficulty: .medium))
    }

    func testMissingChartReturnsNil() throws {
        let songID = UUID()
        for difficulty in ChartStorage.generatedDifficulties {
            XCTAssertNil(try ChartStorage.loadChart(for: songID, difficulty: difficulty))
        }
        XCTAssertTrue(try ChartStorage.loadCharts(for: songID).isEmpty)
    }

    func testDeletedSongArtifactsRecover() throws {
        let songID = UUID()
        try ChartStorage.save(makeChart(songID: songID), for: songID)
        let analysis = SignalFixtures.metronomeAnalysis(bpm: 120, seconds: 10)
        try ChartStorage.saveAnalysis(analysis, for: songID)
        ChartStorage.deleteAllCharts(for: songID)
        ChartStorage.deleteAnalysis(for: songID)
        XCTAssertNil(try ChartStorage.loadChart(for: songID, difficulty: .medium))
        XCTAssertNil(try ChartStorage.loadAnalysis(for: songID))
        // Regenerating after deletion works (the exact re-import path).
        try ChartStorage.save(makeChart(songID: songID), for: songID)
        XCTAssertNotNil(try ChartStorage.loadChart(for: songID, difficulty: .medium))
    }

    func testVersionMismatchIsDetectableNotSilentlyTrusted() throws {
        let songID = UUID()
        var oldChart = makeChart(songID: songID)
        oldChart.chartVersion = ChartStorage.chartVersion - 1   // stale chart
        try ChartStorage.save(oldChart, for: songID)
        let loaded = try ChartStorage.loadChart(for: songID, difficulty: .medium)!
        XCTAssertNotEqual(loaded.chartVersion, ChartStorage.chartVersion,
                          "stale chart must be identifiable so callers regenerate")
        // And a current chart matches the expected version.
        try ChartStorage.save(makeChart(songID: songID), for: songID)
        XCTAssertEqual(try ChartStorage.loadChart(for: songID, difficulty: .medium)?.chartVersion,
                       ChartStorage.chartVersion)
    }

    // MARK: - Result storage

    func testResultStorageStressRoundTrip() {
        let songID = UUID()
        for i in 0..<100 {
            let result = GameplayResult(songTitle: "s", difficulty: .hard,
                                        score: i * 100, maxCombo: i, perfectCount: i, greatCount: 0,
                                        goodCount: 0, missCount: 0, accuracy: 1.0, date: Date(),
                                        holdsCompleted: 0, holdsMissed: 0, playedDuration: 10)
            ResultsStorage.save(result, songID: songID)
            XCTAssertEqual(ResultsStorage.load(songID: songID, difficulty: .hard)?.score, i * 100)
        }
        // Corrupt the results file — load must fail gracefully (nil), no crash.
        let resultsDir = tempRoot.appendingPathComponent("Documents").appendingPathComponent("Results")
        try? FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        let corruptURL = resultsDir.appendingPathComponent("\(songID.uuidString).hard.result.json")
        try? Data("corrupt".utf8).write(to: corruptURL)
        let loaded = ResultsStorage.load(songID: songID, difficulty: .hard)
        XCTAssertNil(loaded, "corrupt result file must not decode into garbage")
    }

    // MARK: - Replay storage stress

    func testReplayStorageChurn() {
        let songID = UUID()
        for i in 0..<50 {
            let replay = ReplayBuilder.make(songID: songID, songTitle: "s", difficulty: .medium,
                                            chartVersion: 4, audioURL: nil, duration: 10,
                                            noteCount: 10,
                                            events: [ReplayEvent(kind: .note, noteID: i, lane: 0,
                                                                 time: Double(i), judgment: .perfect,
                                                                 timingErrorMs: 0, score: i * 100, combo: i + 1)],
                                            createdAt: Date(), id: UUID())
            XCTAssertTrue(ReplayStorage.save(replay))
            XCTAssertEqual(ReplayStorage.load(id: replay.id)?.events.count, 1)
        }
        XCTAssertEqual(ReplayStorage.savedReplays(songID: songID).count, 50)
        // Delete half, purge invalid, end clean.
        for (i, replay) in ReplayStorage.savedReplays(songID: songID).enumerated() where i % 2 == 0 {
            ReplayStorage.delete(id: replay.id)
        }
        XCTAssertEqual(ReplayStorage.savedReplays(songID: songID).count, 25)
        XCTAssertEqual(ReplayStorage.purgeInvalid(), 0)
    }

    // MARK: - Corrupt store files across every JSON store

    func testCorruptStoreFilesRecoverToEmpty() {
        // queue.json, stats.json, playlists.json all corrupt on disk → each
        // manager must restore to a safe empty state, not crash.
        let documents = tempRoot.appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try? Data("!!!!".utf8).write(to: documents.appendingPathComponent("queue.json"))
        try? Data("!!!!".utf8).write(to: documents.appendingPathComponent("stats.json"))
        try? Data("!!!!".utf8).write(to: documents.appendingPathComponent("playlists.json"))

        // The static loaders must refuse corrupt data (nil), and the managers
        // must start empty — the exact app-launch recovery path.
        XCTAssertNil(QueueStorage.load())
        XCTAssertNil(StatsStorage.load())
        XCTAssertNil(PlaylistStorage.load())
        let queue = QueueManager()
        XCTAssertTrue(queue.entries.isEmpty)
        let stats = StatsManager()
        XCTAssertTrue(stats.stats(for: UUID()) == nil)
        let playlists = PlaylistManager()
        XCTAssertTrue(playlists.playlists.isEmpty)
    }
}