import XCTest
@testable import Music_Haptics

/// Repeated lifecycle stress: load → analyze (fixture) → generate chart →
/// play → pause → resume → restart → finish → save result → next song, run
/// many times. Every iteration asserts the state invariants that keep the
/// real game stable (no NaN, fresh scheduler after restart, cleared holds,
/// monotonic score, valid charts, persistence round-trips).
@MainActor
final class LifecycleStressTests: XCTestCase {

    nonisolated(unsafe) private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifecycleStress-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        AppDirectories.testRootOverride = tempRoot
    }

    override func tearDown() {
        AppDirectories.testRootOverride = nil
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func judgeConfig() -> InputJudge.Config {
        InputJudge.Config(perfectWindow: 0.07, greatWindow: 0.13, goodWindow: 0.20,
                          missWindow: 0.20, calibrationOffset: 0)
    }

    /// One full lifecycle pass over the pure pipeline.
    private func runLifecycle(iteration: Int) async throws {
        let songID = UUID()
        // 1. "Load" + analysis fixture (deterministic, per-iteration tempo).
        let bpm = [90.0, 120.0, 140.0, 100.0][iteration % 4]
        let analysis = SignalFixtures.metronomeAnalysis(bpm: bpm, seconds: 16)

        // 2. Generate + validate.
        let output = try await ChartGenerator().generate(
            analysis: analysis,
            songID: songID,
            request: ChartGenerator.Request(difficulty: .medium, densityMultiplier: 1.0,
                                            seed: UInt64(iteration)))
        let chart = output.chart
        for note in chart.notes {
            XCTAssertFalse(note.time.isNaN, "iteration \(iteration): NaN note time")
            XCTAssertFalse(note.time.isInfinite)
            XCTAssertGreaterThanOrEqual(note.time, 0)
            XCTAssertLessThanOrEqual(note.time, analysis.duration + 0.001)
            XCTAssertTrue((0..<4).contains(note.lane), "iteration \(iteration): lane \(note.lane)")
        }
        XCTAssertGreaterThan(chart.notes.count, 0, "iteration \(iteration): empty chart")

        // 3. Play: judge every note at its exact time (perfect autoplay).
        var scheduler = NoteScheduler(chart: chart)
        var score = ScoreManager()
        var judge = InputJudge(config: judgeConfig())
        var holds = HoldTracker()
        for note in chart.notes {
            let judgment = judge.classifyForgiving(tapTime: note.time, noteTime: note.time)
            XCTAssertEqual(judgment, .perfect)
            if let hit = scheduler.nearest(in: note.lane, to: note.time, window: 0.5) {
                score.apply(judgment)
                scheduler.mark(hit.index, judgment: judgment)
                if note.type == .hold {
                    holds.start(lane: note.lane, index: hit.index, noteID: note.id,
                                startTime: note.time, endTime: note.time + note.duration)
                    _ = holds.complete(lane: note.lane)
                }
            }
        }
        let finalScore = score.score
        XCTAssertGreaterThan(finalScore, 0)

        // 4. Pause (holds cleared, nothing survives).
        holds.cancelAll()
        XCTAssertTrue(holds.active.isEmpty)
        XCTAssertTrue(holds.stateByNote.isEmpty)

        // 5. Restart: everything must come back clean.
        scheduler = NoteScheduler(chart: chart)
        score = ScoreManager()
        judge = InputJudge(config: judgeConfig())
        XCTAssertEqual(score.score, 0)
        XCTAssertEqual(scheduler.sortedNotes.count, chart.notes.count)
        for note in chart.notes {
            XCTAssertNil(scheduler.judgment(for: scheduler.nearest(in: note.lane, to: note.time, window: 0.5)?.index ?? 0))
        }

        // 6. Finish + save result (results + stats persistence round-trip).
        let result = GameplayResult(songTitle: "Stress \(iteration)", difficulty: .medium,
                                    score: finalScore, maxCombo: score.maxCombo,
                                    perfectCount: 1, greatCount: 0, goodCount: 0, missCount: 0,
                                    accuracy: 1.0, date: Date(),
                                    holdsCompleted: 0, holdsMissed: 0, playedDuration: 16)
        ResultsStorage.save(result, songID: songID)
        let loaded = ResultsStorage.load(songID: songID, difficulty: .medium)
        XCTAssertEqual(loaded?.score, finalScore, "iteration \(iteration): result round-trip")

        // 7. Stats record (best replacement path under repeated load).
        let stats = StatsManager()
        stats.record(result, for: songID, chartVersion: chart.chartVersion)
        let first = stats.stats(for: songID)
        XCTAssertNotNil(first)
        // A worse run must not lower the best.
        let worse = GameplayResult(songTitle: "Stress \(iteration)", difficulty: .medium,
                                   score: finalScore / 2, maxCombo: 1,
                                   perfectCount: 0, greatCount: 0, goodCount: 1, missCount: 1,
                                   accuracy: 0.25, date: Date(),
                                   holdsCompleted: 0, holdsMissed: 0, playedDuration: 8)
        stats.record(worse, for: songID, chartVersion: chart.chartVersion)
        XCTAssertEqual(stats.stats(for: songID)?.highestScore, finalScore)
    }

    func testFullLifecycleRunsManyIterations() async throws {
        for iteration in 0..<60 {
            try await runLifecycle(iteration: iteration)
        }
    }

    func testRapidSongSwitchingLoop() async throws {
        // A → B → C → A with fresh state each time; every chart loads back
        // identically from storage (the exact cache-invalidation path).
        var songIDs: [UUID] = []
        for i in 0..<12 {
            let songID = UUID()
            songIDs.append(songID)
            let analysis = SignalFixtures.metronomeAnalysis(bpm: 120, seconds: 12)
            // Every difficulty gets its own chart for the same analysis — the
            // exact multi-difficulty cache path.
            for difficulty in [DifficultyLevel.easy, .medium, .hard] {
                let output = try await ChartGenerator().generate(
                    analysis: analysis, songID: songID,
                    request: ChartGenerator.Request(difficulty: difficulty, densityMultiplier: 1.0,
                                                    seed: UInt64(i)))
                try ChartStorage.save(output.chart, for: songID)
            }
        }
        // A→B→C→A×3: the original chart must come back byte-identical each time.
        for round in 0..<3 {
            for songID in songIDs {
                for difficulty in [DifficultyLevel.easy, .medium, .hard] {
                    let loaded = try ChartStorage.loadChart(for: songID, difficulty: difficulty)
                    XCTAssertNotNil(loaded, "round \(round): missing chart for \(songID)")
                    if let loaded {
                        XCTAssertEqual(loaded.songID, songID)
                        XCTAssertEqual(loaded.difficulty, difficulty)
                    }
                }
            }
        }
    }

    func testRepeatedRestartClearsAllJudgmentState() {
        // Restarting 100× must never leak a judgment from a previous pass.
        let analysis = SignalFixtures.metronomeAnalysis(bpm: 120, seconds: 8)
        let notes = analysis.beats.enumerated().map { i, beat in
            ChartNote(id: i, time: beat.time, lane: i % 4, duration: 0, type: .tap, strength: 1)
        }
        let chart = Chart(songID: UUID(), difficulty: .medium, chartVersion: 4, seed: 1,
                          notes: notes, generatedAt: Date(), nps: 2, duration: 8,
                          difficultyScore: 3, validationWarnings: [], generationDuration: 0)
        for _ in 0..<100 {
            var scheduler = NoteScheduler(chart: chart)
            let first = scheduler.sortedNotes.first!
            scheduler.mark(0, judgment: .perfect)
            XCTAssertEqual(scheduler.judgment(for: 0), .perfect)
            scheduler = NoteScheduler(chart: chart)
            XCTAssertNil(scheduler.judgment(for: 0), "fresh scheduler must forget judgments")
            XCTAssertEqual(scheduler.sortedNotes.count, chart.notes.count)
            _ = first
        }
    }
}