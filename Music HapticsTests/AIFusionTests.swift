import XCTest
@testable import Music_Haptics

/// Fusion math: weights, confidence floors, and deterministic fallback.
final class AIFusionTests: XCTestCase {
    func testDifficultyFusionWeightedBlend() {
        let config = AIFusionConfig(enabled: true, difficultyAIWeight: 0.3,
                                    eventAIWeight: 0.35, minEventConfidence: 0.3)
        let outcome = AIDifficultyFusion.fuse(deterministic: 5.0, ai: 7.0, config: config)
        XCTAssertEqual(outcome.finalScore, 5.6, accuracy: 1e-9)
        XCTAssertEqual(outcome.deterministicScore, 5.0)
        XCTAssertEqual(outcome.aiScore, 7.0)
        XCTAssertTrue(outcome.usedAI)
        // Confidence = 1 - |Δ|/3 = 1 - 2/3.
        XCTAssertEqual(outcome.aiConfidence ?? 0, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testDifficultyFusionClampsTo10() {
        let config = AIFusionConfig(enabled: true, difficultyAIWeight: 1.0,
                                    eventAIWeight: 0, minEventConfidence: 0)
        let outcome = AIDifficultyFusion.fuse(deterministic: 9.9, ai: 42.0, config: config)
        XCTAssertEqual(outcome.finalScore, 10.0)
        XCTAssertEqual(outcome.aiScore, 10.0)
    }

    func testDifficultyFallbackWithoutAI() {
        let config = AIFusionConfig.default
        let outcome = AIDifficultyFusion.fuse(deterministic: 4.2, ai: nil, config: config)
        XCTAssertEqual(outcome.finalScore, 4.2)
        XCTAssertFalse(outcome.usedAI)
        XCTAssertNil(outcome.aiConfidence)
    }

    func testDifficultyFallbackWhenDisabled() {
        let config = AIFusionConfig(enabled: false, difficultyAIWeight: 0.9,
                                    eventAIWeight: 0.9, minEventConfidence: 0)
        let outcome = AIDifficultyFusion.fuse(deterministic: 3.3, ai: 9.0, config: config)
        XCTAssertEqual(outcome.finalScore, 3.3)
        XCTAssertFalse(outcome.usedAI)
    }

    func testDifficultyFallbackOnNonFiniteAI() {
        let config = AIFusionConfig.default
        let outcome = AIDifficultyFusion.fuse(deterministic: 5.0, ai: .nan, config: config)
        XCTAssertEqual(outcome.finalScore, 5.0)
        XCTAssertFalse(outcome.usedAI)
    }

    func testEventFusionBlend() {
        let config = AIFusionConfig(enabled: true, difficultyAIWeight: 0.3,
                                    eventAIWeight: 0.35, minEventConfidence: 0.3)
        let outcome = AIEventFusion.fusedImportance(time: 1.0, dsp: 0.8, ai: 0.9, config: config)
        XCTAssertEqual(outcome.finalImportance, 0.8 * 0.65 + 0.9 * 0.35, accuracy: 1e-9)
        XCTAssertTrue(outcome.usedAI)
        XCTAssertEqual(outcome.aiConfidence ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(outcome.time, 1.0)
    }

    func testEventFusionFallsBackOnLowConfidence() {
        // ai = 0.5 → decisiveness 0, below the floor → DSP unchanged.
        let config = AIFusionConfig(enabled: true, difficultyAIWeight: 0.3,
                                    eventAIWeight: 0.35, minEventConfidence: 0.3)
        let outcome = AIEventFusion.fusedImportance(time: 0, dsp: 0.7, ai: 0.5, config: config)
        XCTAssertEqual(outcome.finalImportance, 0.7)
        XCTAssertFalse(outcome.usedAI)
    }

    func testEventFusionFallbackWithoutAIOrDisabled() {
        let config = AIFusionConfig.default
        let noAI = AIEventFusion.fusedImportance(time: 0, dsp: 0.6, ai: nil, config: config)
        XCTAssertEqual(noAI.finalImportance, 0.6)
        XCTAssertFalse(noAI.usedAI)
        let disabled = AIEventFusion.fusedImportance(time: 0, dsp: 0.6, ai: 0.95,
                                                     config: AIFusionConfig(enabled: false, difficultyAIWeight: 0,
                                                                            eventAIWeight: 0, minEventConfidence: 0))
        XCTAssertEqual(disabled.finalImportance, 0.6)
        XCTAssertFalse(disabled.usedAI)
    }

    func testConfigValidationClamps() {
        let config = AIFusionConfig(enabled: true, difficultyAIWeight: 5.0,
                                    eventAIWeight: -1.0, minEventConfidence: 2.0)
        let v = config.validated
        XCTAssertEqual(v.difficultyAIWeight, 1.0)
        XCTAssertEqual(v.eventAIWeight, 0.0)
        XCTAssertEqual(v.minEventConfidence, 1.0)
    }
}