import XCTest
@testable import Music_Haptics

/// AI stress: repeated inference, missing model, invalid features, non-finite
/// input, inference failure, and deterministic fallback. The AI layer must
/// NEVER throw, never crash, and always degrade to the deterministic system.
@MainActor
final class AIStressTests: XCTestCase {

    private func metrics(_ score: Double) -> DifficultyMetrics {
        DifficultyMetrics(score10: score, label: .medium, notesPerSecond: 1.5,
                          averageInterval: 0.7, maxBurstNPS: 3.0, simultaneityRatio: 0.1,
                          averageJumpDistance: 1.2, alternationRatio: 0.4,
                          intervalStdDev: 0.2, spikeRatio: 1.8, sustainedNPS: 2.0)
    }

    // MARK: - Engine-level stress (missing / broken model)

    func testMissingModelNeverThrowsAndFallsBack() async {
        // Explicitly point at model URLs that cannot exist: predictions must
        // return nil, availability must be false, and the error recorded —
        // never a throw. (AIEngine() alone is NOT sufficient here: the iOS
        // app bundle ships the compiled models, so the default URL is found.)
        let engine = AIEngine(difficultyModelURL: URL(fileURLWithPath: "/nonexistent/AIDifficulty.mlmodelc"),
                              eventModelURL: URL(fileURLWithPath: "/nonexistent/AIEvent.mlmodelc"),
                              patternModelURL: URL(fileURLWithPath: "/nonexistent/AIPattern.mlmodelc"))
        for _ in 0..<50 {
            let diff = await engine.predictDifficulty(features: [Double](repeating: 0.5, count: 16))
            XCTAssertNil(diff, "missing model must yield nil, not a score")
            let events = await engine.predictEventImportance(batch: [[Double](repeating: 0.5, count: 12)])
            XCTAssertNil(events)
        }
        let diffAvailable = await engine.isDifficultyAvailable()
        XCTAssertFalse(diffAvailable)
        let eventAvailable = await engine.isEventAvailable()
        XCTAssertFalse(eventAvailable)
        let lastError = await engine.lastError()
        XCTAssertNotNil(lastError)
    }

    func testUnloadableModelURLFailsGracefully() async {
        // A URL that cannot exist: load failure must be silent + nil.
        let engine = AIEngine(difficultyModelURL: URL(fileURLWithPath: "/nonexistent/AIDifficulty.mlmodelc"),
                              eventModelURL: URL(fileURLWithPath: "/nonexistent/AIEvent.mlmodelc"))
        for _ in 0..<20 {
            let diff = await engine.predictDifficulty(features: [Double](repeating: 1.0, count: 16))
            XCTAssertNil(diff)
            let events = await engine.predictEventImportance(batch: [[Double](repeating: 1.0, count: 12)])
            XCTAssertNil(events)
        }
    }

    func testInvalidFeatureCountsReturnNil() async {
        // Wrong feature counts fail provider construction → nil (caller falls
        // back), never a crash and never garbage output.
        let engine = AIEngine(difficultyModelURL: URL(fileURLWithPath: "/nonexistent/x.mlmodelc"),
                              eventModelURL: URL(fileURLWithPath: "/nonexistent/y.mlmodelc"))
        let empty = await engine.predictDifficulty(features: [])
        XCTAssertNil(empty)
        let one = await engine.predictDifficulty(features: [0.1])
        XCTAssertNil(one)
        let emptyBatch = await engine.predictEventImportance(batch: [])
        XCTAssertNil(emptyBatch)
        let emptyRow = await engine.predictEventImportance(batch: [[]])
        XCTAssertNil(emptyRow)
    }

    func testNonFiniteInputsNeverEscape() async {
        // NaN / ±inf features must be rejected at the provider boundary; the
        // fusion layer independently refuses non-finite AI scores.
        let config = AIFusionConfig.default
        for value in [Double.nan, .infinity, -.infinity] {
            let features = [Double](repeating: value, count: 16)
            // The provider path rejects them (or the engine catches) → nil.
            let engine = AIEngine(difficultyModelURL: URL(fileURLWithPath: "/nonexistent/x.mlmodelc"),
                                  eventModelURL: nil)
            let ai = await engine.predictDifficulty(features: features)
            if let ai {
                // If anything slipped through, fusion must clamp/sanitize it.
                let outcome = AIDifficultyFusion.fuse(deterministic: 4.0, ai: ai, config: config)
                XCTAssertTrue(outcome.finalScore.isFinite)
                XCTAssertTrue((0...10).contains(outcome.finalScore))
            } else {
                // Rejected → deterministic fallback intact.
                let outcome = AIDifficultyFusion.fuse(deterministic: 4.0, ai: nil, config: config)
                XCTAssertEqual(outcome.finalScore, 4.0)
                XCTAssertFalse(outcome.usedAI)
            }
        }
        // Direct fusion with NaN/Inf AI scores: always the deterministic value.
        for bad in [Double.nan, .infinity, -.infinity] {
            let outcome = AIDifficultyFusion.fuse(deterministic: 6.5, ai: bad, config: config)
            XCTAssertEqual(outcome.finalScore, 6.5)
            XCTAssertFalse(outcome.usedAI)
        }
    }

    // MARK: - Fusion fallback under stress

    func testFusionFallbackRepeatedlyStable() {
        let config = AIFusionConfig(enabled: true, difficultyAIWeight: 0.3,
                                    eventAIWeight: 0.35, minEventConfidence: 0.3)
        // Same inputs → same output, 1000 times (determinism under load).
        for _ in 0..<1000 {
            let outcome = AIDifficultyFusion.fuse(deterministic: 5.0, ai: 7.0, config: config)
            XCTAssertEqual(outcome.finalScore, 5.6, accuracy: 1e-9)
            XCTAssertEqual(outcome.aiScore, 7.0)
        }
        for _ in 0..<1000 {
            let outcome = AIDifficultyFusion.fuse(deterministic: 4.2, ai: nil, config: config)
            XCTAssertEqual(outcome.finalScore, 4.2)
            XCTAssertFalse(outcome.usedAI)
        }
    }

    func testFusionClampsOutOfRangeAI() {
        // AI scores beyond [0,10] (broken model output) must clamp, never leak.
        let config = AIFusionConfig(enabled: true, difficultyAIWeight: 1.0,
                                    eventAIWeight: 0, minEventConfidence: 0)
        let low = AIDifficultyFusion.fuse(deterministic: 2.0, ai: -5.0, config: config)
        XCTAssertEqual(low.finalScore, 0.0)
        let high = AIDifficultyFusion.fuse(deterministic: 2.0, ai: 99.0, config: config)
        XCTAssertEqual(high.finalScore, 10.0)
    }

    func testEventFusionNonFiniteAI() {
        let config = AIFusionConfig.default
        for bad in [Double.nan, .infinity, -.infinity] {
            let outcome = AIEventFusion.fusedImportance(time: 1.0, dsp: 0.7, ai: bad, config: config)
            XCTAssertEqual(outcome.finalImportance, 0.7, "non-finite AI must not move DSP importance")
            XCTAssertFalse(outcome.usedAI)
        }
    }

    // MARK: - AISystem-level repeated calls

    func testAISystemRepeatedCallsWithoutModel() async {
        // Repeated advisor calls with no bundled model: nil outcomes, no
        // crash, diagnostics store untouched.
        let system = AISystem(engine: AIEngine(difficultyModelURL: URL(fileURLWithPath: "/nonexistent/x.mlmodelc"),
                                               eventModelURL: URL(fileURLWithPath: "/nonexistent/y.mlmodelc")))
        let analysis = SignalFixtures.metronomeAnalysis(bpm: 120, seconds: 8)
        let notes = analysis.beats.enumerated().map { i, beat in
            ChartNote(id: i, time: beat.time, lane: i % 4, duration: 0, type: .tap, strength: 1)
        }
        for _ in 0..<30 {
            let outcome = await system.difficultyOutcome(songID: UUID(), notes: notes,
                                                         metrics: metrics(3.0), analysis: analysis)
            // No model → a GRACEFUL FALLBACK outcome: the deterministic score
            // passes through untouched, AI flags all nil/false.
            XCTAssertNotNil(outcome)
            XCTAssertEqual(outcome?.finalScore, 3.0)
            XCTAssertEqual(outcome?.deterministicScore, 3.0)
            XCTAssertFalse(outcome?.usedAI ?? true)
            XCTAssertNil(outcome?.aiScore)
            XCTAssertNil(outcome?.modelVersion)
            let importance = await system.eventImportance(songID: UUID(), events: [], analysis: analysis)
            XCTAssertNil(importance)
        }
    }

    func testAISystemDisabledConfigShortCircuits() async {
        // Config disabled: the advisor returns nil immediately, no inference.
        let system = AISystem(engine: AIEngine())
        system.config = AIFusionConfig(enabled: false, difficultyAIWeight: 0.5,
                                       eventAIWeight: 0.5, minEventConfidence: 0)
        let analysis = SignalFixtures.metronomeAnalysis(bpm: 100, seconds: 6)
        let notes = analysis.beats.enumerated().map { i, beat in
            ChartNote(id: i, time: beat.time, lane: i % 4, duration: 0, type: .tap, strength: 1)
        }
        for _ in 0..<20 {
            let outcome = await system.difficultyOutcome(songID: UUID(), notes: notes,
                                                         metrics: metrics(3.0), analysis: analysis)
            XCTAssertNil(outcome)
        }
    }

    // MARK: - Versioning sanity

    func testCatalogVersionsAreStablePositive() {
        XCTAssertGreaterThanOrEqual(AIModelCatalog.difficultyModelVersion, 2)
        XCTAssertGreaterThanOrEqual(AIModelCatalog.eventModelVersion, 2)
        XCTAssertGreaterThan(AIModelCatalog.featureSchemaVersion, 0)
        // Difficulty feature count must match what the extractor produces
        // (a schema change without a bump would silently break charts).
        XCTAssertEqual(AIModelCatalog.difficultyFeatureCount, 16)
        XCTAssertGreaterThan(AIModelCatalog.eventFeatureCount, 0)
    }
}