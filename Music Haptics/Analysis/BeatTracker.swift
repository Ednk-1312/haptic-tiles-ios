import Foundation

struct BeatTrack: Sendable {
    var beats: [Beat]
    var reliable: Bool
}

/// Turns tempo + onset envelope into beat positions.
///
/// Strategy: pick the beat phase that maximizes onset energy, lay down a
/// regular grid, then locally snap each beat toward the nearest strong onset
/// (musical tolerance ≈ 1/3 beat). One pass keeps this simple and robust.
enum BeatTracker {
    static func track(flux: [Float], hopTime: Double, bpm: Double, confidence: Double) -> BeatTrack {
        let n = flux.count
        // Duration-relative guard (not a raw hop count): 64 hops is 0.74 s at
        // 44.1 kHz but 4.1 s at 8 kHz — the analyzer accepts 3 s files at any
        // rate, so low-rate files must not silently lose their beat stage.
        guard n > 8, Double(n) * hopTime >= 0.5, bpm > 20, bpm < 300, hopTime > 0 else {
            return BeatTrack(beats: [], reliable: false)
        }
        let period = 60.0 / bpm / hopTime          // hops per beat
        guard period >= 3 else { return BeatTrack(beats: [], reliable: false) }
        let stepHops = max(1, Int(period.rounded()))

        // 1) Phase search: which grid offset aligns with the most onset energy?
        var bestPhase = 0
        var bestScore = -Double.infinity
        let phaseStep = max(1, stepHops / 16)
        var phase = 0
        while phase < stepHops {
            var score = 0.0
            var k = phase
            while k < n {
                score += Double(flux[k])
                k += stepHops
            }
            if score > bestScore { bestScore = score; bestPhase = phase }
            phase += phaseStep
        }

        // 2) Grid + local snapping toward strong onsets.
        var refined: [Double] = []
        var t = Double(bestPhase) * hopTime
        let search = max(1, Int(period * 0.33))
        while t < Double(n) * hopTime {
            let idx = min(n - 1, max(0, Int(t / hopTime)))
            var best = idx
            var bestV = flux[idx]
            for j in max(0, idx - search)...min(n - 1, idx + search) {
                if flux[j] > bestV { bestV = flux[j]; best = j }
            }
            refined.append(Double(best) * hopTime)
            t += Double(stepHops) * hopTime
        }

        // 3) Dedupe beats that snapped to the same onset (period is in hops,
        //    so convert the minimum gap to seconds before comparing). The
        //    absolute 0.09 s floor merges double-beat artifacts (a tempo
        //    misdetected at 2× real speed) — without it the chart grid can
        //    degenerate below the validator's minimum spacing and every
        //    candidate arrangement fails.
        let minGap = max(period * 0.55 * hopTime, 0.09)
        var beats: [Beat] = []
        for time in refined {
            if let last = beats.last, time - last.time < minGap { continue }
            beats.append(Beat(time: time, strength: 0, isStrong: false))
        }

        // 4) Strengths: normalized onset energy at each beat.
        let window = max(1, Int(period * 2.2))
        var strengths: [Double] = []
        for beat in beats {
            let idx = min(n - 1, max(0, Int(beat.time / hopTime)))
            var localMax: Float = 0
            for j in max(0, idx - window)...min(n - 1, idx + window) {
                localMax = max(localMax, flux[j])
            }
            strengths.append(localMax > 0 ? Double(flux[idx]) / Double(localMax) : 0)
        }

        var result = zip(beats, strengths).map { beat, strength in
            Beat(time: beat.time, strength: strength, isStrong: strength >= 0.62)
        }
        // Also mark the strongest beat of each 4-beat group (downbeat-ish).
        var i = 0
        while i < result.count {
            let groupEnd = min(result.count - 1, i + 3)
            if let maxIdx = (i...groupEnd).max(by: { result[$0].strength < result[$1].strength }),
               result[maxIdx].strength >= 0.45 {
                result[maxIdx].isStrong = true
            }
            i += 4
        }

        let reliable = confidence >= 0.3 && result.count >= 4
        return BeatTrack(beats: result, reliable: reliable)
    }
}