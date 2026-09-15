import XCTest
@testable import Music_Haptics

final class TempoAnalysisTierTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tempo-tier-\(UUID().uuidString)", isDirectory: true)
        AppDirectories.testRootOverride = tempRoot
    }

    override func tearDown() {
        AppDirectories.testRootOverride = nil
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private let hopTime = 512.0 / 44_100.0

    private func clickFlux(bpm: Double, seconds: Double = 24) -> [Float] {
        var times: [Double] = []
        var time = 0.0
        while time < seconds {
            times.append(time)
            time += 60.0 / bpm
        }
        return SignalFixtures.impulseFlux(times: times,
                                           hopTime: hopTime,
                                           length: Int(seconds / hopTime))
    }

    private struct FixedScorer: TempoMLScorer, Sendable {
        let scores: [Double]?
        let confidence: Double

        func predict(features: [[Double]]) async -> TempoMLPrediction? {
            guard let scores else { return nil }
            return TempoMLPrediction(scores: scores,
                                     confidence: confidence,
                                     inferenceDuration: 0.25)
        }
    }

    func testCapabilitySelectionRequiresAnActuallyBundledTempoModel() {
        let unsupported = TempoAnalyzerDeviceCapabilities(
            foundationModelsAvailable: false, coreMLAvailable: true, tempoModelAvailable: true)
        XCTAssertFalse(unsupported.supportsIntelligentTempoAnalysis)
        XCTAssertEqual(TempoAnalyzerFactory.make(capabilities: unsupported).kind, .dsp)

        let noModel = TempoAnalyzerDeviceCapabilities(
            foundationModelsAvailable: true, coreMLAvailable: true, tempoModelAvailable: false)
        XCTAssertFalse(noModel.supportsIntelligentTempoAnalysis)
        XCTAssertEqual(TempoAnalyzerFactory.make(capabilities: noModel).kind, .dsp)

        let supported = TempoAnalyzerDeviceCapabilities(
            foundationModelsAvailable: true, coreMLAvailable: true, tempoModelAvailable: true)
        XCTAssertTrue(supported.supportsIntelligentTempoAnalysis)
        XCTAssertEqual(TempoAnalyzerFactory.make(capabilities: supported,
                                                  modelScorer: FixedScorer(scores: [1, 0, 0], confidence: 1)).kind,
                       .intelligentHeuristic)
    }

    func testDSPAnalyzerProducesStableTempoMetadata() async throws {
        let result = try await DSPTempoAnalyzer().analyze(
            TempoAnalysisInput(flux: clickFlux(bpm: 120), hopTime: hopTime))
        XCTAssertEqual(result.analyzer, .dsp)
        XCTAssertEqual(result.bpm, 120, accuracy: 5)
        XCTAssertGreaterThan(result.confidence, 0.2)
        XCTAssertGreaterThanOrEqual(result.stability, 0)
        XCTAssertLessThanOrEqual(result.stability, 1)
        XCTAssertGreaterThanOrEqual(result.halfDoubleAmbiguity, 0)
        XCTAssertLessThanOrEqual(result.halfDoubleAmbiguity, 1)
    }

    func testLowConfidenceIntelligentPredictionFallsBackToDSPResult() async throws {
        let input = TempoAnalysisInput(flux: clickFlux(bpm: 120), hopTime: hopTime)
        let baseline = try await DSPTempoAnalyzer().analyze(input)
        let result = try await IntelligentTempoAnalyzer(
            modelScorer: FixedScorer(scores: [0.5, 0.51, 0.49], confidence: 0.2)
        ).analyze(input)

        XCTAssertEqual(result.bpm, baseline.bpm, accuracy: 0.001)
        XCTAssertEqual(result.confidence, baseline.confidence, accuracy: 0.001)
        XCTAssertEqual(result.analyzer, .intelligentHeuristic)
        XCTAssertNotNil(result.fallbackReason)
    }

    func testConfidentCandidateRankingCanResolveHalfDoubleTime() async throws {
        let input = TempoAnalysisInput(flux: clickFlux(bpm: 120), hopTime: hopTime)
        let result = try await IntelligentTempoAnalyzer(
            modelScorer: FixedScorer(scores: [0.95, 0.2, 0.1], confidence: 0.95)
        ).analyze(input)

        // The baseline candidate list is [60, 120, 220] for a 120 BPM estimate.
        XCTAssertEqual(result.bpm, 60, accuracy: 0.2)
        XCTAssertEqual(result.analyzer, .intelligentCoreML)
        XCTAssertEqual(result.inferenceDuration ?? -1, 0.25, accuracy: 0.001)
    }

    func testCacheRoundTripMarksCacheHitAndDifferentAnalyzerKeysDoNotCollide() {
        let url = URL(fileURLWithPath: "/tmp/song-a.wav")
        let flux: [Float] = [0, 1, 0, 0.5]
        let dspKey = TempoAnalysisCache.key(url: url, sampleRate: 44_100,
                                            duration: 12, flux: flux, analyzerKind: .dsp)
        let intelligentKey = TempoAnalysisCache.key(url: url, sampleRate: 44_100,
                                                    duration: 12, flux: flux,
                                                    analyzerKind: .intelligentCoreML)
        XCTAssertNotEqual(dspKey, intelligentKey)

        let result = TempoAnalysisResult(bpm: 120, confidence: 0.9, stability: 0.8,
                                         halfDoubleAmbiguity: 0.1, tempoChangeDetected: false,
                                         analyzer: .dsp,
                                         analyzerVersion: TempoAnalysisResult.analyzerVersion,
                                         modelVersion: nil,
                                         analysisDuration: 0.4, inferenceDuration: nil,
                                         fallbackReason: nil, cacheHit: false)
        TempoAnalysisCache.save(result, key: dspKey)
        let loaded = TempoAnalysisCache.load(key: dspKey)
        XCTAssertEqual(loaded?.bpm, 120)
        XCTAssertTrue(loaded?.cacheHit == true)
        XCTAssertNil(TempoAnalysisCache.load(key: intelligentKey))
    }

    func testCacheVersionMismatchIsRejected() throws {
        let key = TempoAnalysisCache.key(url: URL(fileURLWithPath: "/tmp/song-b.wav"),
                                         sampleRate: 44_100, duration: 8,
                                         flux: [0.1, 0.2])
        let result = TempoAnalysisResult(bpm: 90, confidence: 0.8, stability: 0.7,
                                         halfDoubleAmbiguity: 0.2, tempoChangeDetected: false,
                                         analyzer: .dsp,
                                         analyzerVersion: TempoAnalysisResult.analyzerVersion,
                                         modelVersion: nil,
                                         analysisDuration: 0.1, inferenceDuration: nil,
                                         fallbackReason: nil, cacheHit: false)
        let resultObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        let staleEntry: [String: Any] = ["version": 0, "key": key, "result": resultObject]
        let data = try JSONSerialization.data(withJSONObject: staleEntry)
        try data.write(to: TempoAnalysisCache.cacheURLForTesting(key: key), options: .atomic)

        XCTAssertNil(TempoAnalysisCache.load(key: key))
    }

    func testEnhancedFallbackCanBeCachedWithoutPretendingModelInferenceSucceeded() {
        let key = TempoAnalysisCache.key(url: URL(fileURLWithPath: "/tmp/song-c.wav"),
                                         sampleRate: 44_100, duration: 8,
                                         flux: [0.1, 0.2], analyzerKind: .intelligentHeuristic)
        let result = TempoAnalysisResult(bpm: 90, confidence: 0.8, stability: 0.7,
                                         halfDoubleAmbiguity: 0.2, tempoChangeDetected: false,
                                         analyzer: .intelligentHeuristic,
                                         analyzerVersion: TempoAnalysisResult.analyzerVersion,
                                         modelVersion: nil,
                                         analysisDuration: 0.1, inferenceDuration: nil,
                                         fallbackReason: "model unavailable", cacheHit: false)

        TempoAnalysisCache.save(result, key: key)
        let loaded = TempoAnalysisCache.load(key: key)
        XCTAssertEqual(loaded?.analyzer, .intelligentHeuristic)
        XCTAssertNil(loaded?.modelVersion)
        XCTAssertEqual(loaded?.fallbackReason, "model unavailable")
        XCTAssertTrue(loaded?.cacheHit == true)
    }

    func testTempoNormalizationHandlesHalfAndDoubleTimeCandidates() {
        XCTAssertEqual(TempoAnalysisMath.normalizedBPM(60), 120, accuracy: 0.001)
        XCTAssertEqual(TempoAnalysisMath.normalizedBPM(240), 120, accuracy: 0.001)
        XCTAssertEqual(TempoAnalysisMath.normalizedBPM(128), 128, accuracy: 0.001)
        XCTAssertEqual(TempoAnalysisMath.normalizedBPM(.nan), 0)
    }

    func testBundledAITempoModelLoadsAndRanksCandidates() async throws {
        // The model is an application resource. Loading the compiled resource
        // from the host bundle verifies the exact artifact shipped to iOS,
        // rather than merely checking that the source .mlmodel exists.
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "AITempo", withExtension: "mlmodelc"),
            "AITempo.mlmodelc must be present in the built app bundle")
        let scorer = CoreMLTempoScorer(modelURL: url)
        let rawPrediction = await scorer.predict(features: [
            Array(repeating: 0.1, count: 12),
            Array(repeating: 0.5, count: 12),
            Array(repeating: 0.9, count: 12)
        ])
        let prediction = try XCTUnwrap(rawPrediction)
        XCTAssertEqual(prediction.scores.count, 3)
        XCTAssertTrue(prediction.scores.allSatisfy(\.isFinite))
        XCTAssertTrue(prediction.inferenceDuration >= 0)
    }
}