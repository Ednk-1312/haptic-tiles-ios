import XCTest
@testable import Music_Haptics

final class ScoreManagerTests: XCTestCase {
    func testComboMultiplierStepsAndBreak() {
        var score = ScoreManager()
        for _ in 0..<9 { score.apply(.great) }
        XCTAssertEqual(score.multiplier, 1)
        score.apply(.great)   // 10th hit → 2×
        XCTAssertEqual(score.multiplier, 2)
        let before = score.score
        score.apply(.perfect) // 2 × 1000
        XCTAssertEqual(score.score - before, 2000)
        score.apply(.miss)    // breaks combo
        XCTAssertEqual(score.comboCount, 0)
        XCTAssertEqual(score.multiplier, 1)
    }

    func testMaxComboTracks() {
        var score = ScoreManager()
        for _ in 0..<5 { score.apply(.perfect) }
        score.apply(.miss)
        for _ in 0..<3 { score.apply(.perfect) }
        XCTAssertEqual(score.maxCombo, 5)
    }

    func testAccuracyWeighting() {
        var score = ScoreManager()
        score.apply(.perfect)
        score.apply(.great)
        score.apply(.good)
        score.apply(.miss)
        XCTAssertEqual(score.accuracy, (1.0 + 0.75 + 0.5) / 4.0, accuracy: 0.001)
    }

    func testMissScoresZero() {
        var score = ScoreManager()
        score.apply(.miss)
        XCTAssertEqual(score.score, 0)
        XCTAssertEqual(score.counts[.miss], 1)
    }
}