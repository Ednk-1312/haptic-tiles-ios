import XCTest
@testable import Music_Haptics

/// The chart generator must consult the AI advisor without ever letting it
/// break determinism, playability or versioning.
final class AIGeneratorIntegrationTests: XCTestCase {
    /// Deterministic fake advisor for testing the integration contract.
    /// A reference type so tests can inspect call counts; `@unchecked Sendable`
    /// because it is only touched inside the generator's serialized call.
    private final class MockAdvisor: AIChartAdvisor, @unchecked Sendable {
        let eventImportanceValue: Double?   // nil → deterministic
        let difficultyScore: Double?        // nil → deterministic
        private(set) var difficultyCalls = 0

        init(eventImportanceValue: Double?, difficultyScore: Double? = nil) {
            self.eventImportanceValue = eventImportanceValue
            self.difficultyScore = difficultyScore
        }

        func eventImportance(songID: UUID, events: [MusicalEvent], analysis: AudioAnalysis) async -> [Double]? {
            eventImportanceValue.map { Array(repeating: $0, count: events.count) }
        }

        func difficultyOutcome(songID: UUID, notes: [ChartNote], metrics: DifficultyMetrics,
                               analysis: AudioAnalysis) async -> AIDifficultyOutcome? {
            difficultyCalls += 1
            guard let difficultyScore else { return nil }
            return AIDifficultyOutcome(finalScore: difficultyScore,
                                       deterministicScore: metrics.score10,
                                       aiScore: difficultyScore,
                                       aiConfidence: 0.95,
                                       usedAI: true,
                                       modelVersion: AIModelCatalog.difficultyModelVersion,
                                       inferenceMs: 0.5)
        }
    }

    private func generate(analysis: AudioAnalysis, advisor: (any AIChartAdvisor)?) async throws -> ChartGenerator.Output {
        try await ChartGenerator().generate(analysis: analysis, songID: UUID(),
                                            request: .init(difficulty: .medium, densityMultiplier: 1.0, seed: 42),
                                            advisor: advisor)
    }

    func testNoAdvisorMatchesVersionedDeterministicBaseline() async throws {
        let analysis = SignalFixtures.drumHeavy(bpm: 120, seconds: 30)
        let plain = try await generate(analysis: analysis, advisor: nil)
        XCTAssertEqual(plain.chart.chartVersion, ChartStorage.chartVersion)
        XCTAssertNil(plain.chart.aiDifficultyScore)
        XCTAssertNil(plain.chart.aiModelVersion)
    }

    func testEventRankingChangesSelection() async throws {
        // Deterministic two-candidate fixture: beats at 1 s with a single
        // musical event on each "and" (beat + 0.5 s). When the AI ranks that
        // event high the chart must chart the "and" (competing with the beat);
        // when it ranks it at zero the chart falls back to the beat pulse.
        // This isolates the re-ranking mechanism from the density budget.
        func analysis(eventImportance: Double) -> AudioAnalysis {
            let beats = SignalFixtures.quarterBeats(bpm: 60, seconds: 22, strongEvery: 4,
                                                    strongStrength: 0.95)
            var events: [MusicalEvent] = []
            for beat in beats where beat.time + 0.5 < 20 {
                events.append(SignalFixtures.event(time: beat.time + 0.5, strength: 0.6,
                                                   importance: eventImportance))
            }
            return SignalFixtures.makeAnalysis(duration: 22, bpm: 60, beats: beats, events: events,
                                               sections: [SongSection(index: 0, start: 0, end: 22,
                                                                       label: .generic, energy: 1.0)])
        }
        final class ConstantAdvisor: AIChartAdvisor, @unchecked Sendable {
            let value: Double
            init(_ value: Double) { self.value = value }
            func eventImportance(songID: UUID, events: [MusicalEvent],
                                 analysis: AudioAnalysis) async -> [Double]? {
                Array(repeating: value, count: events.count)
            }
            func difficultyOutcome(songID: UUID, notes: [ChartNote], metrics: DifficultyMetrics,
                                   analysis: AudioAnalysis) async -> AIDifficultyOutcome? { nil }
        }

        let analysis = analysis(eventImportance: 0.9)
        let high = try await generate(analysis: analysis, advisor: ConstantAdvisor(1.0))
        let low = try await generate(analysis: analysis, advisor: ConstantAdvisor(0.0))
        let timesHigh = high.chart.notes.map(\.time)
        let timesLow = low.chart.notes.map(\.time)
        // The high-ranking chart must place notes on the off-beat "and"s; the
        // low-ranking one must not (it keeps the bare beat pulse instead).
        let andHigh = timesHigh.filter { abs(($0.truncatingRemainder(dividingBy: 1.0)) - 0.5) < 0.06 }.count
        let andLow = timesLow.filter { abs(($0.truncatingRemainder(dividingBy: 1.0)) - 0.5) < 0.06 }.count
        XCTAssertGreaterThan(andHigh, 5, "high-ranked off-beat events should be charted")
        XCTAssertLessThan(andLow, andHigh, "suppressed events must not displace the pulse")
    }

    func testIdentityRankingMatchesDeterministicBaseline() async throws {
        // An advisor that returns the DSP importance unchanged must produce a
        // byte-identical chart — proves the hook is value-faithful and that a
        // no-op AI cannot perturb the deterministic output.
        final class IdentityAdvisor: AIChartAdvisor, @unchecked Sendable {
            func eventImportance(songID: UUID, events: [MusicalEvent],
                                 analysis: AudioAnalysis) async -> [Double]? {
                events.map(\.importance)
            }
            func difficultyOutcome(songID: UUID, notes: [ChartNote], metrics: DifficultyMetrics,
                                   analysis: AudioAnalysis) async -> AIDifficultyOutcome? { nil }
        }
        let analysis = SignalFixtures.drumHeavy(bpm: 120, seconds: 30)
        let plain = try await generate(analysis: analysis, advisor: nil)
        let identity = try await generate(analysis: analysis, advisor: IdentityAdvisor())
        XCTAssertEqual(plain.chart.notes.map(\.time), identity.chart.notes.map(\.time))
        XCTAssertEqual(plain.chart.notes.map(\.lane), identity.chart.notes.map(\.lane))
    }

    func testAdvisorOutputIsDeterministic() async throws {
        let analysis = SignalFixtures.quietLoud(seconds: 32)
        let a = try await generate(analysis: analysis, advisor: MockAdvisor(eventImportanceValue: 0.85))
        let b = try await generate(analysis: analysis, advisor: MockAdvisor(eventImportanceValue: 0.85))
        XCTAssertEqual(a.chart.notes.map(\.time), b.chart.notes.map(\.time))
        XCTAssertEqual(a.chart.notes.map(\.lane), b.chart.notes.map(\.lane))
        XCTAssertEqual(a.chart.difficultyScore, b.chart.difficultyScore)
    }

    func testAIAdvisorChartsRemainPlayable() async throws {
        let analysis = SignalFixtures.fastDrumHeavy(bpm: 220, seconds: 24)
        let output = try await generate(analysis: analysis, advisor: MockAdvisor(eventImportanceValue: 1.0))
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        let validation = ChartValidator.validate(output.chart.notes, constraints: constraints)
        XCTAssertEqual(validation.hardFailureCount, 0)
    }

    func testDifficultyFusionIsRecorded() async throws {
        let analysis = SignalFixtures.drumHeavy(bpm: 120, seconds: 30)
        let advisor = MockAdvisor(eventImportanceValue: nil, difficultyScore: 8.0)
        let output = try await generate(analysis: analysis, advisor: advisor)
        XCTAssertEqual(output.chart.difficultyScore, 8.0)
        XCTAssertEqual(output.chart.aiDifficultyScore, 8.0)
        XCTAssertEqual(output.chart.deterministicDifficultyScore, output.metrics.score10)
        XCTAssertEqual(output.chart.aiModelVersion, AIModelCatalog.difficultyModelVersion)
        XCTAssertEqual(advisor.difficultyCalls, 1)
    }

    func testNilAdvisorResultsAreIdenticalToNilRanking() async throws {
        // An advisor that returns nil for both hooks must not change anything.
        let analysis = SignalFixtures.sparseVocal(bpm: 90, seconds: 24)
        let plain = try await generate(analysis: analysis, advisor: nil)
        let nilAdvisor = try await generate(analysis: analysis,
                                            advisor: MockAdvisor(eventImportanceValue: nil, difficultyScore: nil))
        XCTAssertEqual(plain.chart.notes.map(\.time), nilAdvisor.chart.notes.map(\.time))
        XCTAssertEqual(plain.chart.notes.map(\.lane), nilAdvisor.chart.notes.map(\.lane))
        XCTAssertEqual(plain.chart.difficultyScore, nilAdvisor.chart.difficultyScore)
        XCTAssertNil(nilAdvisor.chart.aiModelVersion)
    }
}