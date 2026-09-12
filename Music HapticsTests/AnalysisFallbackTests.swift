import XCTest
@testable import Music_Haptics

/// Candidate-rejection recoverability: one failed analysis stage (onset
/// detection returning nothing) must not make the whole song unusable. The
/// analyzer derives deterministic fallback events from the detected beats,
/// then from a quarter-note grid at the detected tempo, before ever
/// reporting "no musical events". These tests pin the fallback synthesis and
/// prove the beat-only output still charts cleanly.
final class AnalysisFallbackTests: XCTestCase {
    private let sections = [SongSection(index: 0, start: 0, end: 60, label: .generic, energy: 0.6)]
    private let hopTime = 512.0 / 44100.0

    // MARK: - Beat-grid fallback

    func testBeatGridFallbackYieldsOneEventPerBeat() {
        let beats = SignalFixtures.quarterBeats(bpm: 120, seconds: 20)
        let events = AudioAnalyzer.fallbackEvents(beats: beats, tempoBPM: 120,
                                                  bands: [], hopTime: hopTime,
                                                  sections: sections, duration: 20)
        XCTAssertEqual(events.count, beats.count)
        for (event, beat) in zip(events, beats) {
            XCTAssertEqual(event.time, beat.time, accuracy: 1e-9)
            XCTAssertTrue(event.isOnBeat)
            XCTAssertEqual(event.type, beat.isStrong ? .accent : .beat)
            XCTAssertEqual(event.beatStrength, beat.strength, accuracy: 1e-9)
            XCTAssertEqual(event.strength, beat.strength, accuracy: 1e-9)
        }
        // Strong beats must carry the highest importance (selection priority).
        let strong = events.filter { $0.type == .accent }
        let weak = events.filter { $0.type == .beat }
        XCTAssertFalse(strong.isEmpty)
        XCTAssertFalse(weak.isEmpty)
        XCTAssertGreaterThan(strong.map(\.importance).min() ?? 0,
                             weak.map(\.importance).max() ?? 1)
    }

    func testBeatGridFallbackIsDeterministic() {
        let beats = SignalFixtures.quarterBeats(bpm: 100, seconds: 15)
        let a = AudioAnalyzer.fallbackEvents(beats: beats, tempoBPM: 100,
                                             bands: [], hopTime: hopTime,
                                             sections: sections, duration: 15)
        let b = AudioAnalyzer.fallbackEvents(beats: beats, tempoBPM: 100,
                                             bands: [], hopTime: hopTime,
                                             sections: sections, duration: 15)
        XCTAssertEqual(a, b)
    }

    // MARK: - Tempo-grid fallback (no beats either)

    func testTempoGridFallbackWhenNoBeats() {
        let events = AudioAnalyzer.fallbackEvents(beats: [], tempoBPM: 120,
                                                  bands: [], hopTime: hopTime,
                                                  sections: sections, duration: 10)
        XCTAssertEqual(events.count, 20)   // quarter notes at 120 BPM over 10 s
        for (i, event) in events.enumerated() {
            XCTAssertEqual(event.time, Double(i) * 0.5, accuracy: 1e-9)
            XCTAssertTrue(event.isOnBeat)
            XCTAssertEqual(event.type, i % 4 == 0 ? .accent : .beat)
        }
    }

    func testTempoGridFallbackRejectsUnusableTempos() {
        XCTAssertTrue(AudioAnalyzer.fallbackEvents(beats: [], tempoBPM: 0,
                                                   bands: [], hopTime: hopTime,
                                                   sections: sections, duration: 10).isEmpty)
        XCTAssertTrue(AudioAnalyzer.fallbackEvents(beats: [], tempoBPM: 400,
                                                   bands: [], hopTime: hopTime,
                                                   sections: sections, duration: 10).isEmpty)
    }

    func testFallbackEmptyWhenNothingAvailable() {
        XCTAssertTrue(AudioAnalyzer.fallbackEvents(beats: [], tempoBPM: 0,
                                                   bands: [], hopTime: hopTime,
                                                   sections: sections, duration: 10).isEmpty)
    }

    // MARK: - Section/band mapping

    func testFallbackUsesSectionEnergyAndBandShape() {
        let beats = [Beat(time: 1.0, strength: 0.9, isStrong: true)]
        let bands = [(low: Float(0.8), mid: Float(0.1), high: Float(0.1))]
        let sections = [SongSection(index: 0, start: 0, end: 2, label: .intro, energy: 0.9)]
        let events = AudioAnalyzer.fallbackEvents(beats: beats, tempoBPM: 120,
                                                  bands: bands, hopTime: hopTime,
                                                  sections: sections, duration: 2)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].sectionIndex, 0)
        XCTAssertEqual(events[0].lowEnergy, 0.8, accuracy: 1e-6)
        XCTAssertEqual(events[0].importance, 1.0, accuracy: 1e-6)   // normalized to max
    }

    // MARK: - End-to-end: beat-only analysis charts cleanly

    func testBeatOnlyAnalysisStillGeneratesValidChart() async throws {
        let beats = SignalFixtures.quarterBeats(bpm: 120, seconds: 16)
        let analysis = SignalFixtures.makeAnalysis(duration: 16, bpm: 120,
                                                   beats: beats, events: [],
                                                   sections: [SongSection(index: 0, start: 0, end: 16,
                                                                          label: .generic, energy: 0.6)])
        let request = ChartGenerator.Request(difficulty: .medium, densityMultiplier: 1.0, seed: 42)
        let output = try await ChartGenerator().generate(analysis: analysis,
                                                         songID: UUID(), request: request)
        XCTAssertGreaterThan(output.chart.notes.count, 0)
        let validation = ChartValidator.validate(output.chart.notes,
                                                 constraints: ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0))
        XCTAssertEqual(validation.hardFailureCount, 0, "\(validation.hardFailures)")
    }
}