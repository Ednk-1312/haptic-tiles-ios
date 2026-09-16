import Foundation

/// Versioning metadata for the bundled Core ML models.
///
/// Every model carries: model version, feature schema version, training-data
/// version. Charts record the model version they were generated with, so an
/// incompatible model change is detectable and triggers regeneration.
enum AIModelCatalog {
    static let featureSchemaVersion = 1
    static let difficultyModelVersion = 2
    static let eventModelVersion = 2
    static let patternModelVersion = 2
    static let trainingDataVersion = "synth-v4-corrected-difficulty-2026-09-15"

    static let difficultyFeatureCount = DifficultyFeatureExtractor.featureCount
    static let eventFeatureCount = EventFeatureExtractor.featureCount
    static let patternFeatureCount = PatternFeatureExtractor.featureCount

    static let difficultyModelFileName = "AIDifficulty"
    static let eventModelFileName = "AIEventRanking"
    static let patternModelFileName = "AIPatternRanking"
    static let manifestFileName = "model-manifest"

    /// Bundled manifest (written by the training pipeline, shipped as a
    /// resource). Falls back to code constants when absent.
    static let manifest: AIModelManifest? = {
        if let url = Bundle.main.url(forResource: manifestFileName, withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            return try? JSONDecoder().decode(AIModelManifest.self, from: data)
        }
        return nil
    }()
}

/// Machine-readable record of the trained models, produced by the training
/// pipeline and bundled with the app.
struct AIModelManifest: Codable, Sendable {
    var trainingDataVersion: String
    var featureSchemaVersion: Int
    var difficulty: ModelEntry
    var eventRanking: ModelEntry
    /// Optional: absent in manifests written before pattern ranking shipped.
    var patternRanking: ModelEntry?

    struct ModelEntry: Codable, Sendable {
        var modelVersion: Int
        var featureCount: Int
        var trainingRecordCount: Int
        var evaluation: ModelEvaluation
    }

    struct ModelEvaluation: Codable, Sendable {
        var mae: Double
        var rmse: Double
        var correlation: Double
        var auc: Double?          // event model only
        var precisionAt05: Double?
        var recallAt05: Double?
        var agreement: Double?    // event model: agreement with deterministic selection
        var note: String
    }
}

/// Result of AI difficulty inference fused with the deterministic score.
struct AIDifficultyOutcome: Sendable {
    var finalScore: Double          // 0…10, fused
    var deterministicScore: Double
    var aiScore: Double?
    var aiConfidence: Double?       // heuristic uncertainty, NOT calibrated probability
    var usedAI: Bool
    var modelVersion: Int?
    var inferenceMs: Double?
}

/// Fused importance for one candidate event.
struct AIEventOutcome: Sendable {
    var time: Double
    var dspImportance: Double
    var aiImportance: Double?
    var aiConfidence: Double?       // decisiveness heuristic, NOT calibrated
    var finalImportance: Double
    var usedAI: Bool
}

/// Configurable fusion policy. The deterministic systems stay dominant until
/// the AI proves itself; weights and confidence floor are configurable and
/// tested.
struct AIFusionConfig: Codable, Sendable, Equatable {
    var enabled: Bool
    var difficultyAIWeight: Double     // 0…1 (0.3 → deterministic dominant)
    var eventAIWeight: Double          // 0…1
    var minEventConfidence: Double     // below this, event prediction is ignored
    var patternAIWeight: Double = 0.55        // 0…1 (AI-leaning, fit keeps guard)
    var minPatternConfidence: Double = 0.06   // min top-2 AI gap before a pattern pick

    static let `default` = AIFusionConfig(enabled: true,
                                          difficultyAIWeight: 0.30,
                                          eventAIWeight: 0.35,
                                          minEventConfidence: 0.30,
                                          patternAIWeight: 0.55,
                                          minPatternConfidence: 0.06)

    var validated: AIFusionConfig {
        AIFusionConfig(enabled: enabled,
                       difficultyAIWeight: min(1, max(0, difficultyAIWeight)),
                       eventAIWeight: min(1, max(0, eventAIWeight)),
                       minEventConfidence: min(1, max(0, minEventConfidence)),
                       patternAIWeight: min(1, max(0, patternAIWeight)),
                       minPatternConfidence: min(1, max(0, minPatternConfidence)))
    }
}

/// Difficulty fusion: weighted blend, gated by a disagreement-based uncertainty
/// heuristic. `confidence` is explicitly NOT a calibrated probability — it is
/// `1 - |Δdet-ai| / 3` (how much the two systems agree), documented as such.
enum AIDifficultyFusion {
    static func fuse(deterministic: Double, ai: Double?, config: AIFusionConfig) -> AIDifficultyOutcome {
        let cfg = config.validated
        guard cfg.enabled, let ai, ai.isFinite else {
            return AIDifficultyOutcome(finalScore: deterministic, deterministicScore: deterministic,
                                       aiScore: ai, aiConfidence: nil, usedAI: false,
                                       modelVersion: nil, inferenceMs: nil)
        }
        let clampedAI = min(10, max(0, ai))
        let confidence = max(0, 1 - abs(clampedAI - deterministic) / 3.0)
        let final = deterministic * (1 - cfg.difficultyAIWeight) + clampedAI * cfg.difficultyAIWeight
        return AIDifficultyOutcome(finalScore: min(10, max(0, final)),
                                   deterministicScore: deterministic,
                                   aiScore: clampedAI,
                                   aiConfidence: confidence,
                                   usedAI: true,
                                   modelVersion: AIModelCatalog.difficultyModelVersion,
                                   inferenceMs: nil)
    }
}

/// Event-importance fusion: DSP importance blended with the AI prediction,
/// gated by a decisiveness heuristic (`2·|p − 0.5|`). Low-confidence or
/// unavailable predictions fall back to the DSP score unchanged.
enum AIEventFusion {
    static func fusedImportance(time: Double, dsp: Double, ai: Double?, config: AIFusionConfig) -> AIEventOutcome {
        let cfg = config.validated
        guard cfg.enabled, let ai, ai.isFinite else {
            return AIEventOutcome(time: time, dspImportance: dsp, aiImportance: ai,
                                  aiConfidence: nil, finalImportance: dsp, usedAI: false)
        }
        let clamped = min(1, max(0, ai))
        let confidence = 2 * abs(clamped - 0.5)   // decisiveness heuristic
        guard confidence >= cfg.minEventConfidence else {
            return AIEventOutcome(time: time, dspImportance: dsp, aiImportance: clamped,
                                  aiConfidence: confidence, finalImportance: dsp, usedAI: false)
        }
        let final = dsp * (1 - cfg.eventAIWeight) + clamped * cfg.eventAIWeight
        return AIEventOutcome(time: time, dspImportance: dsp, aiImportance: clamped,
                              aiConfidence: confidence, finalImportance: min(1, max(0, final)), usedAI: true)
    }
}