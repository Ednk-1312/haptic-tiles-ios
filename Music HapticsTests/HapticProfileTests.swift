import XCTest
@testable import Music_Haptics

/// Deterministic tests for the haptic profiles and the anti-stack cooldown.
final class HapticProfileTests: XCTestCase {

    // MARK: - Profile definitions

    func testProfilesAreOrderedByStrength() {
        let minimal = HapticProfileStore.profile(for: .minimal)
        let musical = HapticProfileStore.profile(for: .musical)
        let strong = HapticProfileStore.profile(for: .strong)
        for judgment in [Judgment.perfect, .great, .good] {
            let m = minimal.noteParameters(for: judgment).intensity
            let mu = musical.noteParameters(for: judgment).intensity
            let s = strong.noteParameters(for: judgment).intensity
            XCTAssertLessThan(m, mu, "minimal < musical for \(judgment)")
            XCTAssertLessThanOrEqual(mu, s, "musical ≤ strong for \(judgment)")
        }
        // Cooldowns: minimal is the most conservative.
        XCTAssertGreaterThan(minimal.minIntervalMs, musical.minIntervalMs)
        XCTAssertGreaterThan(musical.minIntervalMs, strong.minIntervalMs)
    }

    func testMinimalDisablesMusicalCategories() {
        let minimal = HapticProfileStore.profile(for: .minimal)
        XCTAssertEqual(minimal.beatWeak, 0)
        XCTAssertEqual(minimal.beatStrong, 0)
        XCTAssertEqual(minimal.accent, 0)
        XCTAssertEqual(minimal.sectionChange, 0)
        XCTAssertFalse(minimal.perfectDoubleTap)
        XCTAssertNil(HapticPatternGenerator.beatPattern(strength: 0.8, isStrong: true,
                                                        profile: minimal, strengthScale: 1.0))
        XCTAssertNil(HapticPatternGenerator.accentPattern(profile: minimal, strengthScale: 1.0))
        XCTAssertNil(HapticPatternGenerator.sectionChangePattern(profile: minimal, strengthScale: 1.0))
    }

    func testBeatFocusedEmphasizesBeatsOverNotes() {
        let beatFocused = HapticProfileStore.profile(for: .beatFocused)
        let musical = HapticProfileStore.profile(for: .musical)
        XCTAssertGreaterThan(beatFocused.beatStrong, musical.beatStrong)
        XCTAssertGreaterThan(beatFocused.beatWeak, musical.beatWeak)
        XCTAssertGreaterThan(beatFocused.accent, musical.accent)
        XCTAssertLessThan(beatFocused.noteParameters(for: .perfect).intensity,
                          musical.noteParameters(for: .perfect).intensity,
                          "beat-focused keeps note taps lighter than musical")
    }

    func testAllProfilesProducePatterns() {
        for id in HapticProfileID.allCases {
            let profile = HapticProfileStore.profile(for: id)
            XCTAssertNotNil(HapticPatternGenerator.pattern(for: .perfect, noteStrength: 1.0,
                                                           profile: profile,
                                                           enabled: true, strengthScale: 1.0, reduced: false),
                           "\(id) note pattern")
            XCTAssertNotNil(HapticPatternGenerator.holdStartPattern(profile: profile,
                                                                    enabled: true, strengthScale: 1.0),
                           "\(id) hold start")
            XCTAssertNotNil(HapticPatternGenerator.holdEndPattern(profile: profile,
                                                                  enabled: true, strengthScale: 1.0),
                           "\(id) hold end")
            XCTAssertNotNil(HapticPatternGenerator.chordPattern(profile: profile,
                                                                enabled: true, strengthScale: 1.0, reduced: false),
                           "\(id) chord")
        }
    }

    func testStrongProfileUsesDoubleTapPerfect() {
        let strong = HapticProfileStore.profile(for: .strong)
        let minimal = HapticProfileStore.profile(for: .minimal)
        XCTAssertTrue(strong.perfectDoubleTap)
        XCTAssertFalse(minimal.perfectDoubleTap)
        // Both produce patterns; the strong one is simply louder.
        let strongPattern = HapticPatternGenerator.pattern(for: .perfect, noteStrength: 1.0,
                                                           profile: strong,
                                                           enabled: true, strengthScale: 1.0, reduced: false)
        let minimalPattern = HapticPatternGenerator.pattern(for: .perfect, noteStrength: 1.0,
                                                            profile: minimal,
                                                            enabled: true, strengthScale: 1.0, reduced: false)
        XCTAssertNotNil(strongPattern)
        XCTAssertNotNil(minimalPattern)
    }

    // MARK: - Determinism

    func testProfilesAreDeterministic() {
        // Identical lookups always return identical parameters (no runtime
        // randomness anywhere in the profile store or pattern builders).
        let a = HapticProfileStore.profile(for: .musical)
        let b = HapticProfileStore.profile(for: .musical)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.noteParameters(for: .perfect), b.noteParameters(for: .perfect))
        // And strong beats are parametrically stronger than weak ones.
        XCTAssertGreaterThan(a.beatStrong, a.beatWeak)
    }

    private func musical() -> HapticProfile {
        HapticProfileStore.profile(for: .musical)
    }

    // MARK: - Cooldown (anti-stack guard)

    func testCooldownBlocksRapidFires() {
        // 500 ms interval (0.5 s is exactly representable — avoids binary
        // rounding at the boundary).
        var cooldown = HapticCooldown(minIntervalMs: 500)
        XCTAssertTrue(cooldown.allowFire(at: 10.0))
        XCTAssertFalse(cooldown.allowFire(at: 10.1), "100 ms later must be blocked")
        XCTAssertFalse(cooldown.allowFire(at: 10.4))
        XCTAssertTrue(cooldown.allowFire(at: 10.5), "exactly 500 ms later is allowed")
        XCTAssertFalse(cooldown.allowFire(at: 10.55))
        XCTAssertTrue(cooldown.allowFire(at: 11.0))
    }

    func testCooldownZeroMeansNoLimit() {
        var cooldown = HapticCooldown(minIntervalMs: 0)
        XCTAssertTrue(cooldown.allowFire(at: 1.0))
        XCTAssertTrue(cooldown.allowFire(at: 1.0001))
    }

    func testCooldownReset() {
        var cooldown = HapticCooldown(minIntervalMs: 500)
        XCTAssertTrue(cooldown.allowFire(at: 10))
        XCTAssertFalse(cooldown.allowFire(at: 10.1))
        cooldown.reset()
        XCTAssertTrue(cooldown.allowFire(at: 10.1), "reset must clear the last-fire time")
    }

    func testCooldownClampsNegativeInterval() {
        let cooldown = HapticCooldown(minIntervalMs: -5)
        XCTAssertEqual(cooldown.minIntervalMs, 0)
    }

    // MARK: - Scheduler gating (pure subset)

    func testSchedulerBeatGatingByProfile() {
        // Minimal: beats produce no pattern even when scheduled.
        let minimal = HapticProfileStore.profile(for: .minimal)
        let pattern = HapticPatternGenerator.beatPattern(strength: 1.0, isStrong: true,
                                                         profile: minimal, strengthScale: 1.0)
        XCTAssertNil(pattern)
    }
}