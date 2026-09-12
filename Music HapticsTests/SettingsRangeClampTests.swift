import XCTest
@testable import Music_Haptics

/// Pins the Settings crash fix. SwiftUI's `Slider` traps (instant crash) when
/// a bound value sits outside its range. This app has been installed-over
/// since the prototype era, so older builds could have persisted values that
/// today's sliders reject — every Double read from UserDefaults must be
/// clamped in SettingsStore.init before it can ever reach a slider.
@MainActor
final class SettingsRangeClampTests: XCTestCase {

    private let keys = [
        "settings.noteApproachTime",
        "settings.calibrationOffsetMs",
        "settings.perfectWindowMs",
        "settings.greatWindowMs",
        "settings.goodWindowMs",
        "settings.holdCompleteBonus",
        "settings.hapticStrength",
        "settings.volume",
        "settings.chartDensityMultiplier",
        "settings.aiDifficultyWeight",
        "settings.aiEventWeight",
        "settings.aiMinEventConfidence",
    ]

    override func tearDown() {
        let d = UserDefaults.standard
        for key in keys { d.removeObject(forKey: key) }
        super.tearDown()
    }

    /// Simulates a legacy install whose stored values predate today's ranges
    /// (this exact state crashed the app the moment Settings opened).
    func testOutOfRangePersistedValuesAreClampedOnInit() {
        let d = UserDefaults.standard
        d.set(0.2, forKey: "settings.noteApproachTime")      // below 1.0
        d.set(500, forKey: "settings.calibrationOffsetMs")   // above 100
        d.set(5, forKey: "settings.perfectWindowMs")         // below 30
        d.set(999, forKey: "settings.greatWindowMs")         // above 140
        d.set(-50, forKey: "settings.goodWindowMs")          // below 120
        d.set(99_999, forKey: "settings.holdCompleteBonus")  // above 2000
        d.set(12.0, forKey: "settings.hapticStrength")       // above 1.0
        d.set(-3.0, forKey: "settings.volume")               // below 0
        d.set(7.5, forKey: "settings.chartDensityMultiplier")// above 1.4

        let settings = SettingsStore()

        XCTAssertGreaterThanOrEqual(settings.noteApproachTime, SettingsStore.SettingsRange.noteApproachTime.lowerBound)
        XCTAssertLessThanOrEqual(settings.calibrationOffsetMs, SettingsStore.SettingsRange.calibrationOffsetMs.upperBound)
        XCTAssertGreaterThanOrEqual(settings.perfectWindowMs, SettingsStore.SettingsRange.perfectWindowMs.lowerBound)
        XCTAssertLessThanOrEqual(settings.greatWindowMs, SettingsStore.SettingsRange.greatWindowMs.upperBound)
        XCTAssertGreaterThanOrEqual(settings.goodWindowMs, SettingsStore.SettingsRange.goodWindowMs.lowerBound)
        XCTAssertLessThanOrEqual(settings.holdCompleteBonus, SettingsStore.SettingsRange.holdCompleteBonus.upperBound)
        XCTAssertLessThanOrEqual(settings.hapticStrength, SettingsStore.SettingsRange.hapticStrength.upperBound)
        XCTAssertGreaterThanOrEqual(settings.volume, SettingsStore.SettingsRange.volume.lowerBound)
        XCTAssertLessThanOrEqual(settings.chartDensityMultiplier, SettingsStore.SettingsRange.chartDensityMultiplier.upperBound)
    }

    /// Fresh install: every default must already satisfy its own slider range
    /// (a default outside its range would trap the same way).
    func testDefaultsAreWithinEverySliderRange() {
        let settings = SettingsStore()
        let r = SettingsStore.SettingsRange.self

        XCTAssertTrue(r.noteApproachTime.contains(settings.noteApproachTime))
        XCTAssertTrue(r.calibrationOffsetMs.contains(settings.calibrationOffsetMs))
        XCTAssertTrue(r.perfectWindowMs.contains(settings.perfectWindowMs))
        XCTAssertTrue(r.greatWindowMs.contains(settings.greatWindowMs))
        XCTAssertTrue(r.goodWindowMs.contains(settings.goodWindowMs))
        XCTAssertTrue(r.holdCompleteBonus.contains(settings.holdCompleteBonus))
        XCTAssertTrue(r.hapticStrength.contains(settings.hapticStrength))
        XCTAssertTrue(r.volume.contains(settings.volume))
        XCTAssertTrue(r.chartDensityMultiplier.contains(settings.chartDensityMultiplier))
        XCTAssertTrue(r.aiDifficultyWeight.contains(settings.aiDifficultyWeight))
        XCTAssertTrue(r.aiEventWeight.contains(settings.aiEventWeight))
        XCTAssertTrue(r.aiMinEventConfidence.contains(settings.aiMinEventConfidence))
    }

    /// Judgment windows are independently configurable, so their ranges MAY
    /// overlap (deliberate: grading falls through Perfect→Great→Good and the
    /// engine stays coherent even when a user sets Perfect wider than Great).
    /// What must always hold: every range is positive and non-inverted.
    func testJudgmentWindowRangesAreSane() {
        let r = SettingsStore.SettingsRange.self
        XCTAssertLessThanOrEqual(r.perfectWindowMs.lowerBound, r.perfectWindowMs.upperBound)
        XCTAssertLessThanOrEqual(r.greatWindowMs.lowerBound, r.greatWindowMs.upperBound)
        XCTAssertLessThanOrEqual(r.goodWindowMs.lowerBound, r.goodWindowMs.upperBound)
        XCTAssertGreaterThanOrEqual(r.perfectWindowMs.lowerBound, 0)
        XCTAssertGreaterThanOrEqual(r.greatWindowMs.lowerBound, 0)
        XCTAssertGreaterThanOrEqual(r.goodWindowMs.lowerBound, 0)
    }
}
