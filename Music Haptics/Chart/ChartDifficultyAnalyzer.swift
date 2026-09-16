import Foundation

/// Objective, reproducible difficulty measurement from chart features.
///
/// Difficulty is measured in player actions rather than raw note voices: notes
/// inside the same 100 ms window are one reaction event (a chord), while chord
/// size is scored separately. This prevents a chord from falsely looking like
/// several independent taps and keeps long intros/outros from inflating the
/// rating through an active-span-only calculation.
enum ChartDifficultyAnalyzer {
    private struct ActionEvent {
        let notes: [ChartNote]
        let time: Double

        var lanes: [Int] { notes.map(\.lane) }
        var isChord: Bool { notes.count > 1 }
    }

    static func analyze(notes: [ChartNote], duration: Double) -> DifficultyMetrics {
        let sorted = notes
            .filter { $0.time.isFinite && $0.duration.isFinite && $0.strength.isFinite && $0.time >= 0 }
            .sorted { $0.time < $1.time }
        let count = sorted.count
        guard !sorted.isEmpty else {
            return DifficultyMetrics(score10: 0, label: .easy, notesPerSecond: 0,
                                     averageInterval: 0, maxBurstNPS: 0, simultaneityRatio: 0,
                                     averageJumpDistance: 0, alternationRatio: 0,
                                     intervalStdDev: 0, spikeRatio: 0, sustainedNPS: 0)
        }

        let events = makeActionEvents(sorted)
        let firstNoteTime = sorted.first?.time ?? 0
        let lastNoteTime = sorted.last?.time ?? firstNoteTime
        let activeSpan = max(lastNoteTime - firstNoteTime, 1)
        let safeDuration = max(duration.isFinite ? duration : 0, lastNoteTime + 0.001, 1)

        // Preserve the public chart NPS semantics: this is raw note voices over
        // their active span and is used for display/diagnostics. The difficulty
        // score below uses action NPS so chords do not double-count reactions.
        let nps = Double(count) / activeSpan
        let sustainedNPS = Double(count) / safeDuration
        let actionSpan = max((events.last?.time ?? firstNoteTime) - (events.first?.time ?? firstNoteTime), 1)
        let actionNPS = Double(events.count) / actionSpan
        let sustainedActionNPS = Double(events.count) / safeDuration

        let actionIntervals = zip(events, events.dropFirst()).map { $1.time - $0.time }
            .filter { $0.isFinite && $0 > 0.001 }
        let averageInterval = average(actionIntervals)
        let intervalStdDev = standardDeviation(actionIntervals)
        let p25Interval = percentile(actionIntervals, 0.25) ?? max(averageInterval, 1)

        // Max action events in any one-second window. This is intentionally
        // chord-aware and more representative of the player's reaction load
        // than counting every simultaneous voice independently.
        let maxBurst = maxCount(in: events, window: 1.0)
        let spikeRatio = actionNPS > 0.3 ? Double(maxBurst) / actionNPS : 0

        // Movement difficulty is measured between action-event lane sets. The
        // minimum reachable lane distance is used for chords, matching the
        // playability validator instead of penalizing a harmless chord voice.
        var jumps: [Int] = []
        var alternations = 0
        var previousRepresentativeLane: Int?
        for event in events {
            if let previous = previousRepresentativeLane,
               let current = event.lanes.min(by: { abs($0 - previous) < abs($1 - previous) }) {
                jumps.append(abs(current - previous))
            }
            if let representative = event.lanes.first {
                previousRepresentativeLane = representative
            }
        }
        if events.count > 2 {
            let representatives = events.map { $0.lanes.first ?? 0 }
            for index in 2..<representatives.count where representatives[index] == representatives[index - 2]
                    && representatives[index] != representatives[index - 1] {
                alternations += 1
            }
        }

        let averageJump = average(jumps.map(Double.init))
        let alternationRatio = events.count > 2
            ? Double(alternations) / Double(events.count - 2)
            : 0
        let chordCount = events.filter(\.isChord).count
        let simultaneityRatio = events.count > 1
            ? Double(chordCount) / Double(events.count - 1)
            : 0
        let holdSeconds = sorted
            .filter { $0.type == .hold && $0.duration > 0 }
            .map(\.duration)
            .reduce(0, +)
        let holdLoad = min(1, holdSeconds / max(safeDuration * 0.35, 0.001))

        // Calibrated, bounded features. The action-rate and reaction-load terms
        // carry most of the score; movement, chords, holds and irregularity add
        // meaningful distinctions without allowing one unusual chart artifact
        // to dominate the rating.
        let densityFeature = clamp01(actionNPS / 8.0)
        let burstFeature = clamp01(Double(maxBurst) / 10.0)
        let reactionFeature = clamp01(0.25 / max(p25Interval, 0.05))
        let sustainedFeature = clamp01(sustainedActionNPS / 6.0)
        let jumpFeature = clamp01(averageJump / 2.0)
        let alternationFeature = clamp01(alternationRatio * 1.35)
        let chordFeature = clamp01(simultaneityRatio * 2.0)
        let irregularityFeature = clamp01(intervalStdDev / max(averageInterval, 0.05) / 0.8)

        let raw = 10 * (
            0.30 * densityFeature
                + 0.16 * burstFeature
                + 0.16 * reactionFeature
                + 0.10 * sustainedFeature
                + 0.10 * jumpFeature
                + 0.07 * alternationFeature
                + 0.06 * chordFeature
                + 0.03 * irregularityFeature
                + 0.02 * holdLoad)
        let score = min(10, max(0, raw.isFinite ? raw : 0))

        return DifficultyMetrics(
            score10: score,
            label: DifficultyLevel.level(forScore: score),
            notesPerSecond: finiteOrZero(nps),
            averageInterval: finiteOrZero(averageInterval),
            maxBurstNPS: Double(maxBurst),
            simultaneityRatio: clamp01(simultaneityRatio),
            averageJumpDistance: finiteOrZero(averageJump),
            alternationRatio: clamp01(alternationRatio),
            intervalStdDev: finiteOrZero(intervalStdDev),
            spikeRatio: finiteOrZero(spikeRatio),
            sustainedNPS: finiteOrZero(sustainedNPS))
    }

    private static func makeActionEvents(_ notes: [ChartNote]) -> [ActionEvent] {
        var result: [ActionEvent] = []
        var index = 0
        while index < notes.count {
            let anchorTime = notes[index].time
            var end = index + 1
            while end < notes.count && notes[end].time - anchorTime < 0.1 {
                end += 1
            }
            result.append(ActionEvent(notes: Array(notes[index..<end]), time: anchorTime))
            index = end
        }
        return result
    }

    private static func maxCount(in events: [ActionEvent], window: Double) -> Int {
        guard !events.isEmpty else { return 0 }
        var right = 0
        var result = 0
        for left in events.indices {
            while right < events.count && events[right].time - events[left].time < window {
                right += 1
            }
            result = max(result, right - left)
        }
        return result
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = average(values)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        return sqrt(max(0, variance))
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = min(Double(sorted.count - 1), max(0, fraction) * Double(sorted.count - 1))
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let amount = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * amount
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }

    private static func finiteOrZero(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
