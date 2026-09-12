import Foundation

enum ChartGenerationError: LocalizedError {
    case unableToGenerate(String)

    /// User-facing text must NEVER expose internal candidate names, tiers or
    /// validator details — those are developer diagnostics, not player errors.
    var errorDescription: String? {
        switch self {
        case .unableToGenerate:
            return "Couldn't generate a playable chart for this song. Try again, or pick a different difficulty."
        }
    }

    /// Technical reason (candidate failures, validator findings) for logs.
    var debugDetail: String? {
        switch self {
        case .unableToGenerate(let reason): return reason
        }
    }
}

/// Turns raw analysis events into a human-playable, *musical* chart.
///
/// Pipeline: beat-grid quantization → phrase/template selection (the rhythm
/// vocabulary) → accent-aware emission with chords → lane motifs → hold pass →
/// playability validation (repair) → quality scoring across candidates.
///
/// How charts become "intentional" (v4):
/// - The song is segmented into 4-beat phrases built from the DETECTED beats.
///   Each phrase picks a RHYTHM TEMPLATE (quarters, eighths, syncopation,
///   bursts, call-and-response, rests…) from a deterministic, seeded roulette
///   over templates that fit the phrase's density budget AND musical support.
///   Repeating musical phrases reuse their template (with lane variation);
///   fresh material gets fresh rhythm — charts are compositions, not onset
///   decisions.
/// - Each phrase also picks a LANE MOTIF (walk, alternation, staircase,
///   mirror…). The motif biases lane assignment; the cost model still
///   guarantees feasibility and lane balance.
/// - Rests are first-class: quiet phrases deliberately choose rest/downbeat
///   templates instead of being force-filled.
/// - Three deterministic candidate charts are generated (seeded variants) and
///   the best one wins by `ChartQualityScorer` (reaction time, jumps, lane
///   balance, dead air in energetic sections, repetition appropriateness,
///   rest placement).
/// - Everything is deterministic for identical inputs; the validator remains
///   the final authority and can repair or reject a candidate.
///
/// When no usable beat grid exists (ambient/beat-less material), the v3
/// per-cell selection runs unchanged as the fallback, so every supported song
/// still charts deterministically.
final class ChartGenerator {
    static let currentVersion = 5

    /// Developer/stats switch: force the pre-v4 per-cell selection path even
    /// when a beat grid exists. Used by the ChartStats tool to measure
    /// before/after chart quality on identical inputs. Deterministic in both
    /// modes; never set from UI.
    nonisolated(unsafe) static var forceLegacySelection = false   // stats tool only

    struct Request: Sendable {
        var difficulty: DifficultyLevel
        var densityMultiplier: Double
        var seed: UInt64
    }

    struct Output: Sendable {
        var chart: Chart
        var metrics: DifficultyMetrics
        var validationWarnings: [String]
        /// 1 = full phrase-pattern pipeline, 2 = relaxed-constraint retry,
        /// 3 = legacy per-cell selection, 4 = minimal deterministic grid.
        /// Candidate rejection is an INTERNAL outcome: when every arrangement
        /// fails validation the generator degrades to the next tier instead of
        /// failing the song ("unplayable pattern (candidate N)" is never a
        /// user-facing error).
        var fallbackTier: Int = 1
    }

    /// Optional AI advisory port. When provided, the advisor may (a) re-rank
    /// candidate events before selection and (b) fuse the deterministic
    /// difficulty score with its own prediction. Returning nil from either
    /// hook leaves the deterministic pipeline byte-identical. The AI never
    /// creates timestamps, never bypasses validation, and the chart remains
    /// fully deterministic for a given advisor + inputs.
    func generate(analysis: AudioAnalysis,
                  songID: UUID,
                  request: Request,
                  advisor: (any AIChartAdvisor)? = nil) async throws -> Output {
        let started = Date()
        var lastReason = "unknown"

        // Resolve AI event importances ONCE (off the hot loop) so selection is
        // deterministic: the same analysis + advisor + settings → same array.
        var eventImportanceOverride: [Double]?
        if let advisor, !analysis.events.isEmpty {
            if let fused = await advisor.eventImportance(songID: songID, events: analysis.events, analysis: analysis),
               fused.count == analysis.events.count {
                eventImportanceOverride = fused
            }
        }

        // Plan every candidate arrangement deterministically (the exact
        // decision sequence the selector runs) and let the AI re-rank each
        // phrase's candidate patterns ONCE per generation. With no advisor
        // (or an unavailable/indecisive model) the plans are used unchanged,
        // so the deterministic output stays byte-identical.
        var preplanned: [PreplannedPhrases] = []
        var patternContexts: [PatternRankingContext] = []
        if advisor != nil {
            for candidate in 0..<3 {
                let pp = Self.preplan(analysis: analysis, request: request,
                                      eventImportance: eventImportanceOverride,
                                      variant: candidate, wantContexts: true)
                patternContexts.append(contentsOf: pp.contexts)
                preplanned.append(pp.planned)
            }
            if !patternContexts.isEmpty,
               let ranked = await advisor?.patternRanking(songID: songID,
                                                          contexts: patternContexts,
                                                          analysis: analysis,
                                                          difficulty: request.difficulty) {
                for r in ranked where r.variant < 3 {
                    if r.variant >= preplanned.count { continue }
                    preplanned[r.variant].rankings[r.phraseIndex] = r
                }
            }
        } else {
            for candidate in 0..<3 {
                preplanned.append(Self.preplan(analysis: analysis, request: request,
                                               eventImportance: eventImportanceOverride,
                                               variant: candidate, wantContexts: false).planned)
            }
        }
        // Cooperative cancellation: a superseded regeneration (newer analysis,
        // difficulty change, song switch) stops between tiers instead of
        // finishing its remaining work — the generation gate already prevents
        // the result from landing.
        try Task.checkCancellation()

        let constraints = ChartConstraints.forDifficulty(request.difficulty, densityMultiplier: request.densityMultiplier)

        // TIER 1 — three seeded candidate arrangements; the quality scorer
        // picks the best. Deterministic: same inputs → same candidates → same
        // winner. Candidate rejection is an internal outcome: if ALL of them
        // fail validation (even after repair), the generator degrades to
        // tier 2 instead of failing the song.
        if ProcessInfo.processInfo.environment["CHARTGEN_LOG"] != nil { FileHandle.standardError.write("CG:start d=\(request.difficulty.rawValue) ev=\(analysis.events.count) beats=\(analysis.beats.count)\n".data(using: .utf8)!) }
        var best = pickBestCandidate(analysis: analysis, songID: songID, request: request,
                                     eventImportance: eventImportanceOverride,
                                     preplanned: preplanned, constraints: constraints,
                                     started: started, lastReason: &lastReason)
        var fallbackTier = 1

        // TIER 2 — relaxed constraints, same seeded candidates. Spacing and
        // jump floors loosen so a grid that is merely *tight* (double-beat
        // detections, very fast tempos) still yields a playable chart.
        try Task.checkCancellation()
        if best == nil {
            let relaxed = ChartConstraints(
                minSpacing: min(0.12, constraints.minSpacing * 1.5),
                maxNPS: max(6, constraints.maxNPS),
                maxSimultaneous: constraints.maxSimultaneous,
                minSameLaneGap: 0.11,
                maxJump: 3,
                minGapForJump2: 0.20,
                minGapForJump3: 0.40,
                maxSpikeRatio: constraints.maxSpikeRatio)
            best = pickBestCandidate(analysis: analysis, songID: songID, request: request,
                                     eventImportance: eventImportanceOverride,
                                     preplanned: preplanned, constraints: relaxed,
                                     started: started, lastReason: &lastReason)
            fallbackTier = 2
        }

        // TIER 3 — legacy per-cell selection over the musical grid (works with
        // the synthetic tempo grid / raw event ticks when beats are unusable).
        try Task.checkCancellation()
        if best == nil {
            let legacyPlan = Self.preplan(analysis: analysis, request: request,
                                          eventImportance: eventImportanceOverride,
                                          variant: 0, wantContexts: false, forceLegacy: true).planned
            best = pickBestCandidate(analysis: analysis, songID: songID, request: request,
                                     eventImportance: eventImportanceOverride,
                                     preplanned: [legacyPlan], constraints: constraints,
                                     started: started, lastReason: &lastReason,
                                     forceLegacy: true)
            fallbackTier = 3
        }

        // TIER 4 — minimal deterministic quarter-note grid over the detected
        // beats. The absolute floor: accessible audio always gets a playable
        // chart, never a dead-end error.
        try Task.checkCancellation()
        if best == nil {
            if let minimal = minimalFallbackChart(analysis: analysis, songID: songID,
                                                  request: request, started: started) {
                best = (minimal, 0)
                fallbackTier = 4
            }
        }

        guard let best else {
            throw ChartGenerationError.unableToGenerate(lastReason)
        }
        if ProcessInfo.processInfo.environment["CHARTGEN_LOG"] != nil { FileHandle.standardError.write("CG:winner tier=\(fallbackTier) notes=\(best.output.chart.notes.count)\n".data(using: .utf8)!) }

        // AI difficulty fusion runs ONCE, on the winning chart: one inference
        // per generation, and the advisor contract stays a single consultation
        // (the same result the deterministic path would have produced).
        var winner = best.output
        if let advisor,
           let outcome = await advisor.difficultyOutcome(songID: songID,
                                                         notes: winner.chart.notes,
                                                         metrics: winner.metrics,
                                                         analysis: analysis) {
            winner.chart.difficultyScore = outcome.finalScore
            winner.chart.deterministicDifficultyScore = outcome.deterministicScore
            if outcome.usedAI {
                winner.chart.aiDifficultyScore = outcome.aiScore
                winner.chart.aiDifficultyConfidence = outcome.aiConfidence
                winner.chart.aiModelVersion = outcome.modelVersion
            }
        }
        // Final safety layer: sanitize before anything can persist/play the
        // chart (drops non-finite/out-of-range notes, clamps, re-ids, sorts).
        var sanitized = winner.chart.sanitized(songDuration: analysis.duration)
        let dropped = winner.chart.notes.count - sanitized.notes.count
        if dropped > 0 {
            sanitized.repairCount = (sanitized.repairCount ?? 0) + dropped
        }
        sanitized.fallbackTier = fallbackTier
        winner.chart = sanitized
        winner.fallbackTier = fallbackTier
        return winner
    }

    // MARK: - Candidate evaluation (shared by the fallback tiers)

    /// Runs the seeded candidate arrangements, validates/repairs each under
    /// `constraints`, and returns the best-scoring survivor (nil = none).
    /// Shared by tier 1 (strict), tier 2 (relaxed) and tier 3 (legacy).
    private func pickBestCandidate(analysis: AudioAnalysis, songID: UUID,
                                   request: Request, eventImportance: [Double]?,
                                   preplanned: [PreplannedPhrases],
                                   constraints: ChartConstraints,
                                   started: Date, lastReason: inout String,
                                   forceLegacy: Bool = false) -> (output: Output, quality: Double)? {
        var best: (output: Output, quality: Double)?
        for candidate in 0..<preplanned.count {
            if Task.isCancelled { break }   // superseded — unwind promptly
            let seed = request.seed &+ UInt64(candidate * 101)
            var rng = SplitMix64(state: seed)
            let built = buildNotes(analysis: analysis, request: request, rng: &rng,
                                   eventImportance: eventImportance, variant: candidate,
                                   preplanned: preplanned[candidate], forceLegacy: forceLegacy)
            var finalNotes = built.notes
            if ProcessInfo.processInfo.environment["CHARTGEN_LOG"] != nil { FileHandle.standardError.write("CG:cand \(candidate) built=\(finalNotes.count)\n".data(using: .utf8)!) }
            var repairCount = 0
            var validation = ChartValidator.validate(finalNotes, constraints: constraints)
            if validation.hardFailureCount > 0 {
                let repaired = ChartValidator.repair(finalNotes, constraints: constraints)
                repairCount = finalNotes.count - repaired.count
                finalNotes = repaired
                validation = ChartValidator.validate(finalNotes, constraints: constraints)
            }
            if validation.hardFailureCount > 0 {
                lastReason = "candidate \(candidate + 1) unplayable: \(validation.hardFailures.first ?? "validation failed")"
                if ProcessInfo.processInfo.environment["CHARTGEN_LOG"] != nil {
                    FileHandle.standardError.write("CG:FAIL \(request.difficulty.rawValue) cand=\(candidate) notes=\(finalNotes.count) : \(validation.hardFailures.prefix(4).joined(separator: " | "))\n".data(using: .utf8)!)
                }
                continue
            }

            if ProcessInfo.processInfo.environment["CHARTGEN_LOG"] != nil { FileHandle.standardError.write("CG:cand \(candidate) after-validate=\(finalNotes.count) fails=\(validation.hardFailureCount)\n".data(using: .utf8)!) }
            let metrics = ChartDifficultyAnalyzer.analyze(notes: finalNotes, duration: analysis.duration)
            if ProcessInfo.processInfo.environment["CHARTGEN_LOG"] != nil { FileHandle.standardError.write("CG:metrics ok\n".data(using: .utf8)!) }

            let quality = ChartQualityScorer.score(notes: finalNotes, analysis: analysis,
                                                   difficulty: request.difficulty,
                                                   phrases: built.phrases,
                                                   sections: analysis.sections)
            if ProcessInfo.processInfo.environment["CHARTGEN_LOG"] != nil { FileHandle.standardError.write("CG:quality \(String(format: "%.2f", quality.score))\n".data(using: .utf8)!) }
            let chart = Chart(songID: songID,
                              difficulty: request.difficulty,
                              chartVersion: Self.currentVersion,
                              seed: seed,
                              notes: finalNotes,
                              generatedAt: Date(),
                              nps: metrics.notesPerSecond,
                              duration: analysis.duration,
                              difficultyScore: metrics.score10,
                              validationWarnings: validation.warnings,
                              generationDuration: Date().timeIntervalSince(started),
                              qualityScore: quality.score,
                              repairCount: repairCount)
            let output = Output(chart: chart, metrics: metrics, validationWarnings: validation.warnings)
            if best == nil || quality.score > best!.quality {
                best = (output, quality.score)
            }
        }
        return best
    }

    /// Tier-4 floor: a sparse but valid chart on the detected beats (or the
    /// synthetic grid). NOT a raw round-robin dump: selection prioritizes
    /// strong/strong beats over weak ones, keeps a readable minimum spacing,
    /// and lanes come from the same pattern-aware `PatternGenerator` the main
    /// pipeline uses (walks/alternation/balance) instead of 1→2→3→4 cycling.
    /// Always passes the validator by construction; nil only when no
    /// beat/event data exists at all (true silence — every tier then fails
    /// and the caller reports it).
    private func minimalFallbackChart(analysis: AudioAnalysis, songID: UUID,
                                      request: Request,
                                      started: Date) -> Output? {
        let playStart = 0.4
        let playEnd = max(analysis.duration - 1.2, playStart + 1)
        var beats = analysis.beats.filter { $0.time >= playStart && $0.time <= playEnd }
        if beats.count < 2 {
            beats = fallbackBeatGrid(analysis: analysis, minSpacing: 0.1)
                .filter { $0.time >= playStart && $0.time <= playEnd }
        }
        guard !beats.isEmpty else { return nil }
        // Accent-prioritized selection: walk beats in time order; a beat is
        // kept only if it clears the spacing AND is locally the strongest
        // candidate (strong beats outrank weak ones within the spacing
        // window, so a grid that double-detects never double-places).
        let selected = Self.selectAccentBeats(beats, minSpacing: 0.18)
        guard !selected.isEmpty else { return nil }
        // Pattern-aware lanes (walks, alternation, balance) with the same
        // seeded determinism as the main pipeline.
        var rng = SplitMix64(state: request.seed &+ 0x9E37_79B9)
        let placed = selected.map { (time: $0.time, strength: $0.strength, allowPair: false) }
        let notes = PatternGenerator.assignLanes(to: placed, rng: &rng)
            .sorted { $0.time < $1.time }
            .enumerated()
            .map { index, note in
                ChartNote(id: index, time: note.time, lane: note.lane, duration: 0,
                          type: .tap, strength: note.strength)
            }
        let constraints = ChartConstraints.forDifficulty(request.difficulty,
                                                         densityMultiplier: request.densityMultiplier)
        let validation = ChartValidator.validate(notes, constraints: constraints)
        let metrics = ChartDifficultyAnalyzer.analyze(notes: notes, duration: analysis.duration)
        let chart = Chart(songID: songID,
                          difficulty: request.difficulty,
                          chartVersion: Self.currentVersion,
                          seed: request.seed,
                          notes: notes,
                          generatedAt: Date(),
                          nps: metrics.notesPerSecond,
                          duration: analysis.duration,
                          difficultyScore: metrics.score10,
                          validationWarnings: validation.warnings,
                          generationDuration: Date().timeIntervalSince(started),
                          qualityScore: 0,
                          repairCount: 0)
        return Output(chart: chart, metrics: metrics, validationWarnings: validation.warnings)
    }

    // MARK: - Plan pass

    /// Deterministic plan pass for one candidate arrangement: builds the
    /// phrase grid and runs the exact template/motif/start-lane decision
    /// sequence. When `wantContexts`, also builds the AI ranking contexts
    /// (candidates + features) — shared with the training exporter so runtime
    /// and training features can never drift apart.
    static func preplan(analysis: AudioAnalysis, request: Request,
                        eventImportance: [Double]?, variant: Int,
                        wantContexts: Bool,
                        forceLegacy: Bool = false) -> (planned: PreplannedPhrases, contexts: [PatternRankingContext]) {
        let difficulty = request.difficulty
        let nps = difficulty.targetNPS * request.densityMultiplier
        let playStart = 0.4
        let playEnd = max(analysis.duration - 1.2, playStart + 1)
        let sectionData = SectionProfile(analysis.sections)
        var phrases = PhraseSequencer.buildPhrases(beats: analysis.beats,
                                                   playStart: playStart, playEnd: playEnd,
                                                   energyAt: sectionData.energy)
        guard !phrases.isEmpty, !Self.forceLegacySelection, !forceLegacy else {
            return (PreplannedPhrases(phrases: [], plans: [], rankings: [:]), [])
        }
        // NOTE: the per-phrase prng is seeded from `request.seed` directly —
        // the `variant * 101` adjustment applies to the OUTER lane-assignment
        // rng only, never to the phrase decisions. Changing this would alter
        // every deterministic chart.
        let active = analysis.events.enumerated().compactMap { idx, event in
            event.time >= playStart - 0.1 && event.time <= playEnd + 0.1 ? (index: idx, event: event) : nil
        }
        let plans = PhraseSequencer.decidePlans(phrases: &phrases,
                                                activeEvents: active.map { $0.event },
                                                targetNPS: nps, difficulty: difficulty,
                                                seed: request.seed, variant: variant,
                                                factorAt: sectionData.factor)
        let planned = PreplannedPhrases(phrases: phrases, plans: plans, rankings: [:])
        guard wantContexts else { return (planned, []) }
        let contexts = PatternRankingBuilder.contexts(phrases: phrases, plans: plans,
                                                      events: analysis.events, variant: variant,
                                                      difficulty: difficulty, targetNPS: nps,
                                                      duration: analysis.duration)
        return (planned, contexts)
    }

    // MARK: - Musical grid

    /// One candidate slot on the musical subdivision grid.
    private struct GridTick {
        var time: Double
        var score: Double        // onset support + beat accent, 0…∞ (relative)
        var isBeat: Bool         // aligned to a detected beat
        var isDownbeat: Bool     // aligned to a strong beat
        var beatStrength: Double
        var chordSupport: Int    // distinct musical events near the tick

        /// Chart strength for a placed note, scaled out of the raw score.
        func strengthOrScore() -> Double {
            min(1, max(0.25, score * 1.2))
        }
    }

    /// Subdivision grid built by interpolating between *detected* beats.
    /// Interpolation (not a global tempo grid) keeps the chart locked to the
    /// song even when its pulse drifts slightly.
    private struct MusicalGrid {
        let ticks: [GridTick]

        /// subdivision: 2 = eighth notes, 4 = sixteenths, etc. relative to the
        /// beat. Chosen so the finest slot is comfortably below the difficulty's
        /// minimum spacing — we *accept* notes at ≥ minSpacing, the grid merely
        /// offers musical candidates.
        init(beats: [Beat], minSpacing: Double) {
            guard beats.count >= 2 else {
                ticks = []
                return
            }
            // Downbeat set (strong beats or local prominence peaks).
            var downbeats: Set<Double> = []
            for (i, beat) in beats.enumerated() {
                let prev = i > 0 ? beats[i - 1].strength : 0
                let next = i < beats.count - 1 ? beats[i + 1].strength : 0
                if beat.isStrong || (beat.strength > 0.6 && beat.strength >= prev && beat.strength > next * 0.85) {
                    downbeats.insert(beat.time)
                }
            }
            let beatInterval = beats[1].time - beats[0].time
            var subdiv = 2
            while subdiv < 8 && beatInterval / Double(subdiv) > minSpacing * 0.75 {
                subdiv *= 2
            }

            var raw: [GridTick] = []
            raw.reserveCapacity(beats.count * subdiv)
            for i in 0..<(beats.count - 1) {
                let start = beats[i], end = beats[i + 1]
                let step = (end.time - start.time) / Double(subdiv)
                for k in 0..<subdiv {
                    let time = start.time + step * Double(k)
                    if k == 0 {
                        // The beat itself.
                        raw.append(GridTick(time: time, score: start.strength, isBeat: true,
                                            isDownbeat: downbeats.contains(start.time),
                                            beatStrength: start.strength, chordSupport: 0))
                    } else {
                        raw.append(GridTick(time: time, score: 0, isBeat: false,
                                            isDownbeat: false, beatStrength: 0, chordSupport: 0))
                    }
                }
            }
            // Final beat closes the grid.
            if let last = beats.last {
                raw.append(GridTick(time: last.time, score: last.strength, isBeat: true,
                                    isDownbeat: downbeats.contains(last.time),
                                    beatStrength: last.strength, chordSupport: 0))
            }
            ticks = raw
        }
    }

    // MARK: - Selection + density control

    /// True when an event list is already ordered by time — avoids a defensive
    /// re-sort on the common analyzer output (events arrive time-sorted).
    private static func isSortedByTime(_ list: [(index: Int, event: MusicalEvent)]) -> Bool {
        guard list.count > 1 else { return true }
        for i in 1..<list.count where list[i].event.time < list[i - 1].event.time {
            return false
        }
        return true
    }

    private struct Placed {
        var time: Double
        var strength: Double
        var allowPair: Bool
    }

    private func buildNotes(analysis: AudioAnalysis, request: Request, rng: inout SplitMix64,
                            eventImportance: [Double]?, variant: Int,
                            preplanned: PreplannedPhrases,
                            forceLegacy: Bool = false) -> (notes: [ChartNote], phrases: [Phrase]) {
        let difficulty = request.difficulty
        let nps = difficulty.targetNPS * request.densityMultiplier
        let minSpacing = max(difficulty.minSpacing, 0.045)
        let playStart = 0.4
        let playEnd = max(analysis.duration - 1.2, playStart + 1)

        // Density shaping: per-second note budget at any moment = nps × local
        // factor. The factor blends the section label (intro sparse, chorus
        // dense) with the section's *measured* energy, clamped to a sane band.
        let sectionData = SectionProfile(analysis.sections)

        // 1) Candidate grid (falls back to a synthetic tempo grid when no beats
        //    were tracked, and to raw event times when no tempo exists at all —
        //    every supported song still charts deterministically).
        var grid = MusicalGrid(beats: analysis.beats, minSpacing: minSpacing)
        if grid.ticks.isEmpty {
            grid = MusicalGrid(beats: fallbackBeatGrid(analysis: analysis, minSpacing: minSpacing), minSpacing: minSpacing)
        }
        var scored: [GridTick] = grid.ticks
        if scored.isEmpty {
            // Last resort: each event is its own candidate tick (no grid).
            scored = analysis.events.enumerated().map { idx, event in
                let importance = eventImportance?[idx] ?? event.importance
                return GridTick(time: event.time, score: importance * event.strength, isBeat: false,
                                isDownbeat: false, beatStrength: 0, chordSupport: 1)
            }
            scored.sort { $0.time < $1.time }
        }

        // 2) Project onset support onto the grid ticks. The AI override (when
        //    present) replaces the DSP importance per event; nil = DSP value.
        var active: [(index: Int, event: MusicalEvent)] = analysis.events.enumerated().compactMap { idx, event in
            event.time >= playStart - 0.1 && event.time <= playEnd + 0.1 ? (idx, event) : nil
        }
        let stepGuess = scored.count > 1
            ? max(scored[1].time - scored[0].time, minSpacing * 0.5)
            : minSpacing
        // Project onset support onto the grid ticks. Both lists are sorted by
        // time (the analyzer sorts events; scored comes from the beat grid), so
        // a single sweep replaces the former O(ticks × events) full scan — the
        // dominant cost on long songs. Accumulation order is unchanged, so
        // output stays bit-identical.
        if !Self.isSortedByTime(active) {
            active.sort { $0.event.time < $1.event.time }
        }
        let supportWindow = stepGuess * 0.55
        var eventPtr = 0
        for k in scored.indices {
            var score = scored[k].score * 0.4     // beat baseline
            var support = 0
            let tickTime = scored[k].time
            while eventPtr < active.count && active[eventPtr].event.time < tickTime - supportWindow {
                eventPtr += 1
            }
            var j = eventPtr
            while j < active.count && active[j].event.time <= tickTime + supportWindow {
                let dist = abs(active[j].event.time - tickTime)
                let proximity = 1 - dist / supportWindow
                let importance = eventImportance?[active[j].index] ?? active[j].event.importance
                score += importance * active[j].event.strength * proximity
                support += 1
                j += 1
            }
            // Beat accents keep a small baseline so quiet passages still get
            // tiles, but they must stay BELOW real onset support: a tile is
            // always placed preferentially where the music actually sounds
            // (Magic Tiles 3 sync). The old 0.9/0.35 baselines let silent,
            // estimated beats outrank nearby audible hits.
            if scored[k].isDownbeat { score += scored[k].beatStrength * 0.3 }
            else if scored[k].isBeat { score += scored[k].beatStrength * 0.12 }
            scored[k].score = score
            scored[k].chordSupport = support
        }

        // 3) Phrase-pattern selection (v4) — the intentional path. Used when
        //    the beat grid gives us real phrases to compose with. The phrases
        //    arrive pre-planned (slot scores + template/motif/start lane) from
        //    `generate`, optionally re-ranked by the AI advisor.
        let phrases = preplanned.phrases
        if !phrases.isEmpty, !scored.isEmpty, !Self.forceLegacySelection, !forceLegacy {
            return selectWithPatterns(analysis: analysis, request: request,
                                      scored: scored, phrases: phrases,
                                      playStart: playStart, playEnd: playEnd,
                                      minSpacing: minSpacing, seed: request.seed,
                                      rng: &rng,
                                      plans: preplanned.plans,
                                      rankings: preplanned.rankings)
        }

        // 4) Legacy per-cell selection (beat-less / ambient material): the v3
        //    cell-march + catch-up, unchanged.
        return selectLegacy(analysis: analysis, request: request, scored: scored,
                            sectionData: sectionData, playStart: playStart, playEnd: playEnd,
                            nps: nps, minSpacing: minSpacing, rng: &rng)
    }

    // MARK: - Phrase-pattern selection (v4)

    private func selectWithPatterns(analysis: AudioAnalysis, request: Request,
                                    scored: [GridTick], phrases: [Phrase],
                                    playStart: Double, playEnd: Double,
                                    minSpacing: Double, seed: UInt64,
                                    rng: inout SplitMix64,
                                    plans: [PhrasePlan],
                                    rankings: [Int: PatternRanking]) -> (notes: [ChartNote], phrases: [Phrase]) {
        let difficulty = request.difficulty
        var selected: [Placed] = []
        var preferredLanes: [Int?] = []
        var phrases = phrases
        var lastPlaced = -Double.infinity
        var lastChordRoot = -Double.infinity

        for pi in phrases.indices {
            var phrase = phrases[pi]
            let plan = plans[pi]
            // The deterministic plan, optionally re-ranked by the AI advisor:
            // a decisive AI pick swaps in one of the phrase's candidate
            // patterns; anything else (no advisor, low confidence, missing
            // entry) keeps the plan exactly as decided.
            var template = plan.template
            var motif = plan.motif
            var startLane = plan.startLane
            if let ranking = rankings[pi],
               let chosen = ranking.chosenIndex,
               ranking.candidates.indices.contains(chosen) {
                let candidate = ranking.candidates[chosen]
                template = candidate.template
                motif = candidate.motif
                startLane = candidate.startLane
            }
            let quiet = plan.quiet
            let targetSlots = plan.targetSlots

            let step = phrase.beatLength / 4
            let noteStart = selected.count
            var noteInPhrase = 0
            // Higher difficulties chart weaker subdivisions (16th pushes) that
            // easy charts leave alone — keeps density monotonic with difficulty
            // while the music's support decides what actually qualifies.
            let floorScale = max(0.22, 0.30 - min(0.10, (difficulty.targetNPS - 4.0) * 0.02))

            for slot in template.slots {
                let t = phrase.slotTimes[slot]
                guard t >= playStart, t <= playEnd else { continue }
                if template == .rest { continue }

                // Snap FIRST, then spacing-check the snapped time — otherwise
                // grid snapping pulls notes closer than the difficulty's
                // minimum and the validator has to repair them away.
                let snapped = bestTickNear(t, step: step, scored: scored)
                let time = snapped?.time ?? t
                guard time - lastPlaced >= minSpacing else { continue }
                let scoreAt = snapped?.score ?? phrase.slotScores[slot]

                // Accent rule: template downbeats chart even with thin onset
                // support; everything else needs the acceptance floor.
                let isDownbeat = slot % 4 == 0
                let accent = isDownbeat && (phrase.slotScores[slot] >= 0.5 || (snapped?.isDownbeat ?? false))
                let floor = quiet ? 0.45 : floorScale
                if !accent, scoreAt < floor { continue }

                // Chord opportunity on supported downbeats (difficulty-gated).
                let chordOK = isDownbeat
                    && (snapped?.chordSupport ?? 0) >= 1
                    && difficulty.maxSimultaneous > 1
                    && time - lastChordRoot >= 0.34
                    && !quiet
                if chordOK { lastChordRoot = time }

                selected.append(Placed(time: time,
                                       strength: snapped?.strengthOrScore() ?? min(1, max(0.25, scoreAt * 1.2)),
                                       allowPair: chordOK))
                preferredLanes.append(motif.preferredLane(startLane: startLane, noteIndex: noteInPhrase))
                if chordOK {
                    selected.append(Placed(time: time,
                                           strength: (snapped?.strengthOrScore() ?? 0.5) * 0.9,
                                           allowPair: false))
                    preferredLanes.append(nil)
                }
                noteInPhrase += 1
                lastPlaced = time
            }

            // Gentle catch-up inside the phrase when the template under-fills
            // the budget on supportive material. Restful templates stay restful.
            // The catch-up floor is RELAXED and difficulty-scaled: easy/medium
            // keep the strict accent gate, while higher difficulties may add
            // supported-but-weak 16th pushes (the odd slots' beat baseline).
            // The difficulty's minSpacing still gates them at slower tempos, and
            // targetSlots bounds the total — the push layer can never turn into
            // an onset dump.
            if !template.isRestful, selected.count - noteStart < targetSlots {
                let floor = quiet ? 0.45 : max(0.12, 0.30 - min(0.18, (difficulty.targetNPS - 2.0) * 0.04))
                // TIME order, not score order, so interleaved pushes (16ths
                // between the template's quarters) are inserted at their
                // musical position with correct spacing both sides.
                let remaining = (0..<16)
                    .filter { !template.slots.contains($0) && phrase.slotScores[$0] >= floor }
                for slot in remaining.sorted() {
                    guard selected.count - noteStart < targetSlots else { break }
                    let time = bestTickNear(phrase.slotTimes[slot], step: step, scored: scored)?.time ?? phrase.slotTimes[slot]
                    var lo = 0, hi = selected.count
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if selected[mid].time < time { lo = mid + 1 } else { hi = mid }
                    }
                    let prevOK = lo == 0 || time - selected[lo - 1].time >= minSpacing
                    let nextOK = lo == selected.count || selected[lo].time - time >= minSpacing
                    guard prevOK, nextOK else { continue }
                    selected.insert(Placed(time: time, strength: 0.5, allowPair: false), at: lo)
                    preferredLanes.insert(nil, at: lo)
                }
            }

            if ProcessInfo.processInfo.environment["CHARTGEN_LOG"] != nil { FileHandle.standardError.write("CG:phrase \(pi) t=\(template.rawValue) target=\(targetSlots) placed=\(selected.count - noteStart) scores=\(phrase.slotScores.prefix(8).map { String(format: "%.2f", $0) }.joined(separator: ","))\n".data(using: .utf8)!) }
            phrase.noteIndices = noteStart..<selected.count
            phrase.template = template
            phrase.motif = motif
            phrase.startLane = startLane
            phrases[pi] = phrase
        }

        // Lane assignment with motifs, hold pass, chronological sort.
        let placed = selected.map { ($0.time, $0.strength, $0.allowPair) }
        let assigned = PatternGenerator.assignLanes(to: placed, rng: &rng, preferredLanes: preferredLanes)
            .sorted { $0.time < $1.time }
        let withHolds = HoldGenerator.apply(to: assigned, analysis: analysis,
                                            difficulty: difficulty, seed: seed, playEnd: playEnd)
        return (withHolds, phrases)
    }

    /// Grid tick to place a note on, chosen so tiles land where the music
    /// actually sounds (Magic Tiles 3 sync). Within `step * 0.75` of the
    /// template slot: the highest-onset-support tick wins; near-ties break to
    /// the tick NEAREST the slot (pure grid timing). The old pick could land
    /// on a louder-but-distant grid neighbor even when an audible onset sat
    /// exactly on the slot — the "tiles don't match the song" feel.
    private func bestTickNear(_ t: Double, step: Double, scored: [GridTick]) -> GridTick? {
        var lo = 0, hi = scored.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if scored[mid].time < t - step * 0.75 { lo = mid + 1 } else { hi = mid }
        }
        var best: GridTick?
        var i = lo
        while i < scored.count, scored[i].time <= t + step * 0.75 {
            if let current = best {
                let epsilon = 0.01
                if scored[i].score > current.score + epsilon {
                    best = scored[i]
                } else if abs(scored[i].score - current.score) <= epsilon
                            && abs(scored[i].time - t) < abs(current.time - t) {
                    best = scored[i]
                }
            } else {
                best = scored[i]
            }
            i += 1
        }
        return best
    }

    // MARK: - Legacy selection (beat-less / ambient fallback, v3 behavior)

    private func selectLegacy(analysis: AudioAnalysis, request: Request, scored: [GridTick],
                              sectionData: SectionProfile, playStart: Double, playEnd: Double,
                              nps: Double, minSpacing: Double, rng: inout SplitMix64) -> (notes: [ChartNote], phrases: [Phrase]) {
        let difficulty = request.difficulty
        var selected: [Placed] = []
        func insertPlaced(_ placed: Placed) {
            var lo = 0, hi = selected.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if selected[mid].time < placed.time { lo = mid + 1 } else { hi = mid }
            }
            selected.insert(placed, at: lo)
        }

        var i = 0
        while i < scored.count, scored[i].time < playStart { i += 1 }
        var lastPlaced = -Double.infinity
        var lastChordRoot = -Double.infinity
        var skippedBudget = 0

        while i < scored.count {
            let tick = scored[i]
            guard tick.time <= playEnd else { break }
            let factor = sectionData.factor(at: tick.time)
            let baseGap = 1.0 / max(0.5, nps * factor)

            var bestIdx = i
            var bestScore = scored[i].score
            var j = i + 1
            while j < scored.count, scored[j].time <= tick.time + baseGap {
                if scored[j].score > bestScore + 0.0001 { bestIdx = j; bestScore = scored[j].score }
                j += 1
            }
            let pick = scored[bestIdx]

            i = j
            guard pick.time >= playStart, pick.time <= playEnd else { continue }

            let gapOK = pick.time - lastPlaced >= minSpacing
            let quiet = sectionData.energy(at: pick.time) < 0.3
            let floor = quiet ? 0.45 : 0.30

            let accent = pick.isDownbeat && pick.beatStrength >= 0.45 && !quiet
            if gapOK && (accent || pick.score >= floor) {
                let chordOK = pick.isDownbeat
                    && pick.chordSupport >= 1
                    && difficulty.maxSimultaneous > 1
                    && pick.time - lastChordRoot >= 0.34
                    && sectionData.energy(at: pick.time) >= 0.45
                let allowPair = chordOK
                if chordOK { lastChordRoot = pick.time }

                insertPlaced(Placed(time: pick.time, strength: pick.strengthOrScore(), allowPair: allowPair))
                if chordOK {
                    insertPlaced(Placed(time: pick.time, strength: pick.strengthOrScore() * 0.9,
                                        allowPair: false))
                }
                lastPlaced = pick.time
            } else {
                skippedBudget += 1
            }
        }

        func canInsertFill(_ time: Double) -> Bool {
            guard time >= playStart, time <= playEnd else { return false }
            var lo = 0, hi = selected.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if selected[mid].time < time { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0, time - selected[lo - 1].time < minSpacing { return false }
            if lo < selected.count, selected[lo].time - time < minSpacing { return false }
            return true
        }
        let expected = nps * sectionData.integratedFactor(from: playStart, to: playEnd, duration: analysis.duration)
            * max(playEnd - playStart, 1)
        let placedCount = selected.count
        if placedCount < Int(expected * 0.9), !scored.isEmpty {
            let fillTarget = min(Int(expected), scored.count * 2)
            var k = 0
            while k < scored.count, selected.count < fillTarget {
                let tick = scored[k]
                if tick.isBeat, canInsertFill(tick.time) {
                    insertPlaced(Placed(time: tick.time,
                                        strength: tick.beatStrength > 0 ? min(1, tick.beatStrength) : 0.5,
                                        allowPair: false))
                }
                k += 1
            }
            if selected.count < fillTarget {
                var rest = scored.filter { !$0.isBeat }
                rest.sort { $0.score > $1.score }
                for tick in rest where selected.count < fillTarget {
                    if canInsertFill(tick.time) {
                        insertPlaced(Placed(time: tick.time, strength: tick.strengthOrScore(), allowPair: false))
                    }
                }
            }
        }
        _ = skippedBudget   // (reserved for future quiet-intro shaping)

        let placed = selected.map { ($0.time, $0.strength, $0.allowPair) }
        let assigned = PatternGenerator.assignLanes(to: placed, rng: &rng)
            .sorted { $0.time < $1.time }
        let withHolds = HoldGenerator.apply(to: assigned, analysis: analysis,
                                            difficulty: difficulty, seed: request.seed, playEnd: playEnd)
        return (withHolds, [])
    }

    /// Accent-prioritized beat selection for fallback charts: strong beats
    /// outrank weak ones within the minimum-spacing window, and the result
    /// never places two notes closer than `minSpacing`. Pure + deterministic
    /// (unit-tested); returns empty only for empty input.
    static func selectAccentBeats(_ beats: [Beat], minSpacing: Double) -> [(time: Double, strength: Double)] {
        var selected: [(time: Double, strength: Double)] = []
        var i = 0
        while i < beats.count {
            var bestIdx = i
            var bestStrength = beats[i].strength + (beats[i].isStrong ? 0.35 : 0)
            var j = i + 1
            let windowEnd = selected.last.map { $0.time + minSpacing } ?? -Double.infinity
            while j < beats.count, beats[j].time <= max(beats[i].time + minSpacing, windowEnd) {
                let s = beats[j].strength + (beats[j].isStrong ? 0.35 : 0)
                if s > bestStrength + 0.0001 { bestIdx = j; bestStrength = s }
                j += 1
            }
            let pick = beats[bestIdx]
            i = j
            if let last = selected.last, pick.time - last.time < minSpacing { continue }
            selected.append((pick.time,
                             min(1, max(0.3, pick.strength * 0.9 + (pick.isStrong ? 0.2 : 0)))))
        }
        return selected
    }

    /// Even grid over the whole song when no beats were detected but a tempo
    /// exists; otherwise empty (caller falls back to raw behavior).
    private func fallbackBeatGrid(analysis: AudioAnalysis, minSpacing: Double) -> [Beat] {
        guard let bpm = analysis.tempoBPM, bpm > 20, bpm < 300 else { return [] }
        guard let first = analysis.events.first?.time else { return [] }
        let interval = 60.0 / bpm
        var beats: [Beat] = []
        var t = first
        var count = 0
        while t <= analysis.duration - 1.0 {
            beats.append(Beat(time: t, strength: 0.5, isStrong: count % 4 == 0))
            t += interval
            count += 1
        }
        return beats
    }
}

/// Section-aware density shaping: label factor × measured energy, both clamped,
/// with an integrated average for budget math. Pure/deterministic.
private struct SectionProfile {
    private let sections: [SongSection]

    init(_ sections: [SongSection]) {
        self.sections = sections.sorted { $0.start < $1.start }
    }

    private func section(at time: Double) -> SongSection? {
        sections.first { time >= $0.start && time < $0.end }
    }

    private static func labelFactor(_ label: SectionLabel) -> Double {
        switch label {
        case .intro: return 0.55
        case .verse: return 0.85
        case .chorus: return 1.10
        case .bridge: return 0.75
        case .breakdown: return 0.60
        case .outro: return 0.40
        case .generic: return 0.9
        }
    }

    func energy(at time: Double) -> Double {
        section(at: time)?.energy ?? 0.5
    }

    /// Density multiplier for a moment: label bias × energy, clamped to keep
    /// local density inside the validator's global cap.
    func factor(at time: Double) -> Double {
        guard let section = section(at: time) else { return 0.85 }
        let energyWeight = 0.45 + 0.55 * section.energy   // 0.45…1.0
        return min(1.0, max(0.25, Self.labelFactor(section.label) * energyWeight))
    }

    /// Mean factor weighted by section length — the density budget multiplier.
    func integratedFactor(from start: Double, to end: Double, duration: Double) -> Double {
        guard !sections.isEmpty, end > start else { return 0.85 }
        var weighted = 0.0
        var lengthSum = 0.0
        for section in sections {
            let a = max(start, section.start)
            let b = min(end, section.end)
            let len = max(0, b - a)
            if len > 0 {
                weighted += factor(at: section.start + (section.end - section.start) / 2) * len
                lengthSum += len
            }
        }
        if lengthSum <= 0 { return 0.85 }
        return max(0.3, weighted / lengthSum)
    }
}