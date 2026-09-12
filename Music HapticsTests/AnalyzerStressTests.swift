import AVFoundation
import XCTest
@testable import Music_Haptics

/// Analyzer stress coverage: long tracks, unusual tempos, dense/sparse
/// percussion, stereo, and non-44.1 kHz sample rates. The analyzer must not
/// fail (or silently drop stages) because of sample-rate-relative assumptions
/// or rate/format edge cases.
final class AnalyzerStressTests: XCTestCase {
    private let songID = UUID(uuidString: "00000000-0000-0000-0000-0000000057A5")!

    private func analyze(_ samples: [Float], channels: Int = 1, sampleRate: Double,
                         file: StaticString = #filePath, line: UInt = #line) async throws -> AudioAnalysis {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stress-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        if channels == 1 {
            try AudioAnalyzerIntegrationTests.writeWAVPublic(samples, sampleRate: sampleRate, to: url)
        } else {
            try AudioAnalyzerIntegrationTests.writeMultichannelWAVPublic(samples, channels: channels,
                                                                         sampleRate: sampleRate, to: url)
        }
        do {
            return try await AudioAnalyzer().analyze(url: url)
        } catch {
            let ns = error as NSError
            XCTFail("analyzer threw: \(error) | domain=\(ns.domain) code=\(ns.code)", file: file, line: line)
            throw error
        }
    }

    private func interleave(_ left: [Float], _ right: [Float]) -> [Float] {
        precondition(left.count == right.count)
        var out = [Float](); out.reserveCapacity(left.count * 2)
        for i in left.indices { out.append(left[i]); out.append(right[i]) }
        return out
    }

    // MARK: - Long stereo track at 48 kHz

    /// 5-minute stereo 48 kHz metronome: the streaming pipeline must handle
    /// ~29M samples without failing or unbounded memory (only flux/RMS/bands
    /// are retained — never the waveform).
    func testFiveMinuteStereo48kTrackAnalyzes() async throws {
        let samples = SignalFixtures.metronome(bpm: 120, seconds: 300, sampleRate: 48000)
        let stereo = interleave(samples, samples.map { $0 * 0.7 })
        let analysis = try await analyze(stereo, channels: 2, sampleRate: 48000)
        XCTAssertEqual(analysis.duration, 300, accuracy: 1.5)
        XCTAssertEqual(analysis.tempoBPM ?? 0, 120, accuracy: 6)
        XCTAssertGreaterThan(analysis.beats.count, 200)
        XCTAssertGreaterThan(analysis.events.count, 100)
        XCTAssertEqual(analysis.waveform.count, 512)
    }

    // MARK: - Low sample rates (fixed duration-relative guards)

    /// 8 kHz mono, 4 s, 4 sparse clicks: 63 hops is < the old raw-count
    /// guards (64/256) at this rate, so every analysis stage used to fail.
    /// Now the guards are duration-relative and the song must analyze.
    func testEightKilohertzSparseTrackAnalyzes() async throws {
        let sampleRate = 8000.0
        var samples = [Float](repeating: 0, count: Int(sampleRate * 4))
        for t in [0.0, 1.0, 2.0, 3.0] {
            let start = Int(t * sampleRate)
            for i in 0..<Int(0.03 * sampleRate) where start + i < samples.count {
                samples[start + i] = Float(sin(2 * .pi * 1000 * Double(i) / sampleRate)) * 0.8
            }
        }
        let analysis = try await analyze(samples, sampleRate: sampleRate)
        XCTAssertEqual(analysis.duration, 4, accuracy: 0.2)
        XCTAssertGreaterThan(analysis.events.count, 0, "sparse low-rate song must still produce events")
        // And it must chart.
        let request = ChartGenerator.Request(difficulty: .medium, densityMultiplier: 1.0, seed: 7)
        let output = try await ChartGenerator().generate(analysis: analysis, songID: songID, request: request)
        XCTAssertGreaterThan(output.chart.notes.count, 0)
        let validation = ChartValidator.validate(output.chart.notes,
                                                 constraints: ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0))
        XCTAssertEqual(validation.hardFailureCount, 0, "\(validation.hardFailures)")
    }

    /// 16 kHz mono metronome — half the usual rate must behave identically.
    func testSixteenKilohertzTrackAnalyzes() async throws {
        let samples = SignalFixtures.metronome(bpm: 100, seconds: 12, sampleRate: 16000)
        let analysis = try await analyze(samples, sampleRate: 16000)
        XCTAssertEqual(analysis.tempoBPM ?? 0, 100, accuracy: 8)
        XCTAssertGreaterThan(analysis.events.count, 10)
    }

    // MARK: - Unusual tempos

    /// 220 BPM (peak sits on the minLag boundary of the tempo search range —
    /// previously excluded by the half-open peak loop).
    func testVeryFastTempoAt220BPM() async throws {
        let samples = SignalFixtures.metronome(bpm: 220, seconds: 20)
        let analysis = try await analyze(samples, sampleRate: 44100)
        let bpm = analysis.tempoBPM ?? 0
        XCTAssertGreaterThan(bpm, 0)
        XCTAssertTrue((105...230).contains(bpm), "tempo \(bpm) — expected ~220 (or its musical half)")
        XCTAssertGreaterThan(analysis.beats.count, 15)
    }

    /// 40 BPM (peak sits on the maxLag boundary — previously excluded).
    func testVerySlowTempoAt40BPM() async throws {
        let samples = SignalFixtures.metronome(bpm: 40, seconds: 40)
        let analysis = try await analyze(samples, sampleRate: 44100)
        let bpm = analysis.tempoBPM ?? 0
        XCTAssertGreaterThan(bpm, 0)
        XCTAssertTrue((35...90).contains(bpm), "tempo \(bpm) — expected ~40 (or its musical double)")
        XCTAssertGreaterThan(analysis.beats.count, 10)
        // Charts cleanly at the resolved tempo.
        let request = ChartGenerator.Request(difficulty: .easy, densityMultiplier: 1.0, seed: 7)
        let output = try await ChartGenerator().generate(analysis: analysis, songID: songID, request: request)
        let validation = ChartValidator.validate(output.chart.notes,
                                                 constraints: ChartConstraints.forDifficulty(.easy, densityMultiplier: 1.0))
        XCTAssertEqual(validation.hardFailureCount, 0, "\(validation.hardFailures)")
    }

    // MARK: - Sparse vs dense at a high rate

    /// Sparse percussion at 96 kHz: slow clicks with long gaps must survive
    /// the adaptive-threshold onset stage and still chart.
    func testSparsePercussionAt96kHz() async throws {
        let sampleRate = 96000.0
        var samples = [Float](repeating: 0, count: Int(sampleRate * 30))
        var t = 0.0
        var i = 0
        while t < 30 {
            let start = Int(t * sampleRate)
            for j in 0..<Int(0.05 * sampleRate) where start + j < samples.count {
                let phase = Double(j) / sampleRate
                samples[start + j] = Float(sin(2 * .pi * 1500 * phase)) * Float(exp(-phase * 60)) * 0.9
            }
            t += (i % 2 == 0) ? 2.0 : 1.0     // irregular but musical-ish spacing
            i += 1
        }
        let analysis = try await analyze(samples, sampleRate: sampleRate)
        XCTAssertGreaterThan(analysis.events.count, 5)
        let request = ChartGenerator.Request(difficulty: .medium, densityMultiplier: 1.0, seed: 7)
        let output = try await ChartGenerator().generate(analysis: analysis, songID: songID, request: request)
        XCTAssertGreaterThan(output.chart.notes.count, 0)
        XCTAssertLessThanOrEqual(output.fallbackTier, 4)
    }

    /// Dense percussion at 96 kHz: a sixteenth-note click train (~10/s, 150
    /// clicks) must not overwhelm the onset stage or the event cap.
    func testDensePercussionAt96kHz() async throws {
        let sampleRate = 96000.0
        var samples = [Float](repeating: 0, count: Int(sampleRate * 15))
        for i in 0..<150 {   // sixteenths at 150 BPM, integer index — no float drift
            let start = Int(Double(i) * 0.1 * sampleRate)
            for j in 0..<Int(0.02 * sampleRate) where start + j < samples.count {
                let phase = Double(j) / sampleRate
                samples[start + j] = Float(sin(2 * .pi * 7000 * phase)) * Float(exp(-phase * 200)) * 0.7
            }
        }
        let analysis = try await analyze(samples, sampleRate: sampleRate)
        XCTAssertTrue((130...165).contains(analysis.tempoBPM ?? 0), "tempo \(analysis.tempoBPM ?? 0)")
        XCTAssertGreaterThan(analysis.events.count, 100, "dense 96 kHz percussion lost events")
    }
}