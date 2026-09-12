import XCTest
@testable import Music_Haptics

/// Charts must use all four lanes naturally — never a near-empty lane, never
/// one lane dominating, even for long constant-groove material that previously
/// looped on the right-hand pair.
final class LaneBalanceTests: XCTestCase {

    private func generate(_ analysis: AudioAnalysis, difficulty: DifficultyLevel, seed: UInt64 = 21) async throws -> Chart {
        try await ChartGenerator().generate(
            analysis: analysis, songID: UUID(),
            request: ChartGenerator.Request(difficulty: difficulty, densityMultiplier: 1.0, seed: seed)).chart
    }

    private func assertBalanced(_ chart: Chart, _ analysis: AudioAnalysis,
                                file: StaticString = #filePath, line: UInt = #line) {
        let a = ChartAnalyticsBuilder.analyze(chart: chart, analysis: analysis)
        XCTAssertFalse(a.isSuspiciouslyOneSided,
                       "one-sided chart: counts \(a.laneCounts) shares \(a.laneShares)",
                       file: file, line: line)
        let shares = a.laneShares
        for (i, share) in shares.enumerated() {
            XCTAssertGreaterThan(share, 0.08,
                                 "lane \(i + 1) nearly unused (share \(String(format: "%.1f", share * 100))%)",
                                 file: file, line: line)
        }
        // No single lane dominates a groove chart.
        XCTAssertLessThanOrEqual(shares.max() ?? 0, 0.42,
                                 "lane share too dominant", file: file, line: line)
        // Longest silence per lane stays moderate (charts keep touching all lanes).
        for (i, idle) in a.laneIdleWindows.enumerated() {
            XCTAssertLessThan(idle, chart.duration * 0.7,
                              "lane \(i + 1) unused for \(String(format: "%.1f", idle))s",
                              file: file, line: line)
        }
    }

    func testMetronomeChartsUseAllLanes() async throws {
        for difficulty in [DifficultyLevel.medium, .hard, .extreme] {
            let analysis = SignalFixtures.metronomeAnalysis(bpm: 120, seconds: 30)
            let chart = try await generate(analysis, difficulty: difficulty)
            assertBalanced(chart, analysis)
        }
    }

    func testDrumGrooveNoLongerLoopsOnTheRightPair() async throws {
        // This was the reported failure: a constant eighth-note groove chart
        // cycling on lanes 3–4. It must migrate across the board.
        for difficulty in [DifficultyLevel.medium, .hard, .extreme] {
            let analysis = SignalFixtures.drumHeavy(bpm: 120, seconds: 30)
            let chart = try await generate(analysis, difficulty: difficulty)
            assertBalanced(chart, analysis)

            // Movement should include adjacent walking, not only same-lane taps.
            let a = ChartAnalyticsBuilder.analyze(chart: chart, analysis: analysis)
            XCTAssertGreaterThan(a.jump1Steps, 0, "\(difficulty): chart never walks between lanes")
        }
    }

    func testLaneBalanceIsDeterministic() async throws {
        let analysis = SignalFixtures.drumHeavy()
        let a = try await generate(analysis, difficulty: .medium, seed: 5)
        let b = try await generate(analysis, difficulty: .medium, seed: 5)
        XCTAssertEqual(a.notes, b.notes)
    }

    func testPathologicalOneSidedChartIsDetected() {
        // A hand-built chart that only ever uses lane 4 must be flagged.
        var notes: [ChartNote] = []
        for i in 0..<40 {
            notes.append(ChartNote(id: i, time: 0.5 * Double(i), lane: 3, duration: 0,
                                   type: .tap, strength: 1))
        }
        let chart = Chart(songID: UUID(), difficulty: .medium, chartVersion: 1, seed: 1,
                          notes: notes, generatedAt: Date(), nps: 0, duration: 30,
                          difficultyScore: 5, validationWarnings: [], generationDuration: 0)
        let a = ChartAnalyticsBuilder.analyze(chart: chart, analysis: SignalFixtures.drumHeavy())
        XCTAssertTrue(a.isSuspiciouslyOneSided)
    }
}