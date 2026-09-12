import AVFoundation
import XCTest
@testable import Music_Haptics

/// End-to-end test: write a synthetic metronome WAV, analyze it, check results.
final class AudioAnalyzerIntegrationTests: XCTestCase {
    func testAnalyzerFindsTempoAndBeatsOnSyntheticWAV() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metronome-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = SignalFixtures.metronome(bpm: 120, seconds: 12)
        try Self.writeWAV(samples, channels: 1, sampleRate: 44100, to: url)

        let analysis: AudioAnalysis
        do {
            analysis = try await AudioAnalyzer().analyze(url: url)
        } catch {
            let ns = error as NSError
            XCTFail("analyzer threw: \(error) | domain=\(ns.domain) code=\(ns.code)")
            return
        }
        XCTAssertNotNil(analysis.tempoBPM)
        XCTAssertEqual(analysis.tempoBPM ?? 0, 120, accuracy: 8)
        XCTAssertGreaterThan(analysis.tempoConfidence ?? 0, 0.3)
        XCTAssertGreaterThan(analysis.beats.count, 8, "expected roughly one beat per 0.5s")
        XCTAssertGreaterThan(analysis.onsets.count, 8)
        XCTAssertGreaterThan(analysis.events.count, 8)
        XCTAssertEqual(analysis.duration, 12, accuracy: 0.5)
    }

    func testAnalyzerRejectsMissingFile() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing.wav")
        do {
            _ = try await AudioAnalyzer().analyze(url: url)
            XCTFail("expected an error for a missing file")
        } catch {
            // expected
        }
    }

    static func writeWAVPublic(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        try writeWAV(samples, channels: 1, sampleRate: sampleRate, to: url)
    }

    /// Minimal 16-bit PCM WAV writer for stress fixtures (mono or interleaved
    /// multi-channel, any sample rate) — self-contained, no AVFoundation.
    static func writeMultichannelWAVPublic(_ samples: [Float], channels: Int,
                                           sampleRate: Double, to url: URL) throws {
        try writeWAV(samples, channels: channels, sampleRate: sampleRate, to: url)
    }

    private static func writeWAV(_ samples: [Float], channels: Int, sampleRate: Double, to url: URL) throws {
        let frameCount = samples.count / channels
        let bytesPerSample = 2 // 16-bit
        let blockAlign = channels * bytesPerSample
        let dataSize = frameCount * blockAlign
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(contentsOf: littleEndian(UInt32(36 + dataSize)))
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        header.append(contentsOf: littleEndian(UInt32(16)))          // fmt chunk size
        header.append(contentsOf: littleEndian(UInt16(1)))           // PCM
        header.append(contentsOf: littleEndian(UInt16(channels)))
        header.append(contentsOf: littleEndian(UInt32(sampleRate)))
        header.append(contentsOf: littleEndian(UInt32(sampleRate * Double(blockAlign)))) // byte rate
        header.append(contentsOf: littleEndian(UInt16(blockAlign)))
        header.append(contentsOf: littleEndian(UInt16(16)))          // bits
        header.append(contentsOf: Array("data".utf8))
        header.append(contentsOf: littleEndian(UInt32(dataSize)))
        var body = Data(capacity: dataSize)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32767)
            body.append(contentsOf: littleEndian(value))
        }
        var data = header
        data.append(body)
        try data.write(to: url)
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var v = value
        return withUnsafeBytes(of: &v) { Array($0) }
    }
}