import XCTest
@testable import Music_Haptics

/// Feature extraction must be deterministic, bounded, and schema-stable.
final class AIFeatureTests: XCTestCase {
    private func makeChart(difficulty: DifficultyLevel = .medium,
                           density: Double = 1.0,
                           seed: UInt64 = 42) async throws -> (notes: [ChartNote], metrics: DifficultyMetrics, analysis: AudioAnalysis) {
        let analysis = SignalFixtures.drumHeavy(bpm: 120, seconds: 30)
        let output = try await ChartGenerator().generate(analysis: analysis, songID: UUID(),
                                                         request: .init(difficulty: difficulty,
                                                                        densityMultiplier: density,
                                                                        seed: seed))
        return (output.chart.notes, output.metrics, analysis)
    }

    func testDifficultyFeatureCountMatchesSchema() async throws {
        let (notes, metrics, analysis) = try await makeChart()
        let features = DifficultyFeatureExtractor.extract(notes: notes, metrics: metrics, analysis: analysis)
        XCTAssertEqual(features.count, DifficultyFeatureExtractor.featureCount)
        XCTAssertEqual(features.count, AIModelCatalog.difficultyFeatureCount)
        XCTAssertEqual(features.count, 16)
    }

    func testDifficultyFeaturesAreBoundedAndDeterministic() async throws {
        let (notes, metrics, analysis) = try await makeChart()
        let a = DifficultyFeatureExtractor.extract(notes: notes, metrics: metrics, analysis: analysis)
        let b = DifficultyFeatureExtractor.extract(notes: notes, metrics: metrics, analysis: analysis)
        XCTAssertEqual(a, b)
        for f in a {
            XCTAssertTrue(f >= 0 && f <= 1, "feature \(f) out of bounds")
        }
    }

    func testDifficultyFeaturesRespondToDensity() async throws {
        let sparse = try await makeChart(difficulty: .easy, density: 0.6)
        let dense = try await makeChart(difficulty: .extreme, density: 1.3)
        let fSparse = DifficultyFeatureExtractor.extract(notes: sparse.notes, metrics: sparse.metrics, analysis: sparse.analysis)
        let fDense = DifficultyFeatureExtractor.extract(notes: dense.notes, metrics: dense.metrics, analysis: dense.analysis)
        // Denser charts must raise the density family of features.
        XCTAssertGreaterThan(fDense[DifficultyFeatureExtractor.Index.notesPerSecond.rawValue],
                             fSparse[DifficultyFeatureExtractor.Index.notesPerSecond.rawValue])
        XCTAssertGreaterThan(fDense[DifficultyFeatureExtractor.Index.noteCount.rawValue],
                             fSparse[DifficultyFeatureExtractor.Index.noteCount.rawValue])
    }

    func testBPMFeatureIsMonotonic() {
        let slow = SignalFixtures.metronomeAnalysis(bpm: 60, seconds: 10)
        let fast = SignalFixtures.metronomeAnalysis(bpm: 200, seconds: 10)
        let fSlow = DifficultyFeatureExtractor.extract(notes: [], metrics: emptyMetrics(), analysis: slow)
        let fFast = DifficultyFeatureExtractor.extract(notes: [], metrics: emptyMetrics(), analysis: fast)
        XCTAssertLessThan(fSlow[DifficultyFeatureExtractor.Index.bpm.rawValue],
                          fFast[DifficultyFeatureExtractor.Index.bpm.rawValue])
    }

    func testEventFeatureCountAndBounds() {
        let analysis = SignalFixtures.quietLoud(seconds: 32)
        XCTAssertFalse(analysis.events.isEmpty)
        let ctx = EventFeatureExtractor.context(for: analysis)
        for (i, event) in analysis.events.prefix(50).enumerated() {
            let features = EventFeatureExtractor.extract(event, index: i, events: analysis.events, ctx: ctx)
            XCTAssertEqual(features.count, EventFeatureExtractor.featureCount)
            XCTAssertEqual(features.count, AIModelCatalog.eventFeatureCount)
            for f in features {
                XCTAssertTrue(f >= 0 && f <= 1, "feature \(f) out of bounds")
            }
        }
    }

    func testEventFeaturesDistinguishOnBeatFromGhost() {
        let analysis = SignalFixtures.sparseVocal(bpm: 90, seconds: 16)
        let ctx = EventFeatureExtractor.context(for: analysis)
        let onBeat = analysis.events.first { $0.isOnBeat }!
        let ghost = analysis.events.first { !$0.isOnBeat }!
        let fOn = EventFeatureExtractor.extract(onBeat, index: analysis.events.firstIndex(of: onBeat)!,
                                                events: analysis.events, ctx: ctx)
        let fGhost = EventFeatureExtractor.extract(ghost, index: analysis.events.firstIndex(of: ghost)!,
                                                   events: analysis.events, ctx: ctx)
        XCTAssertEqual(fOn[EventFeatureExtractor.Index.onBeat.rawValue], 1)
        XCTAssertEqual(fGhost[EventFeatureExtractor.Index.onBeat.rawValue], 0)
        XCTAssertGreaterThan(fOn[EventFeatureExtractor.Index.beatStrength.rawValue],
                             fGhost[EventFeatureExtractor.Index.beatStrength.rawValue])
        XCTAssertGreaterThan(fOn[EventFeatureExtractor.Index.dspImportance.rawValue],
                             fGhost[EventFeatureExtractor.Index.dspImportance.rawValue])
    }

    private func emptyMetrics() -> DifficultyMetrics {
        DifficultyMetrics(score10: 0, label: .easy, notesPerSecond: 0, averageInterval: 0,
                          maxBurstNPS: 0, simultaneityRatio: 0, averageJumpDistance: 0,
                          alternationRatio: 0, intervalStdDev: 0, spikeRatio: 0, sustainedNPS: 0)
    }
}