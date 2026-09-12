import Foundation

/// Deterministic, scripted playthrough validation.
///
/// Drives the SAME subsystems the live engine drives — `NoteScheduler`
/// (nearest-note resolution), `InputJudge` (windows + calibration), and
/// `ScoreManager` (points/combo/accuracy) — in the engine's order: a tap is
/// resolved against the nearest unjudged note in its lane, and a note nobody
/// hit becomes a miss once its miss window passes. No audio, no haptics, no
/// wall clock: time is scripted, so results are perfectly reproducible.
///
/// Used by:
/// - the simulator-autoplay diagnostics (Task 1): replay a chart with a
///   scripted player and compare against expectations;
/// - the automated gameplay-simulation tests (perfect / slightly early /
///   slightly late / deterministic noisy / dropping players).
///
/// This is a validation harness, not the production timing path — the game's
/// authoritative clock remains the audio clock.
enum AutoplaySimulation {
    struct Config: Sendable {
        var songTitle: String = "Autoplay Simulation"
        /// Signed bias added to every tap time (seconds). Positive = late.
        var tapOffset: Double = 0
        /// Deterministic ±jitter (seconds). Seeded — same seed → same run.
        var jitterMs: Double = 0
        var jitterSeed: UInt64 = 0x5EED_2026
        /// 0…1 chance each note is never tapped (becomes a miss).
        var dropRate: Double = 0
        /// 0 = sustain every hold exactly to its tail (completes). Negative =
        /// release that early → the hold misses. Positive = keep holding past
        /// the tail (still completes).
        var holdReleaseOffset: Double = 0
        /// Restrict play to notes inside this window (practice sections).
        /// Notes outside are invisible to the simulation, exactly like a
        /// practice session's section focus.
        var timeWindow: ClosedRange<Double>? = nil
        var windows: InputJudge.Config = .standard
        /// Simulated audio duration (seconds) — reported as playedDuration.
        var duration: Double = 0
    }

    /// Runs the simulation on the main actor because it drives the same
    /// `NoteScheduler` the engine uses; everything else in here is pure.
    @MainActor
    static func run(chart: Chart, config: Config = Config()) -> GameplayResult {
        let judge = InputJudge(config: config.windows)
        // Section focus (practice): notes outside the window simply don't exist.
        var windowedChart = chart
        if let window = config.timeWindow {
            windowedChart.notes = chart.notes.filter {
                $0.time >= window.lowerBound && $0.time <= window.upperBound
            }
        }
        let scheduler = NoteScheduler(chart: windowedChart)
        var score = ScoreManager()
        var rng = SplitMix64(state: config.jitterSeed)

        let notes = scheduler.sortedNotes
        var attempts: [(time: Double, lane: Int)] = []
        var boundaries: [(time: Double, index: Int)] = []
        var completions: [(time: Double, lane: Int, index: Int)] = []
        for (i, note) in notes.enumerated() {
            let jitter = config.jitterMs > 0
                ? (rng.uniform() * 2 - 1) * config.jitterMs / 1000
                : 0
            let dropped = config.dropRate > 0 && rng.uniform() < config.dropRate
            let missBoundary = note.time + judge.config.missWindow
            boundaries.append((missBoundary, i))
            if !dropped {
                attempts.append((note.time + config.tapOffset + jitter, note.lane))
            }
            if note.type == .hold {
                // Sustaining starts at the head tap; release decides completion.
                let release = note.time + note.duration + config.holdReleaseOffset
                completions.append((release, note.lane, i))
            }
        }
        attempts.sort { $0.time < $1.time }
        boundaries.sort { $0.time < $1.time }
        completions.sort { $0.time < $1.time }

        let tapWindow = judge.config.goodWindow + InputJudge.Config.edgeGrace
        var a = 0, b = 0, c = 0
        while a < attempts.count || b < boundaries.count || c < completions.count {
            let attemptTime = a < attempts.count ? attempts[a].time : .infinity
            let boundaryTime = b < boundaries.count ? boundaries[b].time : .infinity
            let completionTime = c < completions.count ? completions[c].time : .infinity
            if attemptTime <= boundaryTime && attemptTime <= completionTime {
                let attempt = attempts[a]
                a += 1
                // Real-engine resolution: nearest unjudged note in the lane.
                if let hit = scheduler.nearest(in: attempt.lane, to: attempt.time, window: tapWindow) {
                    let judgment = judge.classifyForgiving(tapTime: attempt.time, noteTime: hit.note.time)
                    score.apply(judgment)
                    scheduler.mark(hit.index, judgment: judgment)
                }
                // A tap that found nothing leaves its note to the miss boundary.
            } else if completionTime <= boundaryTime {
                // Real-engine hold resolution: only a hold whose head was hit
                // can complete; a release before the tail is a hold miss.
                let completion = completions[c]
                c += 1
                let head = scheduler.judgment(for: completion.index)
                if let head, head != .miss {
                    if completion.time >= notes[completion.index].time + notes[completion.index].duration - 0.06 {
                        score.completeHold()
                    } else {
                        score.missHold()
                        scheduler.mark(completion.index, judgment: .miss)
                    }
                }
            } else {
                let boundary = boundaries[b]
                b += 1
                if scheduler.judgment(for: boundary.index) == nil {
                    score.apply(.miss)
                    scheduler.mark(boundary.index, judgment: .miss)
                }
            }
        }

        return GameplayResult(songTitle: config.songTitle,
                              difficulty: chart.difficulty,
                              score: score.score,
                              maxCombo: score.maxCombo,
                              perfectCount: score.counts[.perfect] ?? 0,
                              greatCount: score.counts[.great] ?? 0,
                              goodCount: score.counts[.good] ?? 0,
                              missCount: score.counts[.miss] ?? 0,
                              accuracy: score.accuracy,
                              date: Date(),
                              holdsCompleted: score.holdsCompleted,
                              holdsMissed: score.holdsMissed,
                              playedDuration: config.duration)
    }

    /// Convenience: the ideal player (every note judged Perfect).
    @MainActor
    static func perfectRun(chart: Chart) -> GameplayResult {
        run(chart: chart, config: Config())
    }
}