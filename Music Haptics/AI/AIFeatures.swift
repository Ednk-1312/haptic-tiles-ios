import Foundation

/// Deterministic, normalized feature extraction for the on-device AI models.
///
/// Rules:
/// - Every feature is a pure function of (chart/analysis) data — no state,
///   no randomness, no SwiftUI — so training data, tests and on-device
///   inference all see identical vectors.
/// - Every feature is clamped to 0…1 (unless noted) so the models never see
///   unbounded values and normalization constants live in ONE place.
/// - Schema is versioned (`AIModelCatalog.featureSchemaVersion`); if a feature
///   is added/removed/reordered, bump the schema and retrain.
enum DifficultyFeatureExtractor {
    static let featureCount = 16

    /// Feature index constants — the training pipeline and tests refer to
    /// these by name, not by magic positions.
    enum Index: Int, CaseIterable {
        case bpm = 0, notesPerSecond, maxBurstNPS, averageInterval, minimumInterval,
             simultaneityRatio, maxSimultaneous, averageLaneJump, maximumLaneJump,
             rapidLaneChangeRate, alternationRatio, irregularity, difficultySpikes,
             sustainedNPS, duration, noteCount
    }

    /// 16 features from the generated notes + difficulty metrics + analysis.
    /// `metrics` is the deterministic `ChartDifficultyAnalyzer` output.
    static func extract(notes: [ChartNote], metrics: DifficultyMetrics, analysis: AudioAnalysis) -> [Double] {
        let sorted = notes.sorted { $0.time < $1.time }
        var f = [Double](repeating: 0, count: featureCount)

        // 1. Tempo (normalized 40…240 BPM → 0…1).
        let bpm = analysis.tempoBPM ?? 120
        f[Index.bpm.rawValue] = clamp01((bpm - 40) / 200)

        // 2–4. Density family.
        f[Index.notesPerSecond.rawValue] = clamp01(metrics.notesPerSecond / 6)
        f[Index.maxBurstNPS.rawValue] = clamp01(metrics.maxBurstNPS / 9)
        f[Index.averageInterval.rawValue] = min(1, 0.35 / max(metrics.averageInterval, 0.05))

        // 5. Tightest interval (unbounded density spike detector).
        var minInterval = Double.infinity
        if sorted.count > 1 {
            for i in 1..<sorted.count where sorted[i].time - sorted[i - 1].time > 0.001 {
                minInterval = min(minInterval, sorted[i].time - sorted[i - 1].time)
            }
        }
        f[Index.minimumInterval.rawValue] = minInterval.isFinite ? min(1, 0.35 / minInterval) : 0

        // 6–7. Simultaneity (two notes closer than 0.1 s count as simultaneous).
        var maxSimult = 0
        var right = 0
        for left in sorted.indices {
            while right < sorted.count, sorted[right].time - sorted[left].time < 0.1 { right += 1 }
            maxSimult = max(maxSimult, right - left)
        }
        f[Index.simultaneityRatio.rawValue] = clamp01(metrics.simultaneityRatio * 4)
        f[Index.maxSimultaneous.rawValue] = clamp01(Double(maxSimult) / 4)

        // 8–10. Lane movement family.
        var maxJump = 0
        var rapidChanges = 0
        var steps = 0
        if sorted.count > 1 {
            for i in 1..<sorted.count {
                let jump = abs(sorted[i].lane - sorted[i - 1].lane)
                let gap = sorted[i].time - sorted[i - 1].time
                maxJump = max(maxJump, jump)
                if gap < 0.4 && jump >= 1 { rapidChanges += 1 }
                steps += 1
            }
        }
        f[Index.averageLaneJump.rawValue] = clamp01(metrics.averageJumpDistance / 3)
        f[Index.maximumLaneJump.rawValue] = clamp01(Double(maxJump) / 3)
        f[Index.rapidLaneChangeRate.rawValue] = steps > 0 ? Double(rapidChanges) / Double(steps) : 0

        // 11–14. Complexity / spikes / sustained.
        f[Index.alternationRatio.rawValue] = clamp01(metrics.alternationRatio)
        f[Index.irregularity.rawValue] = clamp01(metrics.intervalStdDev / 0.25)
        f[Index.difficultySpikes.rawValue] = clamp01(max(0, metrics.spikeRatio - 1) / 1.5)
        f[Index.sustainedNPS.rawValue] = clamp01(metrics.sustainedNPS / 6)

        // 15–16. Scale features (long songs / huge charts are harder to sustain).
        f[Index.duration.rawValue] = clamp01(log10(max(analysis.duration, 20) / 30) / log10(6))
        f[Index.noteCount.rawValue] = clamp01(Double(sorted.count) / 1200)
        return f
    }

    static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

/// Per-candidate-event features for the event-ranking model. Context (beats,
/// sections, neighbors) is computed once per analysis, then each event gets a
/// fixed 16-feature vector.
enum EventFeatureExtractor {
    static let featureCount = 16

    enum Index: Int, CaseIterable {
        case timePosition = 0, strength, confidence, totalEnergy, lowEnergy, midEnergy,
             highEnergy, beatStrength, onBeat, beatDistance, localDensity,
             previousEventDistance, nextEventDistance, sectionEnergy,
             sectionLabelFactor, dspImportance
    }

    /// Precomputed analysis context (sorted arrays + beat interval).
    struct Context: Sendable {
        let duration: Double
        let beatTimes: [Double]
        let eventTimes: [Double]
        let sections: [SongSection]
        let beatInterval: Double
    }

    static func context(for analysis: AudioAnalysis) -> Context {
        let beatInterval: Double
        if let bpm = analysis.tempoBPM, bpm > 20, bpm < 300 {
            beatInterval = 60 / bpm
        } else if analysis.beats.count >= 2 {
            beatInterval = max(analysis.beats[1].time - analysis.beats[0].time, 0.1)
        } else {
            beatInterval = 0.5
        }
        return Context(duration: max(analysis.duration, 1),
                       beatTimes: analysis.beats.map(\.time).sorted(),
                       eventTimes: analysis.events.map(\.time).sorted(),
                       sections: analysis.sections.sorted { $0.start < $1.start },
                       beatInterval: beatInterval)
    }

    /// 16 features for one event given its index in `analysis.events`.
    static func extract(_ event: MusicalEvent, index: Int, events: [MusicalEvent], ctx: Context) -> [Double] {
        var f = [Double](repeating: 0, count: featureCount)

        f[Index.timePosition.rawValue] = min(1, max(0, event.time / ctx.duration))
        f[Index.strength.rawValue] = DifficultyFeatureExtractor.clamp01(event.strength)
        f[Index.confidence.rawValue] = DifficultyFeatureExtractor.clamp01(event.confidence)
        f[Index.totalEnergy.rawValue] = DifficultyFeatureExtractor.clamp01((event.lowEnergy + event.midEnergy + event.highEnergy) / 3)
        f[Index.lowEnergy.rawValue] = DifficultyFeatureExtractor.clamp01(event.lowEnergy)
        f[Index.midEnergy.rawValue] = DifficultyFeatureExtractor.clamp01(event.midEnergy)
        f[Index.highEnergy.rawValue] = DifficultyFeatureExtractor.clamp01(event.highEnergy)
        f[Index.beatStrength.rawValue] = DifficultyFeatureExtractor.clamp01(event.beatStrength)
        f[Index.onBeat.rawValue] = event.isOnBeat ? 1 : 0

        // Distance to nearest beat, normalized so 0 = on the beat, 1 = halfway
        // between two beats.
        if let beat = nearestBeat(to: event.time, in: ctx.beatTimes) {
            f[Index.beatDistance.rawValue] = min(1, abs(event.time - beat) / max(ctx.beatInterval * 0.5, 0.05))
        }

        // Local event density: events within ±0.5 s (excluding self).
        let window = ctx.eventTimes.filter { abs($0 - event.time) < 0.5 }.count - 1
        f[Index.localDensity.rawValue] = min(1, Double(max(0, window)) / 8)

        // Neighbor distances.
        if index > 0 {
            let prev = events[index - 1].time
            f[Index.previousEventDistance.rawValue] = min(1, 0.3 / max(event.time - prev, 0.01))
        }
        if index + 1 < events.count {
            let next = events[index + 1].time
            f[Index.nextEventDistance.rawValue] = min(1, 0.3 / max(next - event.time, 0.01))
        }

        // Section context.
        let section = ctx.sections.first { event.time >= $0.start && event.time < $0.end }
        f[Index.sectionEnergy.rawValue] = DifficultyFeatureExtractor.clamp01(section?.energy ?? 0.5)
        f[Index.sectionLabelFactor.rawValue] = section.map { Self.labelFactor($0.label) } ?? 0.9

        // DSP importance — the deterministic score the model learns to refine.
        f[Index.dspImportance.rawValue] = DifficultyFeatureExtractor.clamp01(event.importance)
        return f
    }

    private static func nearestBeat(to time: Double, in beats: [Double]) -> Double? {
        guard !beats.isEmpty else { return nil }
        var lo = 0, hi = beats.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        var best = beats[lo]
        if lo > 0, abs(beats[lo - 1] - time) < abs(best - time) { best = beats[lo - 1] }
        return best
    }

    /// Section-label bias, normalized into 0…1 (chorus = most chartable).
    /// Kept in sync with the generator's density table, scaled by 1/1.1 so
    /// every feature stays inside the documented 0…1 band.
    static func labelFactor(_ label: SectionLabel) -> Double {
        switch label {
        case .intro: return 0.50
        case .verse: return 0.77
        case .chorus: return 1.00
        case .bridge: return 0.68
        case .breakdown: return 0.55
        case .outro: return 0.36
        case .generic: return 0.82
        }
    }
}