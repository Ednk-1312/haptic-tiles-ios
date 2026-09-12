import XCTest
@testable import Music_Haptics

/// Hold-note coverage: generation gates + determinism, validator overlap
/// rules, scoring bonus/miss, and full-chart simulation of sustained and
/// early-released holds through the real engine subsystems.
@MainActor
final class HoldNoteTests: XCTestCase {

    // MARK: - Generator

    func testGeneratedChartProducesHoldsDeterministically() async throws {
        let analysis = SignalFixtures.drumHeavy(bpm: 120, seconds: 24)
        let request = ChartGenerator.Request(difficulty: .hard, densityMultiplier: 1.0, seed: 11)
        let a = try await ChartGenerator().generate(analysis: analysis, songID: UUID(), request: request)
        let b = try await ChartGenerator().generate(analysis: analysis, songID: UUID(), request: request)

        XCTAssertEqual(a.chart.notes, b.chart.notes, "identical inputs must produce byte-identical charts (incl. holds)")
        let holds = a.chart.notes.filter { $0.type == .hold }
        XCTAssertGreaterThan(holds.count, 0, "an energetic 120 BPM groove should yield some holds")
        XCTAssertLessThan(holds.count, a.chart.notes.count / 2, "holds must stay a seasoning, not the majority")
        for hold in holds {
            XCTAssertGreaterThan(hold.duration, 0.3)
            XCTAssertLessThanOrEqual(hold.duration, 2.4)
        }
    }

    func testHoldOccupancyRespectedInGeneratedChart() async throws {
        let analysis = SignalFixtures.drumHeavy(bpm: 120, seconds: 24)
        let output = try await ChartGenerator().generate(analysis: analysis, songID: UUID(),
                                                         request: .init(difficulty: .hard, densityMultiplier: 1.0, seed: 3))
        let notes = output.chart.notes
        var lastEndPerLane = [Double](repeating: -Double.infinity, count: 4)
        for note in notes {
            let lane = note.lane
            if note.time < lastEndPerLane[lane] - 0.001 {
                XCTFail("note at \(note.time)s overlaps an earlier hold body in lane \(lane)")
            }
            let end = note.type == .hold ? note.time + note.duration : note.time
            if note.type == .hold, note.time < lastEndPerLane[lane] + 0.14 {
                XCTFail("hold head at \(note.time)s starts too soon after previous lane activity")
            }
            lastEndPerLane[lane] = max(lastEndPerLane[lane], end)
        }
    }

    func testHoldsOnlyOnAccentNotes() async throws {
        // Sparse vocal fixture: strong downbeats, weak off-grid whispers. Holds
        // may only land on the strong accents.
        let analysis = SignalFixtures.sparseVocal(bpm: 90, seconds: 32)
        let output = try await ChartGenerator().generate(analysis: analysis, songID: UUID(),
                                                         request: .init(difficulty: .medium, densityMultiplier: 1.0, seed: 8))
        let holds = output.chart.notes.filter { $0.type == .hold }
        for hold in holds {
            XCTAssertGreaterThanOrEqual(hold.strength, 0.6, "hold on a weak note at \(hold.time)s")
        }
    }

    // MARK: - Validator

    func testValidatorRejectsNoteInsideHoldBody() {
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        let notes = [
            ChartNote(id: 0, time: 1.0, lane: 0, duration: 0.8, type: .hold, strength: 1),
            ChartNote(id: 1, time: 1.5, lane: 0, duration: 0, type: .tap, strength: 1),
            ChartNote(id: 2, time: 2.5, lane: 1, duration: 0, type: .tap, strength: 1)
        ]
        let result = ChartValidator.validate(notes, constraints: constraints)
        XCTAssertTrue(result.hardFailures.contains { $0.contains("overlaps a hold") })
    }

    func testValidatorUsesHoldTailForSameLaneGap() {
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        // Head gap is 0.9 s (fine) but tail-to-next is only 0.1 s (< 0.13).
        let notes = [
            ChartNote(id: 0, time: 1.0, lane: 0, duration: 0.8, type: .hold, strength: 1),
            ChartNote(id: 1, time: 1.9, lane: 0, duration: 0, type: .tap, strength: 1)
        ]
        let result = ChartValidator.validate(notes, constraints: constraints)
        XCTAssertTrue(result.hardFailures.contains { $0.contains("Same-lane repeat") },
                      "failures: \(result.hardFailures)")
    }

    func testValidatorAcceptsHoldWithClearTail() {
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        let notes = [
            ChartNote(id: 0, time: 1.0, lane: 0, duration: 0.8, type: .hold, strength: 1),
            ChartNote(id: 1, time: 1.95, lane: 0, duration: 0, type: .tap, strength: 1),
            ChartNote(id: 2, time: 2.4, lane: 2, duration: 0, type: .tap, strength: 1)
        ]
        let result = ChartValidator.validate(notes, constraints: constraints)
        XCTAssertEqual(result.hardFailureCount, 0, "failures: \(result.hardFailures)")
    }

    func testRepairDropsNoteOverlappingHoldBody() {
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        let notes = [
            ChartNote(id: 0, time: 1.0, lane: 0, duration: 0.8, type: .hold, strength: 1),
            ChartNote(id: 1, time: 1.5, lane: 0, duration: 0, type: .tap, strength: 1),
            ChartNote(id: 2, time: 2.5, lane: 1, duration: 0, type: .tap, strength: 1),
            ChartNote(id: 3, time: 3.0, lane: 2, duration: 0, type: .tap, strength: 1)
        ]
        let repaired = ChartValidator.repair(notes, constraints: constraints)
        XCTAssertEqual(repaired.count, 3)
        XCTAssertFalse(repaired.contains { $0.id == 1 }, "the note inside the hold body must be dropped")
        let revalidated = ChartValidator.validate(repaired, constraints: constraints)
        XCTAssertEqual(revalidated.hardFailureCount, 0)
    }

    // MARK: - Scoring

    func testHoldBonusScalesWithMultiplier() {
        var score = ScoreManager()
        // 10 hits → combo 10 → 2×; 25 hits → combo 25 → 3×. The bonus must
        // track the multiplier in force at completion time.
        for _ in 0..<10 { score.apply(.perfect) }
        let mult1 = score.multiplier
        let before = score.score
        score.completeHold()
        XCTAssertEqual(score.score - before, 500 * mult1, "hold bonus = 500 × multiplier")
        XCTAssertEqual(score.holdsCompleted, 1)
        XCTAssertEqual(mult1, 2, "10 hits should reach the 2× band")
        for _ in 0..<15 { score.apply(.perfect) }
        let mult2 = score.multiplier
        let before2 = score.score
        score.completeHold()
        XCTAssertEqual(score.score - before2, 500 * mult2)
        XCTAssertEqual(mult2, 3, "25 hits should reach the 3× band")
    }

    func testEarlyHoldReleaseBreaksComboWithoutAddingMissCount() {
        var score = ScoreManager()
        for _ in 0..<5 { score.apply(.perfect) }
        score.missHold()
        XCTAssertEqual(score.holdsMissed, 1)
        XCTAssertEqual(score.comboCount, 0, "early release breaks the combo")
        XCTAssertEqual(score.counts[.miss], nil, "the head was hit; only the sustain failed")
        score.apply(.perfect)
        XCTAssertEqual(score.comboCount, 1)
    }

    // MARK: - Full-chart simulation

    private func holdChart() -> Chart {
        let notes = [
            ChartNote(id: 0, time: 1.0, lane: 0, duration: 0, type: .tap, strength: 1),
            ChartNote(id: 1, time: 1.5, lane: 1, duration: 1.0, type: .hold, strength: 1),
            ChartNote(id: 2, time: 2.5, lane: 2, duration: 0, type: .tap, strength: 1),
            ChartNote(id: 3, time: 3.0, lane: 3, duration: 0, type: .tap, strength: 1),
            ChartNote(id: 4, time: 3.5, lane: 0, duration: 0, type: .tap, strength: 1)
        ]
        return Chart(songID: UUID(), difficulty: .medium, chartVersion: 3, seed: 1,
                     notes: notes, generatedAt: Date(), nps: 2, duration: 5,
                     difficultyScore: 4, validationWarnings: [], generationDuration: 0)
    }

    func testPerfectPlayerSustainsHoldsToCompletion() {
        let result = AutoplaySimulation.perfectRun(chart: holdChart())
        XCTAssertEqual(result.perfectCount, 5)
        XCTAssertEqual(result.missCount, 0)
        XCTAssertEqual(result.holdsCompleted, 1)
        XCTAssertEqual(result.holdsMissed, 0)
        XCTAssertEqual(result.maxCombo, 5, "hold completion does not break the combo")
    }

    func testEarlyHoldReleaseIsHoldMissAndBreaksCombo() {
        let config = AutoplaySimulation.Config(holdReleaseOffset: -0.5)
        let result = AutoplaySimulation.run(chart: holdChart(), config: config)
        XCTAssertEqual(result.perfectCount, 5, "all heads still hit perfectly")
        XCTAssertEqual(result.missCount, 0, "early release is a hold miss, not a head miss")
        XCTAssertEqual(result.holdsCompleted, 0)
        XCTAssertEqual(result.holdsMissed, 1)
        XCTAssertEqual(result.maxCombo, 3, "combo: 1,2 → break → 1,2,3")
    }

    func testDroppedHoldHeadCountsAsMiss() {
        // Drop every note: the hold head is never hit → normal miss path.
        let config = AutoplaySimulation.Config(dropRate: 1.0)
        let result = AutoplaySimulation.run(chart: holdChart(), config: config)
        XCTAssertEqual(result.missCount, 5)
        XCTAssertEqual(result.holdsCompleted, 0)
        XCTAssertEqual(result.holdsMissed, 0)
        XCTAssertEqual(result.score, 0)
    }

    func testHoldBonusAppearsInPerfectRunScore() {
        // With one completed hold at 1×: 5 perfect taps (5,000) + 500 bonus.
        let result = AutoplaySimulation.perfectRun(chart: holdChart())
        XCTAssertEqual(result.score, 5_000 + 500)
    }
}