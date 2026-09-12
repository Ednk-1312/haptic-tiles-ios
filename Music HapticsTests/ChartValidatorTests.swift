import XCTest
@testable import Music_Haptics

final class ChartValidatorTests: XCTestCase {
    private func note(_ id: Int, time: Double, lane: Int) -> ChartNote {
        ChartNote(id: id, time: time, lane: lane, duration: 0, type: .tap, strength: 1)
    }

    func testRejectsTooDenseChartAndRepairsIt() {
        var notes: [ChartNote] = []
        for i in 0..<10 {
            notes.append(note(i, time: 0.02 * Double(i), lane: i % 4))
        }
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        let result = ChartValidator.validate(notes, constraints: constraints)
        XCTAssertGreaterThan(result.hardFailureCount, 0)

        let repaired = ChartValidator.repair(notes, constraints: constraints)
        XCTAssertLessThan(repaired.count, notes.count)
        let revalidated = ChartValidator.validate(repaired, constraints: constraints)
        XCTAssertEqual(revalidated.hardFailureCount, 0)
    }

    func testRejectsFastExtremeLaneJump() {
        // 0→3 jumps at 0.2s gaps violate the jump rules.
        var notes: [ChartNote] = []
        for i in 0..<8 {
            notes.append(note(i, time: 0.2 * Double(i), lane: i % 2 == 0 ? 0 : 3))
        }
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        let result = ChartValidator.validate(notes, constraints: constraints)
        XCTAssertGreaterThan(result.hardFailureCount, 0)
    }

    func testSlowExtremeJumpIsFine() {
        // 0→3 jump with 0.6s gap is acceptable.
        let notes = [
            note(0, time: 0, lane: 0),
            note(1, time: 0.6, lane: 3),
            note(2, time: 1.2, lane: 0)
        ]
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        let result = ChartValidator.validate(notes, constraints: constraints)
        XCTAssertEqual(result.hardFailureCount, 0)
    }

    func testWarnsOnBouncePattern() {
        var notes: [ChartNote] = []
        for i in 0..<12 {
            notes.append(note(i, time: 0.6 * Double(i), lane: i % 2 == 0 ? 0 : 3))
        }
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        let result = ChartValidator.validate(notes, constraints: constraints)
        XCTAssertTrue(result.warnings.contains { $0.contains("bouncing") })
        XCTAssertEqual(result.hardFailureCount, 0)
    }
}