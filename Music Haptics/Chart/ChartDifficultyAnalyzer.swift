import Foundation

/// Objective, reproducible difficulty measurement from chart features.
enum ChartDifficultyAnalyzer {
    static func analyze(notes: [ChartNote], duration: Double) -> DifficultyMetrics {
        let sorted = notes.sorted { $0.time < $1.time }
        let count = sorted.count
        guard !sorted.isEmpty else {
            return DifficultyMetrics(score10: 0, label: .easy, notesPerSecond: 0,
                                     averageInterval: 0, maxBurstNPS: 0, simultaneityRatio: 0,
                                     averageJumpDistance: 0, alternationRatio: 0,
                                     intervalStdDev: 0, spikeRatio: 0, sustainedNPS: 0)
        }
        let span = max(sorted.last!.time - sorted.first!.time, 1)
        let nps = Double(count) / span
        let sustainedNPS = Double(count) / max(duration, 1)

        // Max notes in a sliding 1s window (burst measure).
        var maxWindow = 0
        var right = 0
        for left in 0..<count {
            while right < count && sorted[right].time - sorted[left].time < 1.0 { right += 1 }
            maxWindow = max(maxWindow, right - left)
        }

        // Intervals, jumps, alternation, simultaneity.
        var intervals: [Double] = []
        var jumps: [Int] = []
        var alternations = 0
        var simult = 0
        for i in 1..<count {
            let gap = sorted[i].time - sorted[i - 1].time
            if gap < 0.1 { simult += 1 }
            intervals.append(gap)
            jumps.append(abs(sorted[i].lane - sorted[i - 1].lane))
        }
        if count > 2 {
            for i in 2..<count {
                if sorted[i].lane == sorted[i - 2].lane && sorted[i].lane != sorted[i - 1].lane {
                    alternations += 1
                }
            }
        }
        let avgInterval = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.isEmpty ? 0
            : intervals.map { ($0 - avgInterval) * ($0 - avgInterval) }.reduce(0, +) / Double(intervals.count)
        let avgJump = jumps.isEmpty ? 0 : Double(jumps.reduce(0, +)) / Double(jumps.count)
        let alternationRatio = count > 2 ? Double(alternations) / Double(count - 2) : 0
        let simultRatio = count > 1 ? Double(simult) / Double(count - 1) : 0
        let spikeRatio = nps > 0.3 ? Double(maxWindow) / nps : 0

        // Weighted, normalized features → 0…10.
        let fNPS = min(1, nps / 6)
        let fBurst = min(1, Double(maxWindow) / 9)
        let fVariance = min(1, sqrt(variance) / 0.25)
        let fJump = min(1, avgJump / 2.5)
        let fSustained = min(1, sustainedNPS / 6)
        let fSpike = min(1, max(0, spikeRatio - 1.5) / 1.5)
        let fSimult = min(1, simultRatio * 4)
        let raw = 10 * (0.35 * fNPS + 0.15 * fBurst + 0.15 * fVariance + 0.10 * fJump
                        + 0.10 * fSustained + 0.10 * fSpike + 0.05 * fSimult)
        let score = min(10, max(0, raw))

        return DifficultyMetrics(
            score10: score,
            label: DifficultyLevel.level(forScore: score),
            notesPerSecond: nps,
            averageInterval: avgInterval,
            maxBurstNPS: Double(maxWindow),
            simultaneityRatio: simultRatio,
            averageJumpDistance: avgJump,
            alternationRatio: alternationRatio,
            intervalStdDev: sqrt(variance),
            spikeRatio: spikeRatio,
            sustainedNPS: sustainedNPS
        )
    }
}