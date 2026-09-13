import XCTest
@testable import Music_Haptics

/// Genre → mood resolution and mood → palette contract for the gameplay
/// background: keyword robustness, offline-safe fallbacks, and readable
/// palettes for every mood.
final class GenreMoodTests: XCTestCase {

    // MARK: - Keyword resolution

    func testCommonGenreStringsResolve() {
        XCTAssertEqual(GenreMood.resolve(from: "Hip-Hop/Rap"), .hipHop)
        XCTAssertEqual(GenreMood.resolve(from: "Dance"), .dance)
        XCTAssertEqual(GenreMood.resolve(from: "Alt. Dance"), .dance)
        XCTAssertEqual(GenreMood.resolve(from: "Electronic"), .electronic)
        XCTAssertEqual(GenreMood.resolve(from: "Hard Rock"), .rock)
        XCTAssertEqual(GenreMood.resolve(from: "Heavy Metal"), .rock)
        XCTAssertEqual(GenreMood.resolve(from: "Chillhop; Lo-fi Beats".components(separatedBy: "; ")[1]), .chill)
        XCTAssertEqual(GenreMood.resolve(from: "Classical Crossover"), .sad)
        XCTAssertEqual(GenreMood.resolve(from: "Pop"), .happy)
        XCTAssertEqual(GenreMood.resolve(from: "Reggae"), .happy)
    }

    func testCaseAndWhitespaceInsensitivity() {
        XCTAssertEqual(GenreMood.resolve(from: "  HIP-HOP "), .hipHop)
        XCTAssertEqual(GenreMood.resolve(from: "Lo-Fi"), .chill)
        XCTAssertEqual(GenreMood.resolve(from: "dAnCe"), .dance)
    }

    func testUnknownAndEmptyResolveNeutral() {
        XCTAssertEqual(GenreMood.resolve(from: nil), .neutral)
        XCTAssertEqual(GenreMood.resolve(from: ""), .neutral)
        XCTAssertEqual(GenreMood.resolve(from: "   "), .neutral)
        XCTAssertEqual(GenreMood.resolve(from: "Klezmer"), .neutral)
        XCTAssertEqual(GenreMood.resolve(from: " Newman"), .neutral)
    }

    /// Specific families win over broad ones: "Dance Pop" is dance, not pop.
    func testSpecificFamilyBeatsBroadKeyword() {
        XCTAssertEqual(GenreMood.resolve(from: "Dance Pop"), .dance)
        XCTAssertEqual(GenreMood.resolve(from: "Indie Rock"), .rock)
        XCTAssertEqual(GenreMood.resolve(from: "Trap"), .hipHop)
    }

    // MARK: - Palettes

    /// Every mood carries a complete, distinct, readable palette.
    func testEveryMoodHasDistinctReadablePalette() {
        var tops = Set<String>()
        for mood in GenreMood.allCases {
            let (top, bottom, accent) = (mood.top, mood.bottom, mood.accent)
            for color in [top, bottom, accent] {
                XCTAssertTrue((0...1).contains(color.r) && (0...1).contains(color.g) && (0...1).contains(color.b))
            }
            // Bottom must differ from top: a flat gradient reads as a bug.
            XCTAssertNotEqual(top, bottom, "\(mood.rawValue) palette is flat")
            tops.insert("\(top.r)-\(top.g)-\(top.b)")
        }
        XCTAssertEqual(tops.count, GenreMood.allCases.count, "two moods share a top color — the backgrounds would be indistinguishable")
    }

    /// Tint strength stays moderate: even the boldest mood must leave the
    /// reference field (and note readability) intact.
    func testTintStrengthsStayModerate() {
        for mood in GenreMood.allCases {
            XCTAssertTrue(mood.tintStrength >= 0.15 && mood.tintStrength <= 0.45,
                          "\(mood.rawValue) tint strength \(mood.tintStrength) is out of the readability-safe band")
        }
    }

    // MARK: - Blending math (used by the theme factory)

    func testThemeBlendingPullsTowardMood() {
        let base = RGB(0.9, 0.9, 0.9)
        let blended = RGB(base.r + (0.0 - base.r) * 0.5,
                          base.g + (0.0 - base.g) * 0.5,
                          base.b + (0.0 - base.b) * 0.5)
        XCTAssertEqual(blended.r, 0.45, accuracy: 0.001)
        XCTAssertEqual(blended.g, 0.45, accuracy: 0.001)
        XCTAssertEqual(blended.b, 0.45, accuracy: 0.001)
    }
}
