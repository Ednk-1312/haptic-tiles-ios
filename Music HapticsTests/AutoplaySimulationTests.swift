import XCTest
@testable import Music_Haptics

/// Deterministic whole-chart playthroughs through the real subsystems
/// (NoteScheduler + InputJudge + ScoreManager): perfect players, early/late
/// bias, seeded timing noise, dropped notes, full-song coverage and the
/// results record the engine would produce.
@MainActor
final class AutoplaySimulationTests: XCTestCase {
    private func handChart(noteCount: Int = 10) -> Chart {
        let notes = (0..<noteCount).map { i in
            ChartNote(id: i, time: Double(i + 1), lane: i % 4, duration: 0,
                      type: .tap, strength: 1)
        }
        return Chart(songID: UUID(), difficulty: .medium, chartVersion: 1, seed: 1,
                     notes: notes, generatedAt: Date(), nps: 1, duration: Double(noteCount + 2),
                     difficultyScore: 5, validationWarnings: [], generationDuration: 0)
    }

    /// Independent recomputation of the multiplier ladder so the harness score
    /// is checked, not just echoed. `ScoreManager` reads the multiplier from
    /// the CURRENT combo (before the hit increments it), so the first 10 hits
    /// score at 1×, hit 11–25 at 2×, 26–50 at 3×, beyond at 4×.
    private func expectedScore(count: Int, points: Int) -> Int {
        var score = 0
        var combo = 0
        for _ in 0..<count {
            let mult = combo <= 9 ? 1 : combo <= 24 ? 2 : combo <= 49 ? 3 : 4
            score += points * mult
            combo += 1
        }
        return score
    }

    // MARK: - Perfect player

    func testPerfectPlayerEveryNotePerfect() {
        let result = AutoplaySimulation.perfectRun(chart: handChart())
        XCTAssertEqual(result.perfectCount, 10)
        XCTAssertEqual(result.greatCount, 0)
        XCTAssertEqual(result.missCount, 0)
        XCTAssertEqual(result.maxCombo, 10)
        XCTAssertEqual(result.judgedCount, 10)
        XCTAssertEqual(result.accuracy, 1.0, accuracy: 1e-9)
    }

    func testPerfectPlayerScoreMatchesIndependentMultiplierMath() {
        let result = AutoplaySimulation.perfectRun(chart: handChart())
        XCTAssertEqual(expectedScore(count: 10, points: 1000), 10_000)
        XCTAssertEqual(result.score, expectedScore(count: 10, points: 1000))
        XCTAssertEqual(result.score, 10_000)
        // And a longer run must climb the ladder: hit 11 is the first 2× note.
        XCTAssertEqual(expectedScore(count: 11, points: 1000), 10_000 + 2_000)
        XCTAssertEqual(expectedScore(count: 25, points: 1000), 10_000 + 15 * 2_000)
    }

    // MARK: - Early / late bias

    func testSlightlyLatePlayerAllGreat() {
        // +100 ms is inside the Great band (70–130 ms) for every note.
        let config = AutoplaySimulation.Config(tapOffset: 0.10)
        let result = AutoplaySimulation.run(chart: handChart(), config: config)
        XCTAssertEqual(result.greatCount, 10)
        XCTAssertEqual(result.perfectCount, 0)
        XCTAssertEqual(result.missCount, 0)
        XCTAssertEqual(result.maxCombo, 10)
        XCTAssertEqual(result.accuracy, 0.75, accuracy: 1e-9)
        XCTAssertEqual(result.score, expectedScore(count: 10, points: 750))
    }

    func testSlightlyEarlyPlayerAllGreat() {
        // Negative bias is symmetric: −100 ms also lands in the Great band.
        let config = AutoplaySimulation.Config(tapOffset: -0.10)
        let result = AutoplaySimulation.run(chart: handChart(), config: config)
        XCTAssertEqual(result.greatCount, 10)
        XCTAssertEqual(result.missCount, 0)
        XCTAssertEqual(result.maxCombo, 10)
    }

    func testSmallEarlyOffsetStaysPerfect() {
        let config = AutoplaySimulation.Config(tapOffset: -0.03)
        let result = AutoplaySimulation.run(chart: handChart(), config: config)
        XCTAssertEqual(result.perfectCount, 10)
        XCTAssertEqual(result.missCount, 0)
    }

    func testHugeOffsetDropsToMisses() {
        // +1 s is far beyond every window: each note must time out as a miss.
        let config = AutoplaySimulation.Config(tapOffset: 1.0)
        let result = AutoplaySimulation.run(chart: handChart(), config: config)
        XCTAssertEqual(result.missCount, 10)
        XCTAssertEqual(result.perfectCount, 0)
        XCTAssertEqual(result.maxCombo, 0)
        XCTAssertEqual(result.score, 0)
    }

    // MARK: - Deterministic noise + drops

    func testNoisyPlayerIsDeterministicAndJudgesAllNotes() {
        let config = AutoplaySimulation.Config(jitterMs: 120, jitterSeed: 42)
        let a = AutoplaySimulation.run(chart: handChart(), config: config)
        let b = AutoplaySimulation.run(chart: handChart(), config: config)
        XCTAssertEqual(a.perfectCount, b.perfectCount)
        XCTAssertEqual(a.greatCount, b.greatCount)
        XCTAssertEqual(a.score, b.score)
        XCTAssertEqual(a.judgedCount, 10)
        XCTAssertEqual(a.missCount, 0)
        // With ±120 ms spread, at least one hit should fall outside Perfect.
        XCTAssertGreaterThan(a.greatCount, 0)
        XCTAssertLessThan(a.accuracy, 1.0)
        XCTAssertGreaterThan(a.accuracy, 0)
    }

    func testDroppedNotesBecomeMissesAndBreakCombo() {
        let config = AutoplaySimulation.Config(jitterSeed: 7, dropRate: 0.3)
        let result = AutoplaySimulation.run(chart: handChart(), config: config)
        XCTAssertEqual(result.judgedCount, 10)
        XCTAssertGreaterThan(result.missCount, 0)
        XCTAssertLessThan(result.maxCombo, 10)
        XCTAssertLessThan(result.accuracy, 1.0)
        XCTAssertGreaterThan(result.score, 0)
    }

    // MARK: - Complete generated song

    func testPerfectRunThroughFullGeneratedSong() async throws {
        let analysis = SignalFixtures.drumHeavy(bpm: 120, seconds: 24)
        let output = try await ChartGenerator().generate(analysis: analysis, songID: UUID(),
                                                         request: .init(difficulty: .hard,
                                                                        densityMultiplier: 1.0,
                                                                        seed: 5))
        let result = AutoplaySimulation.perfectRun(chart: output.chart)
        XCTAssertGreaterThan(output.chart.notes.count, 10)
        XCTAssertEqual(result.perfectCount, output.chart.notes.count)
        XCTAssertEqual(result.missCount, 0)
        XCTAssertEqual(result.maxCombo, output.chart.notes.count)
        XCTAssertEqual(result.accuracy, 1.0, accuracy: 1e-9)
    }

    // MARK: - Results record

    func testResultsCarryMetadataAndConsistentCounts() {
        let chart = handChart()
        let config = AutoplaySimulation.Config(songTitle: "Sim Song",
                                               tapOffset: 0.05, jitterMs: 60, jitterSeed: 9)
        let result = AutoplaySimulation.run(chart: chart, config: config)
        XCTAssertEqual(result.songTitle, "Sim Song")
        XCTAssertEqual(result.difficulty, chart.difficulty)
        XCTAssertEqual(result.judgedCount, 10)
        let fromCounts = result.perfectCount + result.greatCount + result.goodCount + result.missCount
        XCTAssertEqual(fromCounts, 10)
        XCTAssertTrue(result.accuracy >= 0 && result.accuracy <= 1)
        XCTAssertLessThan(abs(result.date.timeIntervalSinceNow), 60)
    }

    func testCalibrationOffsetIsAppliedBySimulation() {
        // A +50 ms tap bias exactly cancelled by −50 ms calibration → perfect.
        var windows = InputJudge.Config.standard
        windows.calibrationOffset = -0.05
        let config = AutoplaySimulation.Config(tapOffset: 0.05, windows: windows)
        let result = AutoplaySimulation.run(chart: handChart(), config: config)
        XCTAssertEqual(result.perfectCount, 10)
        XCTAssertEqual(result.missCount, 0)
    }
}