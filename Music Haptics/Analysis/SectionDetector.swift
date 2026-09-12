import Foundation

/// Detects broad energy-based sections (intro, verse, chorus, ...).
/// Labels are heuristics — useful for density shaping, not musical truth.
enum SectionDetector {
    static func detect(rms: [Float], hopTime: Double, duration: Double) -> [SongSection] {
        let n = rms.count
        guard n > 8 else { return [] }

        // 1-second buckets of average energy.
        let bucketHops = max(1, Int((1.0 / hopTime).rounded()))
        var buckets: [Float] = []
        var idx = 0
        while idx < n {
            let end = min(n, idx + bucketHops)
            var sum: Float = 0
            for k in idx..<end { sum += rms[k] }
            buckets.append(sum / Float(end - idx))
            idx += bucketHops
        }

        // Smooth with a 5-second moving average.
        let smoothHops = 5
        var smoothed = buckets
        var total: Float = 0
        for i in 0..<buckets.count {
            total += buckets[i]
            if i >= smoothHops { total -= buckets[i - smoothHops] }
            smoothed[i] = total / Float(min(i + 1, smoothHops))
        }

        // Boundaries where energy changes a lot relative to its spread. Compare
        // against the value ~half the smoothing window back (2-3 s), not the
        // adjacent bucket: a 5 s smoothing window smears a real transition
        // across several buckets, so adjacent-bucket deltas stay under any
        // sane threshold and quiet sections are never found.
        let sorted = smoothed.sorted()
        let p10 = sorted[max(0, Int(Double(sorted.count) * 0.1) - 1)]
        let p90 = sorted[max(0, Int(Double(sorted.count) * 0.9) - 1)]
        let range = max(p90 - p10, 0.01)
        let lookback = max(1, smoothHops / 2)
        var boundaries: [Int] = []
        for i in lookback..<smoothed.count {
            if abs(smoothed[i] - smoothed[i - lookback]) > range * 0.32 {
                boundaries.append(i)
            }
        }

        // Merge boundaries closer than a song-length-scaled window, so a short
        // quiet passage (breakdown/break) in a short song still survives.
        let mergeDistance = min(8.0, max(2.5, duration * 0.10))
        var merged: [Int] = []
        for b in boundaries {
            if let last = merged.last, Double(b - last) < mergeDistance { continue }
            merged.append(b)
        }

        // Build sections.
        let median = smoothed.sorted()[smoothed.count / 2]
        var sections: [SongSection] = []
        var startBucket = 0
        for (pos, boundary) in merged.enumerated() {
            sections.append(makeSection(index: pos, startBucket: startBucket, endBucket: boundary,
                                        buckets: smoothed, median: median, isLast: false))
            startBucket = boundary
        }
        sections.append(makeSection(index: merged.count, startBucket: startBucket, endBucket: smoothed.count,
                                    buckets: smoothed, median: median, isLast: true))

        // Normalize energies so section factors are comparable across songs.
        let maxE = sections.map(\.energy).max() ?? 1
        for i in sections.indices {
            sections[i].energy /= maxE > 0 ? maxE : 1
        }
        return sections
    }

    private static func makeSection(index: Int, startBucket: Int, endBucket: Int,
                                    buckets: [Float], median: Float, isLast: Bool) -> SongSection {
        let e = buckets[startBucket..<endBucket].reduce(0, +) / Float(max(1, endBucket - startBucket))
        let label: SectionLabel
        if index == 0 {
            label = .intro
        } else if isLast {
            // Only a genuinely quiet ending is an outro; an energetic final
            // section stays a chorus (so final-chorus density is not gutted).
            label = e < median * 0.85 ? .outro : .chorus
        } else if e > median * 1.15 {
            label = .chorus
        } else if e < median * 0.85 {
            label = .breakdown
        } else {
            label = .verse
        }
        return SongSection(index: index, start: Double(startBucket), end: Double(endBucket),
                           label: label, energy: Double(e))
    }
}