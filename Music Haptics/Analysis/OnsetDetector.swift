import Foundation

/// Detects musical onsets from the spectral-flux envelope using an adaptive
/// threshold. Not every peak becomes a note — chart generation decides that.
enum OnsetDetector {
    /// - Parameters:
    ///   - flux: per-hop spectral flux.
    ///   - hopTime: seconds per hop.
    ///   - minSeparation: minimum seconds between onsets (merges double-detections).
    ///   - thresholdFactor: adaptive-threshold multiplier (1.3–1.6 works well).
    static func detect(flux: [Float], hopTime: Double,
                       minSeparation: Double = 0.06,
                       thresholdFactor: Float = 1.4) -> [OnsetEvent] {
        let n = flux.count
        guard n > 8, hopTime > 0 else { return [] }

        // Moving average of flux over ~1 second → adaptive baseline.
        let winHops = max(8, Int((1.0 / hopTime).rounded()))
        var baseline = [Float](repeating: 0, count: n)
        var sum: Float = 0
        for i in 0..<n {
            sum += flux[i]
            if i >= winHops { sum -= flux[i - winHops] }
            baseline[i] = sum / Float(min(i + 1, winHops))
        }

        // Floor so near-silence sections don't produce noise onsets.
        let sorted = flux.sorted()
        let p95 = sorted[max(0, Int(Double(n) * 0.95) - 1)]
        let floor = max(p95 * 0.2, 0.0005)

        let sepHops = max(1, Int((minSeparation / hopTime).rounded()))
        var events: [OnsetEvent] = []
        for i in 1..<(n - 1) {
            guard flux[i] > baseline[i] * thresholdFactor, flux[i] > floor else { continue }
            // Local maximum within ±sepHops. Strict comparison so a plateau of
            // equal peaks still fires once (the dedupe below merges them).
            var isPeak = true
            for j in max(0, i - sepHops)...min(n - 1, i + sepHops) where j != i {
                if flux[j] > flux[i] { isPeak = false; break }
            }
            guard isPeak else { continue }

            // Dedupe: merge peaks closer than minSeparation (keep the first).
            if let last = events.last, Double(i) * hopTime - last.time < minSeparation {
                continue
            }

            // Confidence from prominence above the local baseline.
            let localMax = max(baseline[i], 1e-6)
            let confidence = Float(min(1, max(0, Double((flux[i] - baseline[i]) / (localMax * 2)))))
            events.append(OnsetEvent(time: Double(i) * hopTime, strength: flux[i], confidence: confidence))
        }
        return events
    }
}