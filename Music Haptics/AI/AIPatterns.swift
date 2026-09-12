import Foundation

// MARK: - Pattern candidates

/// One deterministic candidate pattern for a phrase: a rhythm template + lane
/// motif + start lane. Candidates are constructed WITHOUT randomness (seeded
/// only through the deterministic plan they wrap), so the same analysis +
/// plan always yields the same candidate set.
struct PatternCandidate: Codable, Sendable, Equatable {
    var template: RhythmTemplate
    var motif: LaneMotif
    var startLane: Int

    init(template: RhythmTemplate, motif: LaneMotif, startLane: Int) {
        self.template = template
        self.motif = motif
        self.startLane = min(3, max(0, startLane))
    }
}

/// Full musical context for ranking the candidates of ONE phrase. Everything
/// here is a pure function of the analysis + deterministic plan — the AI only
/// re-ranks, it never invents patterns or timestamps.
struct PatternRankingContext: Sendable {
    var variant: Int
    var phraseIndex: Int
    var phraseStart: Double
    var phraseEnd: Double
    var energy: Double
    var beatLength: Double
    var slotScores: [Double]       // musical support per 16th slot (0…∞)
    var targetSlots: Int           // this phrase's density budget
    var previousTemplate: RhythmTemplate?
    var previousMotif: LaneMotif?
    var previousStartLane: Int?
    var previousSimilarity: Double
    var nextTemplate: RhythmTemplate?      // the NEXT phrase's deterministic plan
    var eventsInPhrase: Int
    var duration: Double
    var targetNPS: Double
    var candidates: [PatternCandidate]
    var fits: [Double]             // deterministic template-fit per candidate
}

/// The AI's ranking result for one phrase. `chosenIndex == nil` means the
/// generator uses its deterministic plan (fallback); otherwise it picks
/// `candidates[chosenIndex]` — still gated by the same placement rules and
/// the playability validator downstream.
struct PatternRanking: Sendable {
    var variant: Int
    var phraseIndex: Int
    var candidates: [PatternCandidate]
    var chosenIndex: Int?
    var usedAI: Bool
    var aiConfidence: Double?
}

/// Per-candidate record for diagnostics.
struct AIPatternCandidateDiagnostic: Codable, Sendable {
    var template: RhythmTemplate
    var motif: LaneMotif
    var startLane: Int
    var dspFit: Double
    var aiScore: Double?
    var finalScore: Double
}

/// Per-phrase pattern-ranking diagnostics (persisted locally with the song's
/// AI diagnostics, never transmitted).
struct AIPatternDiagnostic: Codable, Sendable {
    var variant: Int
    var phraseIndex: Int
    var phraseStart: Double
    var template: RhythmTemplate       // the pattern actually placed
    var motif: LaneMotif
    var startLane: Int
    var candidates: [AIPatternCandidateDiagnostic]
    var chosenIndex: Int?              // AI-chosen candidate, nil = deterministic
    var usedAI: Bool
    var aiConfidence: Double?
    var features: [[Double]]
}

/// Fused ranking outcome for one phrase.
struct AIPatternOutcome: Sendable {
    var candidates: [PatternCandidate]
    var fits: [Double]
    var finalScores: [Double]
    var aiScores: [Double]?
    var aiConfidence: Double?          // AI decisiveness, NOT calibrated
    var chosenIndex: Int?              // nil → deterministic plan
    var usedAI: Bool
}

// MARK: - Features

/// Deterministic, normalized per-(phrase, candidate) features for the
/// pattern-ranking model.
///
/// Rules mirror the other extractors: pure functions of analysis data, every
/// feature clamped 0…1, schema versioned via `AIModelCatalog`.
enum PatternFeatureExtractor {
    static let featureCount = 16

    enum Index: Int, CaseIterable {
        case sectionEnergy = 0, bpm, eventDensity, densityBudget,
             candidateDensity, candidateSupport, syncopationSupport, restfulness,
             prevTemplateContinuity, prevMotifContinuity, motifCode,
             laneTransition, targetNPS, burstEnergy,
             nextTemplateContinuity, deterministicFit
    }

    static func extract(context: PatternRankingContext, candidateIndex: Int) -> [Double] {
        let candidate = context.candidates[candidateIndex]
        let beatLength = max(context.beatLength, 0.05)
        let bpm = 60 / beatLength
        let phraseLength = max(context.phraseEnd - context.phraseStart, 0.01)
        let slots = candidate.template.slots
        let support = slots.isEmpty ? 0
            : slots.map { context.slotScores[$0] }.reduce(0, +) / Double(slots.count)
        let offbeat = [1, 5, 9, 13].map { context.slotScores[$0] }.reduce(0, +) / 4

        var f = [Double](repeating: 0, count: featureCount)
        f[Index.sectionEnergy.rawValue] = DifficultyFeatureExtractor.clamp01(context.energy)
        f[Index.bpm.rawValue] = DifficultyFeatureExtractor.clamp01((bpm - 40) / 200)
        f[Index.eventDensity.rawValue] = DifficultyFeatureExtractor.clamp01(Double(context.eventsInPhrase) / (phraseLength * 8))
        f[Index.densityBudget.rawValue] = DifficultyFeatureExtractor.clamp01(Double(context.targetSlots) / 16)
        f[Index.candidateDensity.rawValue] = DifficultyFeatureExtractor.clamp01(Double(slots.count) / 16)
        f[Index.candidateSupport.rawValue] = DifficultyFeatureExtractor.clamp01(support / 0.55)
        f[Index.syncopationSupport.rawValue] = DifficultyFeatureExtractor.clamp01(offbeat / 0.5)
        f[Index.restfulness.rawValue] = candidate.template.isRestful ? 1 : 0
        f[Index.prevTemplateContinuity.rawValue] = context.previousTemplate == candidate.template ? 1 : 0
        f[Index.prevMotifContinuity.rawValue] = context.previousMotif == candidate.motif ? 1 : 0
        f[Index.motifCode.rawValue] = motifCode(candidate.motif)
        f[Index.laneTransition.rawValue] = context.previousStartLane.map { Double(abs($0 - candidate.startLane)) / 3 } ?? 0.5
        f[Index.targetNPS.rawValue] = DifficultyFeatureExtractor.clamp01(context.targetNPS / 6)
        f[Index.burstEnergy.rawValue] = context.energy >= 0.55 ? context.energy : 0
        f[Index.nextTemplateContinuity.rawValue] = context.nextTemplate == candidate.template ? 1 : 0
        f[Index.deterministicFit.rawValue] = DifficultyFeatureExtractor.clamp01(context.fits[candidateIndex])
        return f
    }

    /// Deterministic numeric code for a lane motif (0…1, enum order fixed).
    static func motifCode(_ motif: LaneMotif) -> Double {
        switch motif {
        case .free: return 0.0
        case .walkRight: return 1.0 / 7
        case .walkLeft: return 2.0 / 7
        case .alternate: return 3.0 / 7
        case .center: return 4.0 / 7
        case .staircaseUp: return 5.0 / 7
        case .staircaseDown: return 6.0 / 7
        case .mirrored: return 1.0
        }
    }
}

// MARK: - Fusion

/// Pattern-ranking fusion. Unlike events (blended importance), a pattern is a
/// discrete choice, so the fusion picks ONE candidate:
/// - AI unavailable / disabled / non-finite → deterministic plan (nil).
/// - AI indecisive (top-2 gap below `minPatternConfidence`) → deterministic
///   plan, but the AI scores are still recorded for diagnostics.
/// - AI decisive → argmax over `fit·(1−w) + ai·w`, so the deterministic fit
///   stays a guard rail the AI cannot fully override.
/// The generator's placement rules (density budget, min spacing, accent
/// floors, chord gates) and the validator remain the final authority either
/// way.
enum AIPatternFusion {
    static func rank(candidates: [PatternCandidate],
                     fits: [Double],
                     aiScores: [Double]?,
                     config: AIFusionConfig) -> AIPatternOutcome {
        let cfg = config.validated
        guard cfg.enabled, let aiScores, aiScores.count == candidates.count,
              aiScores.allSatisfy({ $0.isFinite }) else {
            return AIPatternOutcome(candidates: candidates, fits: fits,
                                    finalScores: fits, aiScores: aiScores,
                                    aiConfidence: nil, chosenIndex: nil, usedAI: false)
        }
        let clamped = aiScores.map { min(1, max(0, $0)) }
        let fused = zip(fits, clamped).map { fit, ai in
            fit * (1 - cfg.patternAIWeight) + ai * cfg.patternAIWeight
        }
        let sorted = clamped.sorted(by: >)
        let confidence: Double = sorted.count >= 2 ? sorted[0] - sorted[1]
            : (sorted.count == 1 ? 1.0 : 0.0)
        guard confidence >= cfg.minPatternConfidence else {
            return AIPatternOutcome(candidates: candidates, fits: fits,
                                    finalScores: fused, aiScores: clamped,
                                    aiConfidence: confidence, chosenIndex: nil,
                                    usedAI: false)
        }
        let chosen = fused.indices.max { fused[$0] < fused[$1] } ?? 0
        return AIPatternOutcome(candidates: candidates, fits: fits,
                                finalScores: fused, aiScores: clamped,
                                aiConfidence: confidence, chosenIndex: chosen,
                                usedAI: true)
    }
}