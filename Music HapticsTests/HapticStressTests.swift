import XCTest
@testable import Music_Haptics

/// Haptic stress: repeated pattern generation across every profile/category,
/// cooldown churn (the anti-stack guard), and engine-reset semantics. Core
/// Haptics playback itself is device-only, but the pure profile/cooldown/
/// pattern layer must be deterministic and stable under heavy load.
final class HapticStressTests: XCTestCase {

    func testPatternGenerationChurnAllProfilesAllCategories() {
        // Every profile × every category × 200 iterations: always non-nil
        // where the profile enables the category, always nil where disabled.
        for id in HapticProfileID.allCases {
            let profile = HapticProfileStore.profile(for: id)
            for _ in 0..<200 {
                for judgment in [Judgment.perfect, .great, .good, .miss] {
                    let pattern = HapticPatternGenerator.pattern(for: judgment, noteStrength: 1.0,
                                                                 profile: profile, enabled: true,
                                                                 strengthScale: 1.0, reduced: false)
                    XCTAssertNotNil(pattern, "\(id) \(judgment)")
                }
                XCTAssertNotNil(HapticPatternGenerator.chordPattern(profile: profile,
                                                                    enabled: true, strengthScale: 1.0,
                                                                    reduced: false))
                XCTAssertNotNil(HapticPatternGenerator.holdStartPattern(profile: profile,
                                                                        enabled: true, strengthScale: 1.0))
                XCTAssertNotNil(HapticPatternGenerator.holdEndPattern(profile: profile,
                                                                      enabled: true, strengthScale: 1.0))
                // Category gating is stable across repeated calls.
                if profile.beatWeak == 0 {
                    XCTAssertNil(HapticPatternGenerator.beatPattern(strength: 0.9, isStrong: true,
                                                                    profile: profile, strengthScale: 1.0))
                    XCTAssertNil(HapticPatternGenerator.accentPattern(profile: profile, strengthScale: 1.0))
                    XCTAssertNil(HapticPatternGenerator.sectionChangePattern(profile: profile, strengthScale: 1.0))
                } else {
                    XCTAssertNotNil(HapticPatternGenerator.beatPattern(strength: 0.9, isStrong: true,
                                                                       profile: profile, strengthScale: 1.0))
                }
            }
        }
    }

    func testProfileLookupChurnIsStable() {
        // 10,000 lookups across all ids: same id → same profile every time
        // (the store is deterministic, never memoized-random).
        for _ in 0..<10_000 {
            let id = HapticProfileID.allCases[Int.random(in: 0..<HapticProfileID.allCases.count)]
            let a = HapticProfileStore.profile(for: id)
            let b = HapticProfileStore.profile(for: id)
            XCTAssertEqual(a, b, "profile lookup must be stable per id")
        }
    }

    func testCooldownChurnUnderDenseHits() {
        // 20,000 fires at 10 ms intervals through a 35 ms cooldown: accepted
        // fires must exactly match the cooldown math — no early fires.
        var cooldown = HapticCooldown(minIntervalMs: 35)
        var accepted = 0
        var previousFire: Double? = nil
        for i in 0..<20_000 {
            let now = Double(i) * 0.010
            if cooldown.allowFire(at: now) {
                accepted += 1
                if let prev = previousFire {
                    XCTAssertGreaterThanOrEqual(now - prev, 0.035 - 1e-9)
                }
                previousFire = now
            }
        }
        XCTAssertEqual(accepted, 5000, "a 10ms stream through a 35ms gate admits every 4th fire")
    }

    func testCooldownResetSimulatesEngineReset() {
        // Engine reset (interruption / song change): the cooldown forgets its
        // history and an immediate fire is allowed — stale suppression must
        // never survive a reset.
        var cooldown = HapticCooldown(minIntervalMs: 50)
        XCTAssertTrue(cooldown.allowFire(at: 1.000))
        XCTAssertFalse(cooldown.allowFire(at: 1.010), "within cooldown → suppressed")
        cooldown.reset()
        XCTAssertTrue(cooldown.allowFire(at: 1.011), "reset clears suppression")
    }

    func testCooldownAlternatingProfiles() {
        // Rapid profile switches re-create the cooldown per profile: the
        // sequence must stay within each profile's own interval, and a fresh
        // cooldown never blocks the first fire.
        for _ in 0..<1000 {
            var cooldown = HapticCooldown(minIntervalMs: 25)
            XCTAssertTrue(cooldown.allowFire(at: 0.5))
            XCTAssertFalse(cooldown.allowFire(at: 0.51))
            cooldown = HapticCooldown(minIntervalMs: 25)
            XCTAssertTrue(cooldown.allowFire(at: 0.52), "fresh cooldown never blocks")
        }
    }

    func testReducedModeAndStrengthScaleNeverProduceInvalidPatterns() {
        // The reduced-mode and strength-scale paths must produce patterns for
        // every profile (they feed the same choke point).
        for id in HapticProfileID.allCases {
            let profile = HapticProfileStore.profile(for: id)
            for scale in [0.25, 0.5, 1.0, 2.0] {
                XCTAssertNotNil(HapticPatternGenerator.pattern(for: .perfect, noteStrength: 0.8,
                                                               profile: profile, enabled: true,
                                                               strengthScale: scale, reduced: true),
                                "\(id) scale \(scale)")
                // Beats only exist for profiles that enable them (Minimal
                // intentionally produces none — the gating is part of the API).
                let beat = HapticPatternGenerator.beatPattern(strength: 0.6, isStrong: false,
                                                              profile: profile, strengthScale: scale)
                XCTAssertEqual(beat != nil, profile.beatWeak > 0, "\(id) scale \(scale)")
            }
        }
    }
}