import XCTest
@testable import Music_Haptics

/// Event-ranking AI tests: deterministic feature fixtures (golden vectors),
/// fusion/uncertainty semantics, fallback aggregation, diagnostics recording,
/// and the guarantee that AI importances can never inflate a chart beyond the
/// difficulty's density constraints.
@MainActor
final class AIEventRankingTests: XCTestCase {

    // MARK: - Deterministic feature fixture

    /// Hand-computed golden 16-vector for a known event + context. Any change
    /// to the feature schema (order, normalization, label factors) breaks this
    /// test — that's the point: the model's feature vector is frozen.
    func testEventFeatureGoldenVector() {
        var beats: [Beat] = []
        var t = 0.0
        while t <= 40 {
            beats.append(Beat(time: t, strength: 0.5, isStrong: false))
            t += 0.5
        }
        let events = [
            SignalFixtures.event(time: 9.0, strength: 0.4, importance: 0.2),
            SignalFixtures.event(time: 10.0, strength: 0.8, importance: 0.6),
            SignalFixtures.event(time: 11.0, strength: 0.4, importance: 0.2),
        ]
        let analysis = SignalFixtures.makeAnalysis(
            duration: 40, bpm: 120, beats: beats, events: events,
            sections: [SongSection(index: 0, start: 0, end: 40, label: .generic, energy: 0.7)])
        let ctx = EventFeatureExtractor.context(for: analysis)
        // Rebuild the target with full fields so the golden vector is exact.
        let event = MusicalEvent(time: 10.0, strength: 0.8, confidence: 0.9,
                                 type: .percussive, lowEnergy: 0.5, midEnergy: 0.4, highEnergy: 0.3,
                                 isOnBeat: true, beatStrength: 0.7, sectionIndex: 0, importance: 0.6)
        let f = EventFeatureExtractor.extract(event, index: 1, events: events, ctx: ctx)

        let expected: [Double] = [
            0.25,   // timePosition: 10 / 40
            0.8,    // strength
            0.9,    // confidence
            0.4,    // totalEnergy: (0.5+0.4+0.3)/3
            0.5,    // lowEnergy
            0.4,    // midEnergy
            0.3,    // highEnergy
            0.7,    // beatStrength
            1.0,    // onBeat
            0.0,    // beatDistance: exactly on a beat
            0.0,    // localDensity: no events within ±0.5 s
            0.3,    // prevDistance: 0.3 / (10 - 9)
            0.3,    // nextDistance: 0.3 / (11 - 10)
            0.7,    // sectionEnergy
            0.82,   // sectionLabelFactor(.generic)
            0.6,    // dspImportance
        ]
        XCTAssertEqual(f.count, EventFeatureExtractor.featureCount)
        XCTAssertEqual(f.count, AIModelCatalog.eventFeatureCount,
                       "catalog schema must match the extractor")
        for (i, (got, want)) in zip(f, expected).enumerated() {
            XCTAssertEqual(got, want, accuracy: 1e-12, "feature[\(i)]")
        }
    }

    func testEventFeaturesAreDeterministicAcrossCalls() {
        let beats = SignalFixtures.quarterBeats(bpm: 120, seconds: 30)
        let events = (0..<50).map { i in
            SignalFixtures.event(time: Double(i) * 0.6, strength: 0.5, importance: 0.5)
        }
        let analysis = SignalFixtures.makeAnalysis(duration: 30, bpm: 120, beats: beats,
                                                  events: events,
                                                  sections: [SongSection(index: 0, start: 0, end: 30,
                                                                          label: .verse, energy: 0.6)])
        let ctx = EventFeatureExtractor.context(for: analysis)
        let a = EventFeatureExtractor.extract(events[7], index: 7, events: events, ctx: ctx)
        let b = EventFeatureExtractor.extract(events[7], index: 7, events: events, ctx: ctx)
        XCTAssertEqual(a, b)
    }

    // MARK: - Fusion + uncertainty

    func testFusionUncertaintyAndClamping() {
        let config = AIFusionConfig(enabled: true, difficultyAIWeight: 0.3,
                                    eventAIWeight: 0.35, minEventConfidence: 0.3)
        // Decisive + high → blended, in range.
        let blend = AIEventFusion.fusedImportance(time: 1, dsp: 0.4, ai: 0.9, config: config)
        XCTAssertEqual(blend.finalImportance, 0.4 * 0.65 + 0.9 * 0.35, accuracy: 1e-9)
        XCTAssertTrue(blend.usedAI)
        XCTAssertEqual(blend.aiConfidence ?? 0, 0.8, accuracy: 1e-9)   // 2·|0.9 − 0.5|
        // Indecisive (near 0.5) → DSP unchanged, uncertainty exposed.
        let unsure = AIEventFusion.fusedImportance(time: 2, dsp: 0.6, ai: 0.52, config: config)
        XCTAssertEqual(unsure.finalImportance, 0.6)
        XCTAssertFalse(unsure.usedAI)
        XCTAssertEqual(unsure.aiConfidence ?? 0, 0.04, accuracy: 1e-9)
        // Out-of-range AI never leaks.
        let wild = AIEventFusion.fusedImportance(time: 3, dsp: 0.5, ai: 4.0, config: config)
        XCTAssertLessThanOrEqual(wild.finalImportance, 1.0)
        XCTAssertLessThanOrEqual(wild.aiImportance ?? 0, 1.0)
    }

    // MARK: - Fallback aggregation (diagnostics)

    func testFallbackAggregationCountsAndAverages() {
        let config = AIFusionConfig(enabled: true, difficultyAIWeight: 0.3,
                                    eventAIWeight: 0.35, minEventConfidence: 0.3)
        // 8 events; 3 with decisive AI, 5 indecisive → 5 fallbacks.
        let dsp = [0.2, 0.5, 0.8, 0.4, 0.6, 0.9, 0.3, 0.7]
        let ai = [0.9, 0.51, 0.1, 0.52, 0.6, 0.5, 0.49, 0.95]
        var events: [AIEventDiagnostic] = []
        for (i, (d, a)) in zip(dsp, ai).enumerated() {
            let outcome = AIEventFusion.fusedImportance(time: Double(i), dsp: d, ai: a, config: config)
            events.append(AIEventDiagnostic(time: Double(i), dspImportance: outcome.dspImportance,
                                            aiImportance: outcome.aiImportance,
                                            aiConfidence: outcome.aiConfidence,
                                            finalImportance: outcome.finalImportance,
                                            selected: i % 2 == 0,
                                            usedAI: outcome.usedAI,
                                            features: [Double](repeating: 0, count: 16)))
        }
        let diag = AISongDiagnostics(songID: UUID(), generatedAt: Date(),
                                     modelVersion: AIModelCatalog.eventModelVersion,
                                     featureSchemaVersion: AIModelCatalog.featureSchemaVersion,
                                     events: events)
        XCTAssertEqual(diag.eventCount, 8)
        XCTAssertEqual(diag.fallbackCount, 5, "indecisive predictions fall back to DSP")
        // Average final score: DSP for the 5 fallbacks, blended for the 3 used.
        let used = [0, 2, 7]
        var sum = 0.0
        for i in 0..<8 {
            if used.contains(i) {
                sum += dsp[i] * 0.65 + ai[i] * 0.35
            } else {
                sum += dsp[i]
            }
        }
        XCTAssertEqual(diag.averageEventScore, sum / 8, accuracy: 1e-9)
        // Average confidence covers EVERY ranked event: used ones report their
        // high decisiveness, fallbacks report their (low) uncertainty — the
        // aggregate shows how trustworthy the batch was overall.
        let allConfs = ai.map { 2 * abs($0 - 0.5) }
        XCTAssertEqual(diag.averageConfidence, allConfs.reduce(0, +) / Double(allConfs.count), accuracy: 1e-9)
    }

    func testMissingModelMeansNoEventRankingAndNoDiagnostics() async {
        // Model-less engine: the advisor returns nil (deterministic path) and
        // no diagnostics are fabricated for events that never ran.
        let system = AISystem(engine: AIEngine(difficultyModelURL: URL(fileURLWithPath: "/nonexistent/d.mlmodelc"),
                                               eventModelURL: URL(fileURLWithPath: "/nonexistent/e.mlmodelc")))
        system.config = AIFusionConfig(enabled: true, difficultyAIWeight: 0.5,
                                       eventAIWeight: 0.5, minEventConfidence: 0.3)
        let analysis = SignalFixtures.metronomeAnalysis(bpm: 120, seconds: 8)
        let scores = await system.eventImportance(songID: UUID(), events: analysis.events, analysis: analysis)
        XCTAssertNil(scores, "missing model → deterministic selection, no ranking")
        // The difficulty advisor still returns a graceful fallback outcome.
        let notes = analysis.beats.enumerated().map { i, beat in
            ChartNote(id: i, time: beat.time, lane: i % 4, duration: 0, type: .tap, strength: 1)
        }
        let metrics = DifficultyMetrics(score10: 3, label: .medium, notesPerSecond: 2,
                                        averageInterval: 0.5, maxBurstNPS: 5, simultaneityRatio: 0.1,
                                        averageJumpDistance: 1.0, alternationRatio: 0.3,
                                        intervalStdDev: 0.2, spikeRatio: 1.5, sustainedNPS: 2.5)
        let outcome = await system.difficultyOutcome(songID: UUID(), notes: notes,
                                                     metrics: metrics, analysis: analysis)
        XCTAssertEqual(outcome?.finalScore, 3.0)
        XCTAssertFalse(outcome?.usedAI ?? true)
    }

    // MARK: - Difficulty constraints are never bypassed by AI importance

    func testExtremeImportanceCannotExceedDensityCaps() async throws {
        final class MaxImportanceAdvisor: AIChartAdvisor, @unchecked Sendable {
            func eventImportance(songID: UUID, events: [MusicalEvent],
                                 analysis: AudioAnalysis) async -> [Double]? {
                // Every candidate is "the most important thing in the song".
                Array(repeating: 1.0, count: events.count)
            }
            func difficultyOutcome(songID: UUID, notes: [ChartNote], metrics: DifficultyMetrics,
                                   analysis: AudioAnalysis) async -> AIDifficultyOutcome? { nil }
        }
        // Dense input: quarter + off-beat events everywhere for 60 s.
        let beats = SignalFixtures.quarterBeats(bpm: 120, seconds: 60, strongEvery: 4)
        var events: [MusicalEvent] = []
        for beat in beats {
            events.append(SignalFixtures.event(time: beat.time, strength: 1.0, importance: 0.9))
            events.append(SignalFixtures.event(time: beat.time + 0.25, strength: 1.0, importance: 0.9))
            events.append(SignalFixtures.event(time: beat.time + 0.5, strength: 1.0, importance: 0.9))
        }
        let analysis = SignalFixtures.makeAnalysis(duration: 60, bpm: 120, beats: beats, events: events,
                                                   sections: [SongSection(index: 0, start: 0, end: 60,
                                                                           label: .chorus, energy: 1.0)])
        let output = try await ChartGenerator().generate(
            analysis: analysis, songID: UUID(),
            request: ChartGenerator.Request(difficulty: .hard, densityMultiplier: 1.0, seed: 11),
            advisor: MaxImportanceAdvisor())
        let chart = output.chart
        let constraints = ChartConstraints.forDifficulty(.hard, densityMultiplier: 1.0)

        // The AI ranks everything at 1.0, yet the chart must stay physically
        // playable: validator-clean, no negative/timeless notes, and the
        // per-second density cannot exceed the difficulty's cap.
        XCTAssertTrue(chart.validationWarnings.isEmpty,
                      "extreme AI importance must not produce validator warnings: \(chart.validationWarnings)")
        for note in chart.notes {
            XCTAssertFalse(note.time.isNaN)
            XCTAssertGreaterThanOrEqual(note.time, 0)
            XCTAssertTrue((0..<4).contains(note.lane))
        }
        var maxNPS = 0.0
        for start in stride(from: 0.0, to: 60.0, by: 1.0) {
            let inWindow = chart.notes.filter { $0.time >= start && $0.time < start + 1 }.count
            maxNPS = max(maxNPS, Double(inWindow))
        }
        XCTAssertLessThanOrEqual(maxNPS, constraints.maxNPS + 0.01,
                                 "AI importance must never exceed the difficulty's notes/sec cap")
        // And the chart still uses the real lanes with sane spacing.
        XCTAssertGreaterThan(chart.notes.count, 50)
    }
}