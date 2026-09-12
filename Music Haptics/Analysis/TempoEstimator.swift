import Accelerate
import Foundation

struct TempoEstimate: Sendable {
    var bpm: Double
    var confidence: Double
}

/// Estimates tempo from the spectral-flux envelope via autocorrelation.
///
/// Octave ambiguity (70 vs 140 BPM) is resolved with a musical prior:
/// everything else equal, the estimate in the human-music range (~80–190 BPM)
/// wins.
enum TempoEstimator {
    static func estimate(flux: [Float], hopTime: Double) -> TempoEstimate {
        let n = flux.count
        // Duration-relative guard (not a raw hop count): at 8 kHz a hop is
        // 64 ms, so 256 hops would silently demand 16 s of audio while the
        // analyzer accepts 3 s files at any rate.
        guard n > 16, Double(n) * hopTime >= 1.0, hopTime > 0 else { return TempoEstimate(bpm: 0, confidence: 0) }

        // Reject near-silent signals.
        var totalEnergy: Float = 0
        vDSP_measqv(flux, 1, &totalEnergy, vDSP_Length(n))
        guard totalEnergy > 1e-8 else { return TempoEstimate(bpm: 0, confidence: 0) }

        let minBPM = 40.0
        let maxBPM = 220.0
        let minLag = max(2, Int((60.0 / maxBPM / hopTime).rounded()))
        let maxLag = min(n - 2, Int((60.0 / minBPM / hopTime).rounded()))
        guard maxLag > minLag else { return TempoEstimate(bpm: 0, confidence: 0) }

        // Mean-center so the ACF measures shape, not level.
        var mean: Float = 0
        vDSP_meanv(flux, 1, &mean, vDSP_Length(n))
        let centered = flux.map { $0 - mean }

        // Autocorrelation over the lag range corresponding to 40–220 BPM.
        let centeredD = centered.map { Double($0) }
        var acf = [Double](repeating: 0, count: maxLag + 1)
        centeredD.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            // The ACF is the dominant analysis cost (seconds in Debug on long
            // songs). Be cooperative: bail out promptly when the surrounding
            // task is cancelled — the analyzer checks cancellation right
            // after this call and unwinds. The invalid estimate never lands.
            for lag in minLag...maxLag {
                if lag % 256 == 0, Task.isCancelled {
                    return
                }
                vDSP_dotprD(base, 1, base + lag, 1, &acf[lag], vDSP_Length(n - lag))
            }
        }
        let acf0 = max(acf[minLag], 1e-12)
        for lag in minLag...maxLag { acf[lag] /= acf0 }

        // Collect local maxima (peaks) in the valid lag range.
        struct Candidate {
            var lag: Int
            var value: Double
            var bpm: Double
        }
        var candidates: [Candidate] = []
        // Inclusive edges: a real peak can sit exactly ON the range boundary
        // (40 BPM → the maxLag edge, 220 BPM → the minLag edge).
        for lag in minLag...maxLag {
            let leftOK = lag == minLag || acf[lag] > acf[lag - 1]
            let rightOK = lag == maxLag || acf[lag] >= acf[lag + 1]
            if leftOK && rightOK {
                candidates.append(Candidate(lag: lag, value: acf[lag], bpm: 60.0 / (Double(lag) * hopTime)))
            }
        }
        guard let best = candidates.max(by: { $0.value < $1.value }) else {
            return TempoEstimate(bpm: 0, confidence: 0)
        }
        if ProcessInfo.processInfo.environment["TEMPO_LOG"] != nil {
            let top = candidates.sorted { $0.value > $1.value }.prefix(12)
                .map { String(format: "%.2fbpm@%.3f", $0.bpm, $0.value) }.joined(separator: " ")
            FileHandle.standardError.write("TEMPO top: \(top)\n".data(using: .utf8)!)
            let musical = candidates.filter { (80...190).contains($0.bpm) && $0.value >= best.value * 0.5 }
            for c in musical.sorted(by: { $0.value > $1.value }) {
                var parts = ""
                for k in 1...4 where k * c.lag <= maxLag {
                    parts += String(format: " k%d=%.3f", k, acf[k * c.lag])
                }
                FileHandle.standardError.write(String(format: "TEMPO mus %.2fbpm lag=%d val=%.3f score=%.3f%@\n",
                                                      c.bpm, c.lag, c.value, harmonicScore(lag: c.lag, acf: acf, maxLag: maxLag), parts)
                    .data(using: .utf8)!)
            }
        }

        // Tempo resolution. When the raw ACF peak is a sub- or super-harmonic
        // (dense trap/rap flux envelopes frequently peak at 2×–4× sub-harmonics
        // — hop-quantized sixteenth rolls and beat-switch sections favored
        // e.g. 155 → 51.7 BPM), the true tempo is usually a WEAKER single peak
        // but the strongest harmonic family. Re-rank musical-range candidates
        // by harmonic support Σ ACF[k·L]/k instead of raw peak value.
        var chosen = best
        if best.bpm < 60 || best.bpm > 190 {
            let musical = candidates.filter { (80...190).contains($0.bpm) && $0.value >= best.value * 0.5 }
            if let winner = musical.max(by: {
                harmonicScore(lag: $0.lag, acf: acf, maxLag: maxLag) < harmonicScore(lag: $1.lag, acf: acf, maxLag: maxLag)
                    || (harmonicScore(lag: $0.lag, acf: acf, maxLag: maxLag) == harmonicScore(lag: $1.lag, acf: acf, maxLag: maxLag)
                        && $0.value < $1.value)
            }) {
                chosen = winner
            }
        }

        // Baseline = median ACF in range; confidence = how far the peak stands out.
        let sorted = acf[minLag...maxLag].sorted()
        let median = sorted[sorted.count / 2]
        let confidence = min(1.0, max(0.0, (chosen.value - median) / max(1 - median, 0.05)))
        return TempoEstimate(bpm: chosen.bpm, confidence: confidence)
    }

    /// Harmonic support of a lag: the ACF at the lag plus its in-range
    /// integer multiples (weighted 1/k). A true tempo's family of peaks
    /// out-scores a single strong sub-harmonic. Each multiple is sampled with
    /// a ±1-hop window: hop-quantized flux (fractional hop periods, e.g.
    /// 33.35 hops/beat) puts the real peak one hop away from the exact
    /// integer multiple — lag 99 can be a trough while lag 100 is the peak.
    private static func harmonicScore(lag: Int, acf: [Double], maxLag: Int) -> Double {
        var score = 0.0
        for k in 1...4 {
            let l = k * lag
            guard l <= maxLag else { break }
            var peak = acf[l]
            if l > 0 { peak = max(peak, acf[l - 1]) }
            if l < maxLag { peak = max(peak, acf[l + 1]) }
            score += peak / Double(k)
        }
        return score
    }
}