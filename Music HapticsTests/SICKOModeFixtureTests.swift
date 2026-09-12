import AVFoundation
import XCTest
@testable import Music_Haptics

/// SICKO MODE reproduction with an ACCESSIBLE synthetic fixture (the real
/// Apple Music asset is DRM-protected; no circumvention is attempted). The
/// fixture reproduces the song's characteristic analysis surface — ~155 BPM
/// trap with sixteenth-note hi-hat rolls, kick/clap accents, vocal-like
/// mid-band content, and a mid-song beat switch — and the full pipeline
/// (decode → analyze → chart → validate) must complete with a playable,
/// deterministic chart.
final class SICKOModeFixtureTests: XCTestCase {
    private let songID = UUID(uuidString: "00000000-0000-0000-0000-0000000051C0")!

    func testDenseRapFixtureAnalyzesAndCharts() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sickomode-like-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = SignalFixtures.sickoModeLike()
        try AudioAnalyzerIntegrationTests.writeWAVPublic(samples, sampleRate: 44100, to: url)

        let analysis: AudioAnalysis
        do {
            analysis = try await AudioAnalyzer().analyze(url: url)
        } catch {
            let ns = error as NSError
            XCTFail("analyzer threw: \(error) | domain=\(ns.domain) code=\(ns.code)")
            return
        }

        // Stage 1 — tempo: the trap section dominates, so the estimate must
        // land in the trap range (155 BPM, or the half-time switch at 140).
        if let bpm = analysis.tempoBPM {
            XCTAssertTrue((130...170).contains(bpm), "tempo \(bpm) outside expected trap range")
        } else {
            XCTFail("tempo stage failed on dense rap material")
        }
        XCTAssertGreaterThan(analysis.tempoConfidence ?? 0, 0.2)

        // Stage 2 — beats: a 92 s song at ~2.5 beats/s yields ~220 beats.
        XCTAssertGreaterThan(analysis.beats.count, 80, "beat stage found too few beats")

        // Stage 3 — events: sixteenths + kick/clap + vocals ≈ 1000 onsets.
        XCTAssertGreaterThan(analysis.events.count, 150, "event stage found too few events")
        XCTAssertGreaterThan(analysis.sections.count, 0)

        // Stage 4 — chart: every difficulty on the REAL analysis output must
        // produce a valid, validator-clean chart (no song-level failure).
        for difficulty in DifficultyLevel.allCases {
            let request = ChartGenerator.Request(difficulty: difficulty, densityMultiplier: 1.0, seed: 0x5EED)
            let output = try await ChartGenerator().generate(analysis: analysis,
                                                             songID: songID, request: request)
            XCTAssertGreaterThan(output.chart.notes.count, 20, "\(difficulty) chart too sparse")
            XCTAssertGreaterThanOrEqual(output.fallbackTier, 1)
            XCTAssertLessThanOrEqual(output.fallbackTier, 4)
            let validation = ChartValidator.validate(output.chart.notes,
                                                     constraints: ChartConstraints.forDifficulty(difficulty, densityMultiplier: 1.0))
            XCTAssertEqual(validation.hardFailureCount, 0, "\(difficulty): \(validation.hardFailures)")
        }

        // Determinism: identical analysis + seed → identical chart.
        let request = ChartGenerator.Request(difficulty: .expert, densityMultiplier: 1.0, seed: 0x5EED)
        let a = try await ChartGenerator().generate(analysis: analysis, songID: songID, request: request)
        let b = try await ChartGenerator().generate(analysis: analysis, songID: songID, request: request)
        XCTAssertEqual(a.chart.notes, b.chart.notes)
        XCTAssertEqual(a.fallbackTier, b.fallbackTier)
    }

    /// The chart must be MUSICAL on this material too: the sixteenth-note
    /// hat rolls must not be transcribed wholesale (10+ notes/s).
    func testDenseRapChartDoesNotBecomeAnOnsetDump() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sickomode-dense-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = SignalFixtures.sickoModeLike()
        try AudioAnalyzerIntegrationTests.writeWAVPublic(samples, sampleRate: 44100, to: url)
        let analysis = try await AudioAnalyzer().analyze(url: url)

        let request = ChartGenerator.Request(difficulty: .expert, densityMultiplier: 1.0, seed: 0x5EED)
        let output = try await ChartGenerator().generate(analysis: analysis, songID: songID, request: request)
        let nps = Double(output.chart.notes.count) / max(analysis.duration, 1)
        XCTAssertLessThan(nps, 9.0, "expert chart transcribes too much: \(nps) notes/s")
        // Both musical halves must be covered (notes past the beat switch).
        XCTAssertTrue(output.chart.notes.contains { $0.time > 62 }, "beat-switch section has no notes")
    }
}