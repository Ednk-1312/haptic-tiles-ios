import Foundation

/// Self-supervised training-data generation for the AI models.
///
/// The pipeline is fully deterministic (SplitMix64 seeding) and runs the REAL
/// chart pipeline: synthesize an analysis → `ChartGenerator` (deterministic
/// mode, no advisor) → `ChartDifficultyAnalyzer` → feature extractors.
///
/// Labels come from measurable, reproducible outcomes:
/// - Difficulty label = the deterministic difficulty score of the generated
///   chart (the AI learns to approximate it; later, human chart ratings will
///   replace these labels without changing the record format).
/// - Event label = 1 when the deterministic chart kept the candidate event
///   (within the same 55 ms tolerance the diagnostics use), 0 when skipped.
///
/// The record shapes are deliberately future-proof: a future human-labeling
/// pass can add `humanLabel` / `humanCorrectedTime` fields and re-train
/// without re-architecting anything.
enum TrainingDataSynthesis {
    // MARK: - Record shapes

    struct DifficultyRecord: Codable, Sendable {
        var songID: String
        var difficultyRaw: String
        var chartVersion: Int
        var bpm: Double
        var features: [Double]
        var labelScore: Double          // deterministic difficulty 0…10
        var labelLevel: String
    }

    struct EventRecord: Codable, Sendable {
        var songID: String
        var difficultyRaw: String
        var chartVersion: Int
        var time: Double
        var dspImportance: Double
        var strength: Double
        var onBeat: Bool
        var features: [Double]
        var labelSelected: Double       // 1 = kept by the deterministic chart
    }

    struct PatternRecord: Codable, Sendable {
        var songID: String
        var difficultyRaw: String
        var chartVersion: Int
        var bpm: Double
        var variant: Int
        var phraseIndex: Int
        var candidateIndex: Int
        var features: [Double]
        var labelSelected: Double       // 1 = the deterministic plan's candidate
    }

    // MARK: - Synthetic song generation

    /// A varied, plausible AudioAnalysis: BPM 60–220, duration 45–120 s,
    /// 4–6 sections with an energy ramp (quiet intro → loud chorus), beats
    /// with mild tempo jitter, on-beat accents + off-beat eighths + off-grid
    /// ghosts. Deterministic for a given seed.
    static func synthesizeAnalysis(seed: UInt64) -> AudioAnalysis {
        var rng = SplitMix64(state: seed)
        let bpm = Double(Int(60 + rng.uniform() * 160))          // 60…219
        let duration = 45 + rng.uniform() * 75                   // 45…120 s
        let sectionCount = 4 + Int(rng.uniform() * 3)            // 4…6
        let labelCycle: [SectionLabel] = [.intro, .verse, .chorus, .verse, .chorus, .outro]
        var sections: [SongSection] = []
        var sectionStart = 0.0
        for i in 0..<sectionCount {
            let rawLen = (duration / Double(sectionCount)) * (0.8 + rng.uniform() * 0.4)
            let end = i == sectionCount - 1 ? duration : min(duration, sectionStart + rawLen)
            let label = labelCycle[min(i, labelCycle.count - 1)]
            var energy = 0.12 + 0.88 * (Double(i) / Double(sectionCount - 1))
            energy += (rng.uniform() - 0.5) * 0.2
            if label == .chorus { energy = min(1, energy * 1.15) }
            if label == .breakdown { energy *= 0.5 }
            if label == .intro { energy = min(0.3, energy) }
            sections.append(SongSection(index: i, start: sectionStart, end: end,
                                        label: label, energy: min(1, max(0.05, energy))))
            sectionStart = end
            if sectionStart >= duration { break }
        }
        if sections.isEmpty {
            sections = [SongSection(index: 0, start: 0, end: duration, label: .generic, energy: 0.5)]
        }

        // Band profile for this "song".
        let low = 0.25 + rng.uniform() * 0.5
        let mid = 0.15 + rng.uniform() * 0.5
        let high = 0.05 + rng.uniform() * 0.3

        // Beats with ±1.5 % tempo jitter.
        let baseInterval = 60.0 / bpm
        var beats: [Beat] = []
        var t = 0.25
        var beatIndex = 0
        while t < duration - 1.0 {
            let strong = beatIndex % 4 == 0
            let strength = strong ? 0.85 + rng.uniform() * 0.15 : 0.45 + rng.uniform() * 0.2
            beats.append(Beat(time: t, strength: strength, isStrong: strong))
            t += baseInterval * (1 + (rng.uniform() - 0.5) * 0.03)
            beatIndex += 1
        }

        // Events: on-beat accents, off-beat eighths, occasional off-grid ghosts.
        var events: [MusicalEvent] = []
        var onsets: [OnsetEvent] = []
        var nextBeatIndex = 0
        var ghostCount = 0
        while nextBeatIndex < beats.count {
            let beat = beats[nextBeatIndex]
            let sectionIndex = sections.lastIndex { beat.time >= $0.start && beat.time < $0.end } ?? 0

            // On-beat event.
            let importance = beat.isStrong
                ? 0.75 + rng.uniform() * 0.2
                : 0.45 + rng.uniform() * 0.3
            let type: MusicalEventType = beat.isStrong ? .kickLike : .percussive
            events.append(MusicalEvent(time: beat.time,
                                       strength: beat.strength * (0.8 + rng.uniform() * 0.2),
                                       confidence: 0.7 + rng.uniform() * 0.25,
                                       type: type,
                                       lowEnergy: low + rng.uniform() * 0.15,
                                       midEnergy: mid + rng.uniform() * 0.15,
                                       highEnergy: high + rng.uniform() * 0.1,
                                       isOnBeat: true,
                                       beatStrength: beat.strength,
                                       sectionIndex: sectionIndex,
                                       importance: importance))
            onsets.append(OnsetEvent(time: beat.time, strength: Float(importance), confidence: 0.8))

            // Off-beat eighth (half the time), weaker.
            if rng.uniform() < 0.5 {
                let offTime = beat.time + baseInterval * 0.5
                if offTime < duration - 1 {
                    let offImportance = 0.25 + rng.uniform() * 0.35
                    events.append(MusicalEvent(time: offTime,
                                               strength: 0.35 + rng.uniform() * 0.3,
                                               confidence: 0.55 + rng.uniform() * 0.3,
                                               type: .percussive,
                                               lowEnergy: low * 0.7 + rng.uniform() * 0.1,
                                               midEnergy: mid * 0.8 + rng.uniform() * 0.1,
                                               highEnergy: high + rng.uniform() * 0.1,
                                               isOnBeat: false,
                                               beatStrength: beat.strength * 0.5,
                                               sectionIndex: sectionIndex,
                                               importance: offImportance))
                    onsets.append(OnsetEvent(time: offTime, strength: Float(offImportance), confidence: 0.6))
                }
            }

            // Off-grid ghost (a quarter of the time): weak, off the grid, and
            // loud-section-dependent — the chart should mostly skip these.
            if rng.uniform() < 0.25 {
                ghostCount += 1
                let ghostTime = beat.time + baseInterval * (0.2 + rng.uniform() * 0.6)
                if ghostTime < duration - 1, ghostTime > 0.4 {
                    let ghostImportance = 0.05 + rng.uniform() * 0.15
                    events.append(MusicalEvent(time: ghostTime,
                                               strength: 0.05 + rng.uniform() * 0.2,
                                               confidence: 0.3 + rng.uniform() * 0.3,
                                               type: .melodic,
                                               lowEnergy: low * 0.3 + rng.uniform() * 0.05,
                                               midEnergy: mid * 0.4 + rng.uniform() * 0.05,
                                               highEnergy: high * 0.5 + rng.uniform() * 0.05,
                                               isOnBeat: false,
                                               beatStrength: 0.1,
                                               sectionIndex: sectionIndex,
                                               importance: ghostImportance))
                    onsets.append(OnsetEvent(time: ghostTime, strength: Float(ghostImportance), confidence: 0.4))
                }
            }
            nextBeatIndex += 1
        }
        events.sort { $0.time < $1.time }
        onsets.sort { $0.time < $1.time }

        // Waveform envelope (downsampled RMS feel) from section energy.
        var waveform = [Float](repeating: 0.1, count: 256)
        for i in waveform.indices {
            let time = Double(i) / 255 * duration
            let section = sections.last { time >= $0.start && time < $0.end }
                ?? sections.first
                ?? SongSection(index: 0, start: 0, end: duration, label: .generic, energy: 0.5)
            waveform[i] = Float(max(0.05, section.energy * (0.7 + rng.uniform() * 0.6)))
        }

        return AudioAnalysis(duration: duration,
                             sampleRate: 44100,
                             tempoBPM: bpm,
                             tempoConfidence: 0.6 + rng.uniform() * 0.35,
                             beats: beats,
                             onsets: onsets,
                             events: events,
                             sections: sections,
                             waveform: waveform,
                             averageEnergy: sections.map(\.energy).reduce(0, +) / Double(sections.count),
                             analysisDuration: 0.4,
                             hopTime: 512.0 / 44100.0)
    }

    // MARK: - Record generation

    /// Runs the deterministic pipeline over `songCount` synthetic songs ×
    /// difficulty/density combos and returns labeled feature records.
    /// Labels come from the REAL generator + difficulty analyzer, so training
    /// data and app behavior can never drift apart.
    static func generateRecords(seed: UInt64 = 0x5EED_2026,
                                songCount: Int = 90,
                                difficulties: [DifficultyLevel] = [.easy, .medium, .hard, .extreme],
                                densities: [Double] = [0.9, 1.05, 1.2],
                                maxEventsPerChart: Int = 250,
                                progress: (Int, Int) -> Void = { _, _ in }) async
        -> (difficulty: [DifficultyRecord], events: [EventRecord], patterns: [PatternRecord]) {
        var difficultyRecords: [DifficultyRecord] = []
        var eventRecords: [EventRecord] = []
        var patternRecords: [PatternRecord] = []

        for song in 0..<songCount {
            let songSeed = seed &+ UInt64(song) &* 0x9E37_79B9_7F4A_7C15
            let analysis = synthesizeAnalysis(seed: songSeed)
            let songID = UUID().uuidString

            for (dIdx, difficulty) in difficulties.enumerated() {
                for (densIdx, density) in densities.enumerated() {
                    let request = ChartGenerator.Request(
                        difficulty: difficulty,
                        densityMultiplier: density,
                        seed: songSeed ^ (UInt64(dIdx) << 16) ^ UInt64(densIdx))
                    guard let output = try? await ChartGenerator().generate(analysis: analysis,
                                                                            songID: UUID(),
                                                                            request: request) else { continue }
                    let chart = output.chart
                    let metrics = output.metrics

                    let diffFeatures = DifficultyFeatureExtractor.extract(notes: chart.notes,
                                                                          metrics: metrics,
                                                                          analysis: analysis)
                    difficultyRecords.append(DifficultyRecord(songID: songID,
                                                              difficultyRaw: difficulty.rawValue,
                                                              chartVersion: chart.chartVersion,
                                                              bpm: analysis.tempoBPM ?? 0,
                                                              features: diffFeatures,
                                                              labelScore: metrics.score10,
                                                              labelLevel: metrics.label.rawValue))

                    // Pattern records — every phrase of variant 0, every
                    // candidate. Candidate 0 IS the deterministic plan (the
                    // model learns to defend or overturn it from the features),
                    // so labels come from the real pipeline by construction.
                    let pp = ChartGenerator.preplan(analysis: analysis, request: request,
                                                    eventImportance: nil, variant: 0,
                                                    wantContexts: true)
                    for ctx in pp.contexts {
                        for ci in ctx.candidates.indices {
                            patternRecords.append(PatternRecord(songID: songID,
                                                                difficultyRaw: difficulty.rawValue,
                                                                chartVersion: chart.chartVersion,
                                                                bpm: analysis.tempoBPM ?? 0,
                                                                variant: 0,
                                                                phraseIndex: ctx.phraseIndex,
                                                                candidateIndex: ci,
                                                                features: PatternFeatureExtractor.extract(context: ctx, candidateIndex: ci),
                                                                labelSelected: ci == 0 ? 1.0 : 0.0))
                        }
                    }

                    // Event records — deterministically downsampled per chart.
                    let ctx = EventFeatureExtractor.context(for: analysis)
                    let noteTimes = chart.notes.map(\.time)
                    let selected = analysis.events.map { event in
                        noteTimes.contains { abs($0 - event.time) <= 0.055 } ? 1.0 : 0.0
                    }
                    // Deterministic even-spaced subsample (keeps the dataset
                    // bounded while covering the whole song, intro → outro).
                    let total = analysis.events.count
                    let count = min(total, maxEventsPerChart)
                    let step = Double(total) / Double(count)
                    var k = 0
                    while k < count {
                        let idx = min(total - 1, Int(Double(k) * step))
                        let event = analysis.events[idx]
                        let features = EventFeatureExtractor.extract(event, index: idx,
                                                                     events: analysis.events, ctx: ctx)
                        eventRecords.append(EventRecord(songID: songID,
                                                        difficultyRaw: difficulty.rawValue,
                                                        chartVersion: chart.chartVersion,
                                                        time: event.time,
                                                        dspImportance: event.importance,
                                                        strength: event.strength,
                                                        onBeat: event.isOnBeat,
                                                        features: features,
                                                        labelSelected: selected[idx]))
                        k += 1
                    }
                }
            }
            progress(song + 1, songCount)
        }
        return (difficultyRecords, eventRecords, patternRecords)
    }
}