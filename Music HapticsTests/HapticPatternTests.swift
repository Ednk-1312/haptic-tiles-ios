import XCTest
@testable import Music_Haptics

final class HapticPatternTests: XCTestCase {

    private let musical = HapticProfileStore.profile(for: .musical)

    // MARK: - Judgment ordering

    func testJudgmentPatternsAreOrdered() {
        // Within every profile, Perfect > Great > Good > Miss in intensity.
        for id in HapticProfileID.allCases {
            let profile = HapticProfileStore.profile(for: id)
            let perfect = profile.noteParameters(for: .perfect).intensity
            let great = profile.noteParameters(for: .great).intensity
            let good = profile.noteParameters(for: .good).intensity
            let miss = profile.noteParameters(for: .miss).intensity
            XCTAssertGreaterThan(perfect, great, "\(id): perfect > great")
            XCTAssertGreaterThan(great, good, "\(id): great > good")
            XCTAssertGreaterThan(good, miss, "\(id): good > miss")
        }
    }

    // MARK: - Settings gating

    func testPatternsRespectSettings() {
        XCTAssertNotNil(HapticPatternGenerator.pattern(for: .perfect, noteStrength: 1.0,
                                                       profile: musical,
                                                       enabled: true, strengthScale: 1.0, reduced: false))
        XCTAssertNil(HapticPatternGenerator.pattern(for: .great, noteStrength: 1.0,
                                                    profile: musical,
                                                    enabled: false, strengthScale: 1.0, reduced: false))
        // Reduced mode suppresses miss feedback entirely…
        XCTAssertNil(HapticPatternGenerator.pattern(for: .miss, noteStrength: 1.0,
                                                    profile: musical,
                                                    enabled: true, strengthScale: 1.0, reduced: true))
        // …but keeps hit feedback (softer).
        XCTAssertNotNil(HapticPatternGenerator.pattern(for: .great, noteStrength: 1.0,
                                                       profile: musical,
                                                       enabled: true, strengthScale: 1.0, reduced: true))
    }

    func testBeatPatternExists() {
        XCTAssertNotNil(HapticPatternGenerator.beatPattern(strength: 0.5, isStrong: true,
                                                           profile: musical, strengthScale: 1.0))
    }

    // MARK: - Chord

    func testChordPatternRespectsMasterAndReduced() {
        XCTAssertNotNil(HapticPatternGenerator.chordPattern(profile: musical,
                                                            enabled: true, strengthScale: 1.0, reduced: false))
        XCTAssertNil(HapticPatternGenerator.chordPattern(profile: musical,
                                                         enabled: false, strengthScale: 1.0, reduced: false))
        XCTAssertNotNil(HapticPatternGenerator.chordPattern(profile: musical,
                                                            enabled: true, strengthScale: 1.0, reduced: true))
    }
}