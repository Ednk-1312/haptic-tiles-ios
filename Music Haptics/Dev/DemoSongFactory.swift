import Foundation

/// Built-in synthetic demo song: a ~28 s, 120 BPM energetic groove (kick,
/// snare, hats, bassline, chord stabs) synthesized straight to a 16-bit WAV in
/// the app's sandbox. Lets the game be demoed end-to-end in the Simulator —
/// real analysis, real chart, real audio clock, real autoplay — without a
/// personal music library.
enum DemoSongFactory {
    // v2: adds a mid-song breakdown (bars 9–10) and a soft outro (bar 14) so
    // the section detector finds real quiet material and generated charts
    // demonstrate rests / section-aware density in autoplay.
    static let fileName = "DemoSong-v2.wav"
    static let duration = 28.0

    /// Returns the cached demo WAV or creates it off the main actor.
    /// The sample buffer is intentionally built in a detached task: generating
    /// 28 seconds of PCM is real CPU work and must never block the home screen.
    static func writeIfNeededAsync(to directory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try writeIfNeeded(to: directory)
        }.value
    }

    /// Synchronous worker used only from the detached generation task.
    static func writeIfNeeded(to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try write(to: url)
        return url
    }

    static func write(to url: URL) throws {
        let sampleRate = 44100
        let totalSamples = Int(duration * Double(sampleRate))
        var samples = [Double](repeating: 0, count: totalSamples)
        var rng = SplitMix64(state: 0xDEAD_BEEF)

        func add(_ buffer: inout [Double], from t0: Double, length: Double,
                 _ wave: (Double) -> Double) {
            let start = max(0, Int(t0 * Double(sampleRate)))
            let end = min(buffer.count, Int((t0 + length) * Double(sampleRate)))
            guard start < end else { return }
            for i in start..<end {
                let t = Double(i) / Double(sampleRate) - t0
                buffer[i] += wave(t)
            }
        }

        let bpm = 120.0
        let beat = 60.0 / bpm
        let bars = 14

        func kick(_ t0: Double) {
            add(&samples, from: t0, length: 0.30) { t in
                sin(2 * .pi * (48 + 42 * exp(-t * 32)) * t) * exp(-t * 16) * 0.95
            }
        }
        func snare(_ t0: Double) {
            add(&samples, from: t0, length: 0.25) { t in
                let noise = (rng.uniform() * 2 - 1)
                return (noise * exp(-t * 20) * 0.55) + (sin(2 * .pi * 185 * t) * exp(-t * 28) * 0.35)
            }
        }
        func hat(_ t0: Double) {
            add(&samples, from: t0, length: 0.09) { t in
                (rng.uniform() * 2 - 1) * exp(-t * 85) * 0.22
            }
        }
        let bassRiff: [Double] = [110, 110, 130.81, 98, 110, 110, 146.83, 130.81]
        func bass(_ t0: Double, eighth: Int) {
            let f = bassRiff[eighth % bassRiff.count]
            add(&samples, from: t0, length: 0.42) { t in
                (sin(2 * .pi * f * t) + 0.35 * sin(2 * .pi * f * 2 * t)) * exp(-t * 7) * 0.34
            }
        }
        let chords: [[Double]] = [
            [220.0, 261.63, 329.63],      // Am
            [174.61, 220.0, 261.63],      // F
            [261.63, 329.63, 392.0],      // C
            [196.0, 246.94, 293.66]       // G
        ]
        func stab(_ t0: Double, chord: [Double]) {
            add(&samples, from: t0, length: 0.55) { t in
                chord.reduce(0) { $0 + sin(2 * .pi * $1 * t) } * exp(-t * 5) * 0.16
            }
        }

        for bar in 0..<bars {
            let isBreakdown = (9...10).contains(bar)   // quiet middle section
            let isOutro = bar == 13                    // sparse ending
            for b in 0..<4 {
                let t0 = Double(bar) * 4 * beat + Double(b) * beat
                if isBreakdown || isOutro {
                    // Breakdown/outro: sparse pulse only — kick (+ bass) on
                    // downbeats, everything else drops out.
                    if b % 4 == 0 {
                        kick(t0)
                        if !isOutro { bass(t0, eighth: b * 2) }
                    }
                    continue
                }
                kick(t0)
                if b % 4 == 1 || b % 4 == 3 { snare(t0) }
                if bar >= 1, b == 0 { stab(t0, chord: chords[bar % chords.count]) }
                for e in 0..<2 {
                    hat(t0 + Double(e) * beat / 2)
                    bass(t0 + Double(e) * beat / 2, eighth: b * 2 + e)
                }
            }
        }

        // Soft clip + normalize headroom.
        let peak = samples.map { abs($0) }.max() ?? 1
        let scale = min(1, 0.92 / max(peak, 0.001))
        var data = Data(capacity: 44 + samples.count * 2)
        func le16(_ v: Int16) { data.append(UInt8(truncatingIfNeeded: v & 0xFF)); data.append(UInt8(truncatingIfNeeded: (v >> 8) & 0xFF)) }
        func le32(_ v: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) {
                data.append(UInt8(truncatingIfNeeded: (v >> shift) & 0xFF))
            }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        le32(16)
        le16(1)                       // PCM
        le16(1)                       // mono
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * 2))  // byte rate
        le16(2)                       // block align
        le16(16)                      // bits
        data.append(contentsOf: Array("data".utf8))
        le32(UInt32(samples.count * 2))
        for s in samples {
            le16(Int16(max(-1, min(1, s * scale)) * Double(Int16.max)))
        }
        try data.write(to: url)
    }
}