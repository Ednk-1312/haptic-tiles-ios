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

    func testLabelMapping() {
        XCTAssertEqual(DifficultyLevel.level(forScore: 1.0), .easy)
        XCTAssertEqual(DifficultyLevel.level(forScore: 2.5), .casual)
        XCTAssertEqual(DifficultyLevel.level(forScore: 4.0), .medium)
        XCTAssertEqual(DifficultyLevel.level(forScore: 6.0), .hard)
        XCTAssertEqual(DifficultyLevel.level(forScore: 7.0), .expert)
        XCTAssertEqual(DifficultyLevel.level(forScore: 9.0), .extreme)
    }
}