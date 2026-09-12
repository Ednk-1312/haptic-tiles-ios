import Foundation

/// Sixteenth-note rhythm templates over a 4-beat phrase (16 slots). These are
/// the musical vocabularies the generator composes with — a chart is a string
/// of templates, chosen deterministically from what the music actually does,
/// not a per-onset decision.
enum RhythmTemplate: String, Codable, Sendable, CaseIterable {
    case rest               // deliberate silence (empty phrase)
    case downbeatOnly       // just the downbeat
    case quarterTwoFour     // beats 1 & 3
    case quarterAccents     // all four beats
    case eighthsHalf        // groove with the 2- and 4- "ands" skipped
    case eighthsSteady      // full eighth-note groove
    case syncopated         // off-beat pushes (with a grounding downbeat)
    case burst              // 16th-note burst on beat 1, beat 3 breathes
    case callResponse       // call on beats 1-2, echo on beat 4

    /// Sixteenth-note slot indices (0…15) within the phrase.
    var slots: [Int] {
        switch self {
        case .rest: return []
        case .downbeatOnly: return [0]
        case .quarterTwoFour: return [0, 8]
        case .quarterAccents: return [0, 4, 8, 12]
        case .eighthsHalf: return [0, 2, 6, 8, 10, 14]
        case .eighthsSteady: return [0, 2, 4, 6, 8, 10, 12, 14]
        case .syncopated: return [0, 1, 5, 9, 13]
        case .burst: return [0, 1, 2, 8]
        case .callResponse: return [0, 2, 12, 14]
        }
    }

    /// A phrase with no (or almost no) notes — the "wait" moment.
    var isRestful: Bool { self == .rest || self == .downbeatOnly }

    /// Template whose 16-slot mask best matches an actual note pattern; used
    /// by the analytics to classify what a chart's phrases did.
    static func closest(toMask mask: UInt16, phraseLength: Int) -> RhythmTemplate {
        var best: RhythmTemplate = .rest
        var bestOverlap = -1
        for t in RhythmTemplate.allCases {
            var tMask: UInt16 = 0
            for slot in t.slots where slot < phraseLength { tMask |= 1 << UInt16(slot) }
            let overlap = (tMask & mask).nonzeroBitCount
            if overlap > bestOverlap { bestOverlap = overlap; best = t }
        }
        return best
    }
}

/// Intentional four-lane movement motifs. Each phrase chooses one; the lane
/// assignment cost model still guards feasibility (jumps, spacing, balance),
/// so a motif shapes the hand, never breaks it.
enum LaneMotif: String, Codable, Sendable {
    case free          // no preference — the cost model decides
    case walkRight     // L→R progression
    case walkLeft      // R→L progression
    case alternate     // adjacent-pair alternation
    case center        // middle lanes (1-2)
    case staircaseUp   // short controlled staircase up
    case staircaseDown // short controlled staircase down
    case mirrored      // mirror around the center

    /// Preferred lane for the note at `i` within a phrase, or nil (free).
    func preferredLane(startLane: Int, noteIndex: Int) -> Int? {
        switch self {
        case .free: return nil
        case .walkRight: return (startLane + noteIndex) % 4
        case .walkLeft: return ((startLane - noteIndex) % 4 + 4) % 4
        case .alternate:
            let a = startLane % 3
            return noteIndex % 2 == 0 ? a : a + 1
        case .center: return noteIndex % 2 == 0 ? 1 : 2
        case .staircaseUp: return min(3, startLane + noteIndex)
        case .staircaseDown: return max(0, startLane - noteIndex)
        case .mirrored: return noteIndex % 2 == 0 ? startLane : 3 - startLane
        }
    }
}

/// One musical phrase: four detected beats (a bar), its musical context, the
/// chosen rhythm template + lane motif, and the notes that were placed in it.
struct Phrase: Sendable {
    var index: Int
    var start: Double
    var end: Double
    var beats: [Beat]
    var beatLength: Double
    var energy: Double
    var slotTimes: [Double] = []      // 16 sixteenth-note times
    var slotScores: [Double] = []     // musical support per slot (0…∞)
    var template: RhythmTemplate = .rest
    var motif: LaneMotif = .free
    var noteIndices: Range<Int> = 0..<0   // indices into the placed list
    var startLane = 0

    /// Pattern mask of the notes actually placed in this phrase (analytics).
    static func slotMask(for noteTimes: [Double], start: Double, beatLength: Double) -> UInt16 {
        var mask: UInt16 = 0
        let step = beatLength / 4
        for t in noteTimes {
            let slot = Int(((t - start) / step).rounded())
            if (0..<16).contains(slot) { mask |= 1 << UInt16(slot) }
        }
        return mask
    }
}

/// Turns the detected beat grid into phrases and chooses templates + motifs
/// deterministically. Pure: same beats/events/seed → same phrases.
enum PhraseSequencer {
    static let slotsPerPhrase = 16

    /// 4-beat bars over the detected beats, skipping material outside the
    /// playable window. Returns [] when there is no usable beat grid — the
    /// generator then falls back to the legacy per-cell selection.
    static func buildPhrases(beats: [Beat], playStart: Double, playEnd: Double,
                             energyAt: (Double) -> Double) -> [Phrase] {
        guard beats.count >= 4 else { return [] }
        var phrases: [Phrase] = []
        var i = 0
        while i + 3 < beats.count {
            let group = Array(beats[i...(i + 3)])
            let start = group[0].time
            let end = group[3].time + (group[3].time - group[2].time)
            let beatLength = (group[3].time - group[0].time) / 3
            // `beatLength > 0.05` alone admits degenerate 4-beat groups whose
            // sixteenth slots sit BELOW the validator's minimum spacing (e.g.
            // double-beat artifacts), which made whole candidate charts
            // unrepairable. 0.18 s = ~333 BPM — no real song is excluded, but
            // a pathological grid falls through to the legacy/synthetic tiers
            // instead of producing an unplayable arrangement.
            if end > playStart && start < playEnd, beatLength >= 0.18 {
                let step = beatLength / 4
                let times = (0..<slotsPerPhrase).map { start + Double($0) * step }
                phrases.append(Phrase(index: phrases.count, start: start, end: end,
                                      beats: group, beatLength: beatLength,
                                      energy: energyAt(start + (end - start) / 2),
                                      slotTimes: times,
                                      slotScores: [Double](repeating: 0, count: slotsPerPhrase)))
            }
            i += 4
        }
        return phrases
    }

    /// Musical support per sixteenth slot: beat baseline + nearby event energy.
    static func computeSlotScores(_ phrase: inout Phrase, events: [MusicalEvent]) {
        let step = phrase.beatLength / 4
        for (i, t) in phrase.slotTimes.enumerated() {
            var score = 0.0
            for beat in phrase.beats {
                let dist = abs(beat.time - t)
                let reach = phrase.beatLength * 0.45
                if dist < reach {
                    score += (beat.isStrong ? 0.55 : 0.3) * (1 - dist / reach)
                }
            }
            phrase.slotScores[i] = score
        }
        for event in events {
            let rel = event.time - phrase.start
            let slot = Int((rel / step).rounded())
            guard slot >= 0, slot < slotsPerPhrase else { continue }
            let dist = abs(rel - Double(slot) * step)
            let reach = step * 0.9
            guard dist <= reach else { continue }
            phrase.slotScores[slot] += event.importance * event.strength * (1 - dist / reach)
        }
    }

    /// Cosine similarity between two phrases' support profiles (0…1) — how
    /// much the music is repeating.
    static func similarity(_ a: Phrase, _ b: Phrase) -> Double {
        guard a.slotScores.count == b.slotScores.count else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.slotScores.indices {
            dot += a.slotScores[i] * b.slotScores[i]
            na += a.slotScores[i] * a.slotScores[i]
            nb += b.slotScores[i] * b.slotScores[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    /// How well a template fits this phrase musically: density budget + slot
    /// support + energy/repetition modifiers. Shared by the deterministic
    /// roulette AND the AI feature extractor, so the AI learns against the
    /// exact fit the deterministic path uses. Deterministic.
    static func templateFit(template: RhythmTemplate, phrase: Phrase, targetSlots: Int,
                            quiet: Bool, previous: RhythmTemplate?,
                            previousSimilarity: Double) -> Double {
        var fit: Double
        if template.isRestful {
            // Rests are the musical choice when the music breathes.
            fit = (quiet || targetSlots <= 1) ? 1.3 : 0.12
        } else {
            let densityFit = 1 - min(1, abs(Double(template.slots.count) - Double(targetSlots)) / 8)
            let support = template.slots.map { phrase.slotScores[$0] }.reduce(0, +) / Double(template.slots.count)
            fit = 0.55 * densityFit + 0.45 * min(1, support / 0.55)
            if template == .syncopated {
                let offbeat = [1, 5, 9, 13].map { phrase.slotScores[$0] }.reduce(0, +) / 4
                fit *= 0.35 + 0.65 * min(1, offbeat / 0.5)
            }
            if template == .burst { fit *= phrase.energy >= 0.55 ? 1.0 : 0.3 }
            if template == .eighthsSteady || template == .eighthsHalf { if quiet { fit *= 0.55 } }
            if template == .callResponse { if quiet { fit *= 0.7 } }
        }
        if previous == template {
            // Repeating music reuses its pattern; fresh material doesn't.
            fit *= previousSimilarity >= 0.65 ? 1.2 : 0.75
        }
        return fit
    }

    /// Deterministic template pick: density budget + musical support + energy
    /// + repetition/continuity. A seeded roulette over the best-fitting
    /// templates keeps variety without randomness leaking into determinism.
    static func chooseTemplate(phrase: Phrase, targetSlots: Int,
                               previous: RhythmTemplate?, previousSimilarity: Double,
                               rng: inout SplitMix64) -> RhythmTemplate {
        let quiet = phrase.energy < 0.3
        var fits: [(RhythmTemplate, Double)] = []
        for t in RhythmTemplate.allCases {
            fits.append((t, max(0.01, templateFit(template: t, phrase: phrase,
                                                  targetSlots: targetSlots, quiet: quiet,
                                                  previous: previous,
                                                  previousSimilarity: previousSimilarity))))
        }
        fits.sort { $0.1 > $1.1 }
        let pool = Array(fits.prefix(3))
        let total = pool.reduce(0.0) { $0 + $1.1 }
        var roll = rng.uniform() * total
        for (t, f) in pool {
            roll -= f
            if roll <= 0 { return t }
        }
        return pool.last!.0
    }

    /// Deterministic motif pick: energetic sections move, quiet ones stay
    /// centered/free; difficulty adds stairs/mirrors; repetition keeps the
    /// motion family with a rotated start lane (controlled variation).
    static func chooseMotif(phrase: Phrase, difficulty: DifficultyLevel,
                           previous: LaneMotif?, rng: inout SplitMix64) -> LaneMotif {
        let energetic = phrase.energy >= 0.55
        var pool: [LaneMotif]
        if !energetic {
            pool = [.free, .free, .center, .alternate]
        } else if difficulty.targetNPS >= 4.2 {
            pool = [.walkRight, .walkLeft, .alternate, .staircaseUp, .staircaseDown, .mirrored, .center]
        } else {
            pool = [.walkRight, .walkLeft, .alternate, .center, .staircaseUp]
        }
        // Continuity: a repeating musical phrase keeps its movement family.
        if let previous, pool.contains(previous), rng.uniform() < 0.5 {
            return previous
        }
        return pool[Int(rng.uniform() * Double(pool.count))]
    }

    // MARK: - Plan pass (shared by the selector and the AI ranking)

    /// Runs the EXACT decision sequence the selector uses — slot scoring,
    /// similarity, per-phrase seeded roulette for template + motif, start-lane
    /// rotation — and returns one `PhrasePlan` per phrase. The phrases are
    /// mutated in place (slot scores, template, motif, start lane) exactly as
    /// the selector's loop did, so the AI-absent path is byte-identical and
    /// the AI path re-ranks against the true deterministic decisions.
    static func decidePlans(phrases: inout [Phrase],
                            activeEvents: [MusicalEvent],
                            targetNPS: Double,
                            difficulty: DifficultyLevel,
                            seed: UInt64,
                            variant: Int,
                            factorAt: (Double) -> Double) -> [PhrasePlan] {
        var plans: [PhrasePlan] = []
        plans.reserveCapacity(phrases.count)
        var prevTemplate: RhythmTemplate?
        var prevMotif: LaneMotif?
        var prevPhrase: Phrase?

        for pi in phrases.indices {
            var phrase = phrases[pi]
            PhraseSequencer.computeSlotScores(&phrase, events: activeEvents)
            let similarity = prevPhrase.map { PhraseSequencer.similarity(phrase, $0) } ?? 0
            let midTime = phrase.start + (phrase.end - phrase.start) / 2
            let factor = factorAt(midTime)
            let targetSlots = max(0, Int((targetNPS * factor * (phrase.end - phrase.start)).rounded()))
            let quiet = phrase.energy < 0.3

            // Per-phrase deterministic RNG: seeded from the chart seed, phrase
            // index and candidate variant — never from global state.
            var prng = SplitMix64(state: seed &+ UInt64(pi &* 0x9E37_79B9) &+ UInt64(variant &* 7919))
            let template = PhraseSequencer.chooseTemplate(phrase: phrase, targetSlots: targetSlots,
                                                          previous: prevTemplate,
                                                          previousSimilarity: similarity,
                                                          rng: &prng)
            let motif = PhraseSequencer.chooseMotif(phrase: phrase, difficulty: difficulty,
                                                    previous: prevMotif, rng: &prng)
            var startLane = Int(prng.uniform() * 4)
            if let prevStart = prevPhrase?.startLane, motif == prevMotif {
                // Repeating motif: rotate the hand so repetition stays musical.
                startLane = (prevStart + 1 + Int(prng.uniform() * 2)) % 4
            }

            plans.append(PhrasePlan(template: template, motif: motif, startLane: startLane,
                                    targetSlots: targetSlots, quiet: quiet,
                                    previousTemplate: prevTemplate, previousMotif: prevMotif,
                                    previousStartLane: prevPhrase?.startLane,
                                    previousSimilarity: similarity))
            phrase.template = template
            phrase.motif = motif
            phrase.startLane = startLane
            phrases[pi] = phrase
            prevTemplate = template
            prevMotif = motif
            prevPhrase = phrase
        }
        return plans
    }

    /// Deterministic candidate pattern set around a phrase's plan. Candidate 0
    /// is ALWAYS the deterministic plan itself (the AI learns to defend or
    /// overturn it); the others are the musically meaningful alternatives:
    /// same rhythm / different movement, a restful breath, a groove or
    /// syncopation alternative, and an energy candidate. No randomness — the
    /// same plan always yields the same candidates.
    static func candidatePatterns(plan: PhrasePlan, phrase: Phrase,
                                  difficulty: DifficultyLevel) -> [PatternCandidate] {
        let energetic = phrase.energy >= 0.55
        var candidates: [PatternCandidate] = []
        func add(_ candidate: PatternCandidate) {
            guard !candidates.contains(candidate) else { return }
            candidates.append(candidate)
        }

        // 0: the deterministic plan.
        add(PatternCandidate(template: plan.template, motif: plan.motif, startLane: plan.startLane))
        // 1: same rhythm, different movement family.
        let altMotif: LaneMotif = energetic
            ? (plan.motif == .alternate ? .walkRight : .alternate)
            : (plan.motif == .center ? .walkRight : .center)
        add(PatternCandidate(template: plan.template, motif: altMotif, startLane: (plan.startLane + 1) % 4))
        // 2: musical breathing — a rest or bare downbeat.
        let restTemplate: RhythmTemplate = (plan.quiet || plan.targetSlots <= 1) ? .rest : .downbeatOnly
        add(PatternCandidate(template: restTemplate, motif: .free, startLane: (plan.startLane + 2) % 4))
        // 3: groove/syncopation alternative.
        let grooveTemplate: RhythmTemplate = phrase.energy >= 0.3 ? .syncopated : .eighthsHalf
        add(PatternCandidate(template: grooveTemplate, motif: plan.motif, startLane: (plan.startLane + 3) % 4))
        // 4: energy candidate — bursts in loud sections, quarters in calm ones.
        let energyTemplate: RhythmTemplate = energetic ? .burst : .quarterTwoFour
        add(PatternCandidate(template: energyTemplate,
                             motif: energetic ? .staircaseUp : .walkLeft,
                             startLane: plan.startLane))
        return candidates
    }
}

/// Builds the AI ranking contexts (candidates + feature-ready context) from a
/// completed plan pass. Pure and shared: the chart generator and the training
/// exporter call the SAME code, so runtime features and training features can
/// never drift apart.
enum PatternRankingBuilder {
    static func contexts(phrases: [Phrase], plans: [PhrasePlan],
                         events: [MusicalEvent], variant: Int,
                         difficulty: DifficultyLevel, targetNPS: Double,
                         duration: Double) -> [PatternRankingContext] {
        var result: [PatternRankingContext] = []
        result.reserveCapacity(plans.count)
        for (pi, plan) in plans.enumerated() {
            let phrase = phrases[pi]
            let candidates = PhraseSequencer.candidatePatterns(plan: plan, phrase: phrase,
                                                               difficulty: difficulty)
            guard !candidates.isEmpty else { continue }
            let fits = candidates.map {
                PhraseSequencer.templateFit(template: $0.template, phrase: phrase,
                                            targetSlots: plan.targetSlots, quiet: plan.quiet,
                                            previous: plan.previousTemplate,
                                            previousSimilarity: plan.previousSimilarity)
            }
            let nextTemplate = pi + 1 < plans.count ? plans[pi + 1].template : nil
            let eventsInPhrase = events.reduce(0) {
                $0 + (($1.time >= phrase.start && $1.time < phrase.end) ? 1 : 0)
            }
            result.append(PatternRankingContext(variant: variant, phraseIndex: pi,
                                                phraseStart: phrase.start, phraseEnd: phrase.end,
                                                energy: phrase.energy, beatLength: phrase.beatLength,
                                                slotScores: phrase.slotScores,
                                                targetSlots: plan.targetSlots,
                                                previousTemplate: plan.previousTemplate,
                                                previousMotif: plan.previousMotif,
                                                previousStartLane: plan.previousStartLane,
                                                previousSimilarity: plan.previousSimilarity,
                                                nextTemplate: nextTemplate,
                                                eventsInPhrase: eventsInPhrase,
                                                duration: duration, targetNPS: targetNPS,
                                                candidates: candidates, fits: fits))
        }
        return result
    }
}

/// The deterministic decision for one phrase: what the seeded roulette chose
/// plus the context the decision was made in. Computed ONCE up front by
/// `PhraseSequencer.decidePlans` so the chart selector and the AI ranking
/// share the exact same decision state.
struct PhrasePlan: Sendable {
    var template: RhythmTemplate
    var motif: LaneMotif
    var startLane: Int
    var targetSlots: Int
    var quiet: Bool
    var previousTemplate: RhythmTemplate?
    var previousMotif: LaneMotif?
    var previousStartLane: Int?
    var previousSimilarity: Double
}

/// A completed plan pass for one candidate arrangement: the phrases (with
/// slot scores + template/motif/start lane set), the per-phrase plans, and
/// any AI rankings stitched back in by phrase index (empty = deterministic).
struct PreplannedPhrases: Sendable {
    var phrases: [Phrase]
    var plans: [PhrasePlan]
    var rankings: [Int: PatternRanking]
}

/// Playability/musicality quality score used to choose among candidate charts.
/// Penalty-based (higher is better), fully deterministic.
struct ChartQualityScore: Sendable {
    var score: Double
    var reactionPenalty: Double
    var jumpPenalty: Double
    var balancePenalty: Double
    var holePenalty: Double
    var repetitionPenalty: Double
    var restPenalty: Double

    static let zero = ChartQualityScore(score: 0, reactionPenalty: 0, jumpPenalty: 0,
                                        balancePenalty: 0, holePenalty: 0,
                                        repetitionPenalty: 0, restPenalty: 0)
}

enum ChartQualityScorer {
    /// Scores a completed chart. `phrases` carries template/motif structure;
    /// when empty (fallback path) repetition/rest components are skipped.
    static func score(notes: [ChartNote], analysis: AudioAnalysis?,
                      difficulty: DifficultyLevel, phrases: [Phrase],
                      sections: [SongSection]) -> ChartQualityScore {
        let sorted = notes.sorted { $0.time < $1.time }

        // Chord-aware event sequence: notes within 0.1s of the group's first
        // note are ONE event (matching the validator), so reaction time and
        // lane jumps are measured between chord groups — a chord voice next to
        // its partner is not a "0 ms reaction". Jumps use the minimum distance
        // between the two groups' lane sets (a chord (0,2) after a lane-3 note
        // is reachable via lane 2).
        var anchors: [(time: Double, lanes: [Int])] = []
        for note in sorted {
            if var last = anchors.last, note.time - last.time < 0.1 {
                last.lanes.append(note.lane)
                anchors[anchors.count - 1] = last
            } else {
                anchors.append((note.time, [note.lane]))
            }
        }
        var reaction = 0.0
        var jumps = 0.0
        for i in 1..<anchors.count {
            let gap = anchors[i].time - anchors[i - 1].time
            if gap < 0.24 {
                reaction += (0.24 - gap) * 6
            }
            var jump = 3
            for a in anchors[i - 1].lanes {
                for b in anchors[i].lanes { jump = min(jump, abs(a - b)) }
            }
            if jump == 3, gap < 0.6 { jumps += (0.6 - gap) * 3 + 0.5 }
            else if jump == 2, gap < 0.34 { jumps += (0.34 - gap) * 4 + 0.3 }
        }
        reaction = min(3, reaction)
        jumps = min(2, jumps)

        // Lane balance (charts long enough to matter).
        var balance = 0.0
        if sorted.count >= 40 {
            var counts = [0, 0, 0, 0]
            for note in sorted where (0..<4).contains(note.lane) { counts[note.lane] += 1 }
            let minShare = Double(counts.min() ?? 0) / Double(sorted.count)
            if minShare < 0.10 { balance = (0.10 - minShare) * 12 }
        }

        // Dead air inside energetic sections (rests belong to quiet ones).
        var holes = 0.0
        if !sections.isEmpty {
            for i in 1..<sorted.count {
                let gap = sorted[i].time - sorted[i - 1].time
                if gap > 1.3 {
                    let mid = (sorted[i].time + sorted[i - 1].time) / 2
                    let section = sections.first { mid >= $0.start && mid < $0.end }
                    if let section, section.energy >= 0.5 { holes += (gap - 1.3) * 0.8 }
                }
            }
        }
        holes = min(1.5, holes)

        // Repetition: some reuse is good (musical), constant reuse is boring.
        var repetition = 0.0
        if phrases.count >= 3 {
            var same = 0
            for i in 1..<phrases.count where phrases[i].template == phrases[i - 1].template {
                same += 1
            }
            let rate = Double(same) / Double(phrases.count - 1)
            repetition = abs(rate - 0.5) * 1.6
        }

        // Rests where the music breathes.
        var rest = 0.0
        if !phrases.isEmpty {
            let quietPhrases = phrases.filter { $0.energy < 0.35 }
            if !quietPhrases.isEmpty {
                let quietRested = quietPhrases.filter { $0.template.isRestful }.count
                if Double(quietRested) < Double(quietPhrases.count) * 0.4 {
                    rest = 1.0
                }
            }
        }

        let score = max(0, 10 - reaction - jumps - balance - holes - repetition - rest)
        return ChartQualityScore(score: score, reactionPenalty: reaction, jumpPenalty: jumps,
                                 balancePenalty: balance, holePenalty: holes,
                                 repetitionPenalty: repetition, restPenalty: rest)
    }
}