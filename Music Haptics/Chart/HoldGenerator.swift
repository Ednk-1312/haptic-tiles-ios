import Foundation

/// Deterministic hold-note pass.
///
/// Runs AFTER lane assignment. A small, musically-gated fraction of strong
/// accent notes become holds: the note must land on a strong detected beat (or
/// be a high-strength accent), sit in a section with real energy, and have
/// enough free space in its OWN lane for the hold body (head + duration +
/// minimum same-lane gap must clear the next note in that lane). Other lanes
/// may keep playing normally during a hold — that is the musical point of a
/// hold: one finger sustains while the chart keeps moving.
///
/// Everything is seeded from the chart seed, so identical input → identical
/// holds. The validator still has the last word: any chart that ends up with a
/// same-lane overlap is rejected/repaired there.
enum HoldGenerator {
    /// Converts qualifying tap notes into holds in place. `playEnd` bounds how
    /// late a hold may start so its tail still lands inside the playable span.
    static func apply(to notes: [ChartNote],
                      analysis: AudioAnalysis,
                      difficulty: DifficultyLevel,
                      seed: UInt64,
                      playEnd: Double) -> [ChartNote] {
        guard notes.count >= 3, let bpm = analysis.tempoBPM, bpm > 20, bpm < 300 else {
            return notes
        }
        let beatInterval = 60.0 / bpm
        var rng = SplitMix64(state: seed &+ 0x484F_4C44)   // "HOLD"

        // Strong-beat reference set for accent checks.
        let strongTimes: [Double] = analysis.beats
            .filter { $0.isStrong || $0.strength > 0.7 }
            .map { $0.time }

        // Next note in the same lane (index), for occupancy checks.
        var nextSameLane = [Int](repeating: -1, count: notes.count)
        for i in notes.indices {
            var j = i + 1
            while j < notes.count, notes[j].lane != notes[i].lane { j += 1 }
            nextSameLane[i] = j < notes.count ? j : -1
        }

        // Higher difficulties hold more; capped so holds stay a seasoning, not
        // the default. The two rng draws below happen only for notes that pass
        // the musical gates, and the draw ORDER only depends on the note list
        // — so output stays fully deterministic.
        let chance = min(0.42, max(0.16, 0.14 + difficulty.targetNPS * 0.032))
        let minSameLaneGap = 0.14

        var result = notes
        for i in result.indices {
            guard result[i].type == .tap else { continue }

            // Musical gates: accent on a strong beat, with real energy behind it.
            let onStrongBeat = strongTimes.contains { abs($0 - result[i].time) < 0.035 }
            guard result[i].strength >= 0.72 || onStrongBeat else { continue }
            // Not the tail of the chart, and the next same-lane note must exist
            // (a hold's tail needs somewhere to land before the song ends).
            guard nextSameLane[i] >= 0 else { continue }
            // Chord partner on the same tick: only the first voice may hold.
            if i > 0, result[i].time - result[i - 1].time < 0.05 { continue }
            // Tail must land inside the playable span.
            guard result[i].time + 2.0 * beatInterval <= playEnd + 0.2 else { continue }

            // Duration follows the LOCAL beat interval at the hold head, not
            // only the song-wide BPM. A tempo/energy build can therefore make
            // holds shorter in the fast passage while a sparse section keeps
            // its natural sustain. This is still a musical chart duration;
            // Dynamic Speed never rewrites it during active gameplay.
            let localBeat = localBeatInterval(at: result[i].time,
                                               beats: analysis.beats,
                                               fallback: beatInterval)
            let beats = rng.uniform() < 0.22 ? 2.0 : 1.0
            let duration = min(max(beats * localBeat, 0.32), 2.4)

            // Own-lane occupancy: head + body + gap must clear the next note.
            let nextTime = result[nextSameLane[i]].time
            guard result[i].time + duration + minSameLaneGap <= nextTime else { continue }

            // Final gate: only a fraction of qualifying accents become holds.
            guard rng.uniform() < chance else { continue }

            result[i].type = .hold
            result[i].duration = duration
        }
        return result
    }

    /// Returns the beat interval local to a note. Beat detection can contain
    /// an occasional gap, so choose the nearest valid interval whose midpoint
    /// is closest to the hold head and fall back to the global tempo when the
    /// local evidence is not usable. This is pre-game chart construction only.
    static func localBeatInterval(at time: Double, beats: [Beat], fallback: Double) -> Double {
        let safeFallback = fallback.isFinite && fallback > 0 ? fallback : 0.5
        let ordered = beats
            .filter { $0.time.isFinite }
            .sorted { $0.time < $1.time }
        guard ordered.count >= 2, time.isFinite else { return safeFallback }

        var best: (distance: Double, interval: Double)?
        for pair in zip(ordered, ordered.dropFirst()) {
            let interval = pair.1.time - pair.0.time
            guard interval.isFinite, interval >= 0.20, interval <= 2.5 else { continue }
            let midpoint = (pair.0.time + pair.1.time) * 0.5
            let candidate = (abs(midpoint - time), interval)
            if best == nil || candidate.0 < best!.distance {
                best = candidate
            }
        }
        return best?.interval ?? safeFallback
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value.isFinite ? value : 0))
    }
}