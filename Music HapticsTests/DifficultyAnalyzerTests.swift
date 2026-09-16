import XCTest
@testable import Music_Haptics

final class DifficultyAnalyzerTests: XCTestCase {
    private func makeNotes(count: Int, span: Double, alternating: Bool) -> [ChartNote] {
        var notes: [ChartNote] = []
        for i in 0..<count {
            let time = span * Double(i) / Double(max(1, count - 1))
            let lane = alternating ? i % 2 : 0
            notes.append(ChartNote(id: i, time: time, lane: lane, duration: 0, type: .tap, strength: 1))
        }
        return notes
    }

    private func note(_ id: Int, _ time: Double, _ lane: Int,
                      duration: Double = 0, type: ChartNoteType = .tap) -> ChartNote {
        ChartNote(id: id, time: time, lane: lane, duration: duration,
                  type: type, strength: 1)
    }

    func testDenseChartScoresHigherThanSparse() {
        let dense = ChartDifficultyAnalyzer.analyze(notes: makeNotes(count: 400, span: 60, alternating: true), duration: 60)
        let sparse = ChartDifficultyAnalyzer.analyze(notes: makeNotes(count: 60, span: 60, alternating: true), duration: 60)
        XCTAssertGreaterThan(dense.score10, sparse.score10)
        XCTAssertGreaterThan(dense.notesPerSecond, sparse.notesPerSecond)
    }

    func testScoreIsBounded() {
        let metrics = ChartDifficultyAnalyzer.analyze(notes: makeNotes(count: 100, span: 30, alternating: true), duration: 30)
        XCTAssertGreaterThanOrEqual(metrics.score10, 0)
        XCTAssertLessThanOrEqual(metrics.score10, 10)
    }

    func testChordVoicesDoNotDoubleReactionDensity() {
        let solo = (0..<16).map { note($0, Double($0) * 0.5, $0 % 4) }
        let chords = (0..<16).flatMap { index -> [ChartNote] in
            let time = Double(index) * 0.5
            return [note(index * 2, time, 0), note(index * 2 + 1, time, 2)]
        }
        let soloMetrics = ChartDifficultyAnalyzer.analyze(notes: solo, duration: 8)
        let chordMetrics = ChartDifficultyAnalyzer.analyze(notes: chords, duration: 8)

        XCTAssertEqual(chordMetrics.maxBurstNPS, soloMetrics.maxBurstNPS,
                       "a chord adds voices, not independent reaction events")
        XCTAssertLessThan(chordMetrics.score10 - soloMetrics.score10, 2.0,
                          "chords should add a bounded coordination cost, not double the rating")
        XCTAssertGreaterThan(chordMetrics.simultaneityRatio, soloMetrics.simultaneityRatio)
    }

    func testLongSilenceDoesNotHideActiveReactionLoad() {
        let active = (0..<20).map { note($0, 5 + Double($0) * 0.25, $0 % 4) }
        let withLongTail = active + [note(20, 120, 0)]
        let activeMetrics = ChartDifficultyAnalyzer.analyze(notes: active, duration: 121)
        let tailMetrics = ChartDifficultyAnalyzer.analyze(notes: withLongTail, duration: 121)

        XCTAssertGreaterThan(activeMetrics.score10, 0)
        XCTAssertGreaterThan(tailMetrics.score10, 0)
        XCTAssertLessThan(abs(activeMetrics.score10 - tailMetrics.score10), 1.5,
                          "a distant tail note must not make the active section look effortless")
    }

    func testMovementAndHoldsContributeWithoutChangingTiming() {
        let sameLane = (0..<12).map { note($0, Double($0) * 0.5, 1) }
        let wideMovement = (0..<12).map { note($0, Double($0) * 0.5, $0 % 4) }
        let holds = (0..<12).map { note($0, Double($0) * 0.5, $0 % 4,
                                             duration: 0.35, type: .hold) }

        let sameMetrics = ChartDifficultyAnalyzer.analyze(notes: sameLane, duration: 6)
        let movementMetrics = ChartDifficultyAnalyzer.analyze(notes: wideMovement, duration: 6)
        let holdMetrics = ChartDifficultyAnalyzer.analyze(notes: holds, duration: 6)

        XCTAssertGreaterThan(movementMetrics.averageJumpDistance, sameMetrics.averageJumpDistance)
        XCTAssertGreaterThan(movementMetrics.score10, sameMetrics.score10)
        XCTAssertGreaterThan(holdMetrics.score10, sameMetrics.score10)
    }

    func testBoundaryInputsAreFiniteAndSafe() {
        let empty = ChartDifficultyAnalyzer.analyze(notes: [], duration: 0)
        XCTAssertEqual(empty.score10, 0)
        XCTAssertEqual(empty.label, .easy)

        let sparse = ChartDifficultyAnalyzer.analyze(
            notes: [note(0, 4, 0)], duration: 120)
        XCTAssertGreaterThanOrEqual(sparse.score10, 0)
        XCTAssertTrue(sparse.score10.isFinite)

        let invalid = [
            note(0, .nan, 0),
            note(1, 1, 0, duration: .infinity),
            note(2, 2, 1),
            ChartNote(id: 3, time: 3, lane: 2, duration: 0, type: .tap, strength: .nan)
        ]
        let sanitized = ChartDifficultyAnalyzer.analyze(notes: invalid, duration: .nan)
        XCTAssertEqual(sanitized.notesPerSecond, 1, accuracy: 0.0001,
                       "only the finite note should contribute")
        XCTAssertTrue(sanitized.score10.isFinite)
        XCTAssertTrue(sanitized.averageInterval.isFinite)
        XCTAssertTrue(sanitized.intervalStdDev.isFinite)
    }

    func testDenseChordsAndExtremeMovementStayBounded() {
        var notes: [ChartNote] = []
        for index in 0..<80 {
            let time = Double(index) * 0.12
            let firstLane = index.isMultiple(of: 2) ? 0 : 3
            let secondLane = index.isMultiple(of: 2) ? 1 : 2
            notes.append(note(index * 2, time, firstLane))
            notes.append(note(index * 2 + 1, time, secondLane,
                              duration: index.isMultiple(of: 5) ? 0.5 : 0,
                              type: index.isMultiple(of: 5) ? .hold : .tap))
        }
        let metrics = ChartDifficultyAnalyzer.analyze(notes: notes, duration: 10)
        XCTAssertGreaterThan(metrics.simultaneityRatio, 0.9)
        XCTAssertGreaterThanOrEqual(metrics.averageJumpDistance, 2)
        XCTAssertGreaterThan(metrics.score10, 0)
        XCTAssertLessThanOrEqual(metrics.score10, 10)
        XCTAssertTrue(metrics.sustainedNPS.isFinite)
    }

    func testLabelMapping() {
        XCTAssertEqual(DifficultyLevel.level(forScore: 1.0), .easy)
        XCTAssertEqual(DifficultyLevel.level(forScore: 2.5), .casual)
        XCTAssertEqual(DifficultyLevel.level(forScore: 4.0), .medium)
        XCTAssertEqual(DifficultyLevel.level(forScore: 6.0), .hard)
        XCTAssertEqual(DifficultyLevel.level(forScore: 7.0), .expert)
        XCTAssertEqual(DifficultyLevel.level(forScore: 9.0), .extreme)
    }
}
