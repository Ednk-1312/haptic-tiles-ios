import Foundation

/// Deterministic statistics about a generated chart, used by the developer
/// diagnostics and the chart-quality tests. Computed purely from the persisted
/// chart + analysis, so it works offline and reproduces exactly.
struct ChartAnalytics: Sendable {
    // Musical content
    var eventCandidateCount = 0      // onsets inside the chartable window
    var eventsCharted = 0            // candidates that matched an accepted note
    var eventsSkipped = 0            // candidates deliberately not charted
    var beatFillNoteCount = 0        // notes added from beats, not onsets
    var totalNoteCount = 0
    var notesPerSecond = 0.0         // over active span
    var sustainedNPS = 0.0           // over full song duration

    // Simultaneity
    var maxSimultaneous = 0          // max notes inside any 0.1s window
    var chordGroups = 0              // disjoint 0.1s windows holding ≥ 2 notes

    // Lane distribution
    var laneCounts: [Int] = [0, 0, 0, 0]        // notes per lane
    var laneIdleWindows: [Double] = [0, 0, 0, 0]  // longest gap w/o using each lane

    /// A one-sided chart (a lane nearly unused, or one lane dominating) is
    /// suspicious unless the music justifies it. Not a hard error — some
    /// patterns legitimately favor lanes — but worth surfacing. Sparse charts
    /// (fewer than ~40 notes) are exempt: short/intro material can be musical
    /// with little lane travel.
    var isSuspiciouslyOneSided: Bool {
        let total = laneCounts.reduce(0, +)
        guard total >= 40 else { return false }
        let shares = laneCounts.map { Double($0) / Double(total) }
        return shares.min() ?? 0 < 0.06 || (shares.max() ?? 0) > 0.45
    }

    var laneShares: [Double] {
        let total = laneCounts.reduce(0, +)
        guard total > 0 else { return [0, 0, 0, 0] }
        return laneCounts.map { Double($0) / Double(total) }
    }

    // Lane movement
    var sameLaneSteps = 0
    var jump1Steps = 0               // adjacent-lane moves
    var jump2Steps = 0
    var jump3Steps = 0
    var alternationCount = 0         // a,b,a bounces on any lane pair
    var maxExtremeBounceRun = 0      // longest 1↔4↔1↔4 run

    // v4 pattern vocabulary
    var templateCounts: [String: Int] = [:]   // RhythmTemplate rawValue → phrases
    var repeatedPatternRate = 0.0             // consecutive same-template phrase share
    var restFrequency = 0.0                   // restful-phrase share of all phrases
    var meanPhraseLength = 0.0                // average phrase duration (s)
    var chordFrequency = 0.0                  // chord notes / total notes
    var holdCount = 0
    var holdFrequency = 0.0                   // holds / total notes
    var sectionDensity: [SectionDensityStat] = []
    var difficultyVariance = 0.0              // variance of per-section NPS
    var repairCount = 0
}

/// One section's measured density, for diagnostics.
struct SectionDensityStat: Sendable {
    var label: String
    var start: Double
    var end: Double
    var energy: Double
    var notes: Int
    var nps: Double
}

/// Cross-difficulty diagnostics for the multi-chart system: does harder mean
/// harder? Minor crossings are tolerated (music can rate oddly at a boundary),
/// but significant inversions are surfaced so the developer can see them.
enum ChartMonotonicity {
    /// Difficulty score drop (higher-level score below lower-level score) that
    /// counts as a SIGNIFICANT inversion.
    static let significantInversionThreshold = 0.75

    /// For each adjacent pair (Easy→Normal→Hard→Expert→Extreme) whose score
    /// drops by more than the threshold, returns a human-readable diagnostic.
    static func inversions(charts: [DifficultyLevel: Chart]) -> [String] {
        let ordered = ChartStorage.generatedDifficulties.compactMap { level in
            charts[level].map { (level, $0) }
        }
        guard ordered.count >= 2 else { return [] }
        var result: [String] = []
        for i in 1..<ordered.count {
            let (lowerLevel, lower) = ordered[i - 1]
            let (higherLevel, higher) = ordered[i]
            let drop = lower.difficultyScore - higher.difficultyScore
            if drop > significantInversionThreshold {
                result.append("\(higherLevel.displayName) (\(String(format: "%.1f", higher.difficultyScore))) rates BELOW \(lowerLevel.displayName) (\(String(format: "%.1f", lower.difficultyScore))) by \(String(format: "%.1f", drop))")
            }
        }
        return result
    }
}

enum ChartAnalyticsBuilder {
    /// Chartable window padding — the same the generator uses (0.4 s lead-in,
    /// 1.2 s tail).
    static let windowStart = 0.4
    static let windowTail = 1.2

    static func analyze(chart: Chart, analysis: AudioAnalysis?) -> ChartAnalytics {
        var stats = ChartAnalytics()
        let notes = chart.notes.sorted { $0.time < $1.time }
        stats.totalNoteCount = notes.count

        let firstTime = notes.first?.time ?? 0
        let lastTime = notes.last?.time ?? 0
        let span = max(lastTime - firstTime, 1)
        stats.notesPerSecond = Double(notes.count) / span
        stats.sustainedNPS = Double(notes.count) / max(chart.duration, 1)

        if let analysis {
            let candidates = analysis.events.filter {
                $0.time >= Self.windowStart
                    && $0.time <= max(analysis.duration - Self.windowTail, Self.windowStart + 0.5)
            }
            stats.eventCandidateCount = candidates.count

            // Every event within 55 ms of an accepted note counts as charted.
            var charted = Set<Int>()
            for note in notes {
                for (idx, event) in candidates.enumerated() where abs(event.time - note.time) <= 0.055 {
                    charted.insert(idx)
                }
            }
            stats.eventsCharted = charted.count
            stats.eventsSkipped = max(0, candidates.count - stats.eventsCharted)

            // Beat fill: notes not near an onset but near a detected beat.
            for note in notes {
                let nearEvent = candidates.contains { abs($0.time - note.time) <= 0.055 }
                if !nearEvent, analysis.beats.contains(where: { abs($0.time - note.time) <= 0.055 }) {
                    stats.beatFillNoteCount += 1
                }
            }
        }

        guard notes.count > 1 else { return stats }

        // Simultaneity: max notes inside any 0.1s window.
        var right = 0
        for left in 0..<notes.count {
            while right < notes.count, notes[right].time - notes[left].time < 0.1 { right += 1 }
            stats.maxSimultaneous = max(stats.maxSimultaneous, right - left)
        }
        stats.chordGroups = chordGroupCount(notes)

        // Lane distribution: per-lane counts and the longest silence per lane.
        var lastLaneUse = [Double](repeating: Self.windowStart, count: 4)
        for note in notes where (0..<4).contains(note.lane) {
            stats.laneCounts[note.lane] += 1
            stats.laneIdleWindows[note.lane] = max(stats.laneIdleWindows[note.lane],
                                                   note.time - lastLaneUse[note.lane])
            lastLaneUse[note.lane] = note.time
        }
        let trackEnd = max(chart.duration - Self.windowTail, Self.windowStart)
        for lane in 0..<4 where stats.laneCounts[lane] > 0 {
            stats.laneIdleWindows[lane] = max(stats.laneIdleWindows[lane], trackEnd - lastLaneUse[lane])
        }

        // v4 pattern vocabulary: rebuild phrase boundaries exactly the way the
        // generator does (same beats, same window, same energy lookup), then
        // classify each phrase's placed notes against the rhythm templates.
        if let analysis {
            let energy: (Double) -> Double = { time in
                analysis.sections.first { time >= $0.start && time < $0.end }?.energy ?? 0.5
            }
            let phrases = PhraseSequencer.buildPhrases(beats: analysis.beats,
                                                       playStart: Self.windowStart,
                                                       playEnd: max(analysis.duration - Self.windowTail, Self.windowStart + 0.5),
                                                       energyAt: energy)
            if !phrases.isEmpty {
                var templateCounts: [String: Int] = [:]
                var sameRuns = 0
                var restful = 0
                var previousTemplate: RhythmTemplate?
                for phrase in phrases {
                    let phraseNotes = notes.filter { $0.time >= phrase.start && $0.time < phrase.end }
                    let mask = Phrase.slotMask(for: phraseNotes.map(\.time), start: phrase.start, beatLength: phrase.beatLength)
                    let template = RhythmTemplate.closest(toMask: mask, phraseLength: 16)
                    templateCounts[template.rawValue, default: 0] += 1
                    if template.isRestful { restful += 1 }
                    if previousTemplate == template { sameRuns += 1 }
                    previousTemplate = template
                }
                stats.templateCounts = templateCounts
                stats.repeatedPatternRate = Double(sameRuns) / Double(max(1, phrases.count - 1))
                stats.restFrequency = Double(restful) / Double(phrases.count)
                stats.meanPhraseLength = phrases.map { $0.end - $0.start }.reduce(0, +) / Double(phrases.count)
            }
        }

        // Chords + holds (as fractions of all notes).
        let inChord = chordNoteCount(notes)
        stats.chordFrequency = notes.isEmpty ? 0 : Double(inChord) / Double(notes.count)
        stats.holdCount = notes.filter { $0.type == .hold }.count
        stats.holdFrequency = notes.isEmpty ? 0 : Double(stats.holdCount) / Double(notes.count)
        stats.repairCount = chart.repairCount ?? 0

        // Per-section density + difficulty variance across sections.
        if let analysis, !analysis.sections.isEmpty {
            var npsValues: [Double] = []
            for section in analysis.sections {
                let inSection = notes.filter { $0.time >= section.start && $0.time < section.end }
                let len = max(0.001, section.end - section.start)
                let nps = Double(inSection.count) / len
                stats.sectionDensity.append(SectionDensityStat(label: section.label.rawValue,
                                                               start: section.start, end: section.end,
                                                               energy: section.energy, notes: inSection.count, nps: nps))
                if !inSection.isEmpty { npsValues.append(nps) }
            }
            if npsValues.count >= 2 {
                let mean = npsValues.reduce(0, +) / Double(npsValues.count)
                stats.difficultyVariance = npsValues.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(npsValues.count)
            }
        }

        // Lane transitions between consecutive notes.
        for i in 1..<notes.count {
            switch abs(notes[i].lane - notes[i - 1].lane) {
            case 0: stats.sameLaneSteps += 1
            case 1: stats.jump1Steps += 1
            case 2: stats.jump2Steps += 1
            default: stats.jump3Steps += 1
            }
        }
        for i in 2..<notes.count {
            if notes[i].lane == notes[i - 2].lane, notes[i].lane != notes[i - 1].lane {
                stats.alternationCount += 1
            }
        }
        stats.maxExtremeBounceRun = extremeBounceRun(notes)
        return stats
    }

    /// Notes that belong to a simultaneous pair (within 0.1s of another note).
    private static func chordNoteCount(_ notes: [ChartNote]) -> Int {
        var count = 0
        var i = 0
        while i < notes.count {
            let j = i + 1
            if j < notes.count, notes[j].time - notes[i].time < 0.1 { count += 2; i = j + 1 }
            else { i += 1 }
        }
        return count
    }

    /// Number of disjoint 0.1s windows containing ≥ 2 notes.
    private static func chordGroupCount(_ notes: [ChartNote]) -> Int {
        var count = 0
        var idx = 0
        while idx < notes.count {
            var end = idx + 1
            while end < notes.count, notes[end].time - notes[idx].time < 0.1 { end += 1 }
            if end - idx >= 2 { count += 1 }
            idx = end
        }
        return count
    }

    /// Longest run of strictly alternating 1↔4 lane hits (0,3,0,3,…).
    private static func extremeBounceRun(_ notes: [ChartNote]) -> Int {
        var best = 0
        var run = 0
        for (i, note) in notes.enumerated() {
            let lane = note.lane
            guard lane == 0 || lane == 3 else {
                run = 0
                continue
            }
            if i > 0 {
                let prev = notes[i - 1].lane
                if (prev == 0 && lane == 3) || (prev == 3 && lane == 0) {
                    run += 1
                } else {
                    run = 1
                }
            } else {
                run = 1
            }
            best = max(best, run)
        }
        return best
    }
}