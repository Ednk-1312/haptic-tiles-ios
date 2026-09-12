import Foundation
import Observation

/// The deterministic chart generator's AI advisory port. The AI never creates
/// timestamps or bypasses validation — it only adjusts (a) the final
/// difficulty number and (b) each candidate event's importance, both inside
/// the existing deterministic pipeline. Returning nil means "use the
/// deterministic value unchanged".
protocol AIChartAdvisor: Sendable {
    func difficultyOutcome(songID: UUID,
                           notes: [ChartNote],
                           metrics: DifficultyMetrics,
                           analysis: AudioAnalysis) async -> AIDifficultyOutcome?
    func eventImportance(songID: UUID,
                         events: [MusicalEvent],
                         analysis: AudioAnalysis) async -> [Double]?
    /// Ranks the deterministic candidate patterns per phrase. Returns nil to
    /// keep the deterministic plans; a non-nil result may override one or
    /// more phrases' (template, motif, startLane) — never the placement
    /// constraints themselves.
    func patternRanking(songID: UUID,
                        contexts: [PatternRankingContext],
                        analysis: AudioAnalysis,
                        difficulty: DifficultyLevel) async -> [PatternRanking]?
}

extension AIChartAdvisor {
    /// Optional hook: advisors that don't rank patterns leave the
    /// deterministic plans untouched.
    func patternRanking(songID: UUID,
                        contexts: [PatternRankingContext],
                        analysis: AudioAnalysis,
                        difficulty: DifficultyLevel) async -> [PatternRanking]? {
        nil
    }
}

/// Per-song AI diagnostics — persisted locally (JSON), never transmitted.
struct AISongDiagnostics: Codable, Sendable {
    var songID: UUID
    var generatedAt: Date
    var modelVersion: Int
    var featureSchemaVersion: Int
    var difficulty: AIDifficultyDiagnostic?
    var events: [AIEventDiagnostic] = []
    /// Wall time of the LAST event-ranking inference batch (ms), nil when the
    /// model never ran (missing model, disabled config, empty event list).
    var eventInferenceMs: Double? = nil
    var eventCount: Int { events.count }
    var fallbackCount: Int { events.filter { !$0.usedAI }.count }
    /// Per-phrase pattern-ranking diagnostics (empty when the model never ran
    /// or the song has no beat grid).
    var patterns: [AIPatternDiagnostic] = []
    /// Wall time of the LAST pattern-ranking inference batch (ms).
    var patternInferenceMs: Double? = nil
    var patternCount: Int { patterns.count }
    var patternFallbackCount: Int { patterns.filter { !$0.usedAI }.count }
    var averageEventScore: Double {
        guard !events.isEmpty else { return 0 }
        return events.map(\.finalImportance).reduce(0, +) / Double(events.count)
    }
    var averageConfidence: Double {
        let confs = events.compactMap(\.aiConfidence)
        guard !confs.isEmpty else { return 0 }
        return confs.reduce(0, +) / Double(confs.count)
    }
}

struct AIDifficultyDiagnostic: Codable, Sendable {
    var deterministicScore: Double
    var aiScore: Double?
    var aiConfidence: Double?
    var finalScore: Double
    var usedAI: Bool
    var inferenceMs: Double?
    var features: [Double]
}

struct AIEventDiagnostic: Codable, Sendable {
    var time: Double
    var dspImportance: Double
    var aiImportance: Double?
    var aiConfidence: Double?
    var finalImportance: Double
    var selected: Bool
    var usedAI: Bool
    var features: [Double]
}

/// App-facing AI service. Owns the inference engine, the fusion config and
/// the per-song diagnostics the developer views export. MainActor so UI can
/// read diagnostics directly; heavy inference happens inside the `AIEngine`
/// actor (never on the main thread).
@MainActor
@Observable
final class AISystem {
    // Workaround for swiftlang/swift#87316 (see StatsManager).
    deinit {}
    private let engine: AIEngine
    private let store = AIDiagnosticsStore()
    var config: AIFusionConfig = .default
    private var diagnosticsBySong: [UUID: AISongDiagnostics] = [:]

    init(engine: AIEngine = AIEngine()) {
        self.engine = engine
    }

    // MARK: - Chart-advisor interface

    func difficultyOutcome(songID: UUID,
                           notes: [ChartNote],
                           metrics: DifficultyMetrics,
                           analysis: AudioAnalysis) async -> AIDifficultyOutcome? {
        guard config.enabled else { return nil }
        let features = DifficultyFeatureExtractor.extract(notes: notes, metrics: metrics, analysis: analysis)
        let ai = await engine.predictDifficulty(features: features)
        let outcome = AIDifficultyFusion.fuse(deterministic: metrics.score10, ai: ai, config: config)
        var diag = diagnosticsBySong[songID] ?? AISongDiagnostics(songID: songID, generatedAt: Date(),
                                                                  modelVersion: AIModelCatalog.difficultyModelVersion,
                                                                  featureSchemaVersion: AIModelCatalog.featureSchemaVersion)
        diag.difficulty = AIDifficultyDiagnostic(deterministicScore: outcome.deterministicScore,
                                                 aiScore: outcome.aiScore,
                                                 aiConfidence: outcome.aiConfidence,
                                                 finalScore: outcome.finalScore,
                                                 usedAI: outcome.usedAI,
                                                 inferenceMs: await engine.lastPredictionTimeMs(),
                                                 features: features)
        diagnosticsBySong[songID] = diag
        return outcome
    }

    func eventImportance(songID: UUID,
                         events: [MusicalEvent],
                         analysis: AudioAnalysis) async -> [Double]? {
        guard config.enabled, !events.isEmpty else { return nil }
        // Per-event feature extraction is O(events) CPU work — run it off the
        // main actor (chart generation calls in through the bridge while the
        // UI is live).
        let cfg = config
        let batch = await Task.detached(priority: .userInitiated) {
            let ctx = EventFeatureExtractor.context(for: analysis)
            return events.enumerated().map {
                EventFeatureExtractor.extract($0.element, index: $0.offset, events: events, ctx: ctx)
            }
        }.value
        let aiScores = await engine.predictEventImportance(batch: batch)
        guard let aiScores else { return nil }

        // Fusion + diagnostics-record construction is another per-event loop;
        // compute off the main actor, then only touch state on main.
        let computed = await Task.detached(priority: .userInitiated) { () -> ([Double], [AIEventDiagnostic]) in
            var outcomes: [AIEventOutcome] = []
            var records: [AIEventDiagnostic] = []
            outcomes.reserveCapacity(events.count)
            records.reserveCapacity(events.count)
            for (i, event) in events.enumerated() {
                let outcome = AIEventFusion.fusedImportance(time: event.time,
                                                            dsp: event.importance,
                                                            ai: aiScores[i],
                                                            config: cfg)
                outcomes.append(outcome)
                records.append(AIEventDiagnostic(time: event.time,
                                                 dspImportance: outcome.dspImportance,
                                                 aiImportance: outcome.aiImportance,
                                                 aiConfidence: outcome.aiConfidence,
                                                 finalImportance: outcome.finalImportance,
                                                 selected: false,
                                                 usedAI: outcome.usedAI,
                                                 features: batch[i]))
            }
            return (outcomes.map(\.finalImportance), records)
        }.value

        var diag = diagnosticsBySong[songID] ?? AISongDiagnostics(songID: songID, generatedAt: Date(),
                                                                  modelVersion: AIModelCatalog.eventModelVersion,
                                                                  featureSchemaVersion: AIModelCatalog.featureSchemaVersion)
        diag.eventInferenceMs = await engine.lastPredictionTimeMs()
        diag.events = computed.1
        diagnosticsBySong[songID] = diag
        return computed.0
    }

    // MARK: - Pattern ranking (chart-pattern advisor)

    /// Ranks each phrase's deterministic candidate patterns with the model,
    /// fusing fit + AI score, and records per-phrase diagnostics. Returns nil
    /// when the model is unavailable/disabled — the generator then keeps its
    /// deterministic plans byte-for-byte.
    func patternRanking(songID: UUID,
                        contexts: [PatternRankingContext],
                        analysis: AudioAnalysis,
                        difficulty: DifficultyLevel) async -> [PatternRanking]? {
        guard config.enabled, !contexts.isEmpty else { return nil }
        // Candidate feature extraction is O(total candidates) CPU work — run
        // it off the main actor.
        let cfg = config
        let batch = await Task.detached(priority: .userInitiated) {
            var batch: [[Double]] = []
            batch.reserveCapacity(contexts.reduce(0) { $0 + $1.candidates.count })
            for ctx in contexts {
                for i in ctx.candidates.indices {
                    batch.append(PatternFeatureExtractor.extract(context: ctx, candidateIndex: i))
                }
            }
            return batch
        }.value
        let aiScores = await engine.predictPatternScores(batch: batch)
        guard let aiScores else { return nil }

        // Per-phrase fusion + diagnostics construction — off the main actor.
        let computed = await Task.detached(priority: .userInitiated) { () -> ([PatternRanking], [AIPatternDiagnostic]) in
            var result: [PatternRanking] = []
            result.reserveCapacity(contexts.count)
            var records: [AIPatternDiagnostic] = []
            records.reserveCapacity(contexts.count)
            var offset = 0
            for ctx in contexts {
                let count = ctx.candidates.count
                let scores = Array(aiScores[offset..<(offset + count)])
                offset += count
                let outcome = AIPatternFusion.rank(candidates: ctx.candidates,
                                                   fits: ctx.fits,
                                                   aiScores: scores,
                                                   config: cfg)
                let chosen = outcome.chosenIndex
                let used = outcome.usedAI && chosen != nil
                let chosenCandidate = chosen.flatMap { ctx.candidates.indices.contains($0) ? ctx.candidates[$0] : nil }
                let candidateRecords: [AIPatternCandidateDiagnostic] = ctx.candidates.indices.map { i in
                    AIPatternCandidateDiagnostic(template: ctx.candidates[i].template,
                                                 motif: ctx.candidates[i].motif,
                                                 startLane: ctx.candidates[i].startLane,
                                                 dspFit: ctx.fits[i],
                                                 aiScore: outcome.aiScores?[i],
                                                 finalScore: outcome.finalScores[i])
                }
                // Empty-candidate contexts are skipped upstream at context
                // construction; the firstCandidate fallback is belt-and-braces
                // so a future caller can never trap here (crash audit).
                let firstCandidate = ctx.candidates.first
                records.append(AIPatternDiagnostic(variant: ctx.variant,
                                                   phraseIndex: ctx.phraseIndex,
                                                   phraseStart: ctx.phraseStart,
                                                   template: chosenCandidate?.template ?? firstCandidate?.template ?? .rest,
                                                   motif: chosenCandidate?.motif ?? firstCandidate?.motif ?? .free,
                                                   startLane: chosenCandidate?.startLane ?? firstCandidate?.startLane ?? 0,
                                                   candidates: candidateRecords,
                                                   chosenIndex: chosen,
                                                   usedAI: used,
                                                   aiConfidence: outcome.aiConfidence,
                                                   features: (0..<count).map { PatternFeatureExtractor.extract(context: ctx, candidateIndex: $0) }))
                result.append(PatternRanking(variant: ctx.variant,
                                             phraseIndex: ctx.phraseIndex,
                                             candidates: ctx.candidates,
                                             chosenIndex: chosen,
                                             usedAI: used,
                                             aiConfidence: outcome.aiConfidence))
            }
            return (result, records)
        }.value

        var diag = diagnosticsBySong[songID] ?? AISongDiagnostics(songID: songID, generatedAt: Date(),
                                                                  modelVersion: AIModelCatalog.patternModelVersion,
                                                                  featureSchemaVersion: AIModelCatalog.featureSchemaVersion)
        diag.patternInferenceMs = await engine.lastPredictionTimeMs()
        diag.patterns = computed.1
        diagnosticsBySong[songID] = diag
        return computed.0
    }

    // MARK: - Diagnostics

    /// Marks each candidate event as charted/rejected from the final chart and
    /// persists the song's diagnostics. Call after the chart is saved.
    /// Both lists are time-sorted, so the matching pass is a single linear
    /// sweep (was O(events × notes) — visible on long songs).
    func finalizeDiagnostics(songID: UUID, chart: Chart) {
        guard var diag = diagnosticsBySong[songID] else { return }
        let noteTimes = chart.notes.map(\.time).sorted()
        var notePtr = 0
        for i in diag.events.indices {
            let eventTime = diag.events[i].time
            while notePtr < noteTimes.count && noteTimes[notePtr] < eventTime - 0.055 {
                notePtr += 1
            }
            diag.events[i].selected = notePtr < noteTimes.count
                && abs(noteTimes[notePtr] - eventTime) <= 0.055
        }
        diag.generatedAt = Date()
        diagnosticsBySong[songID] = diag
        // JSON encode + file write off the main actor; harmless if it races a
        // later finalize for the same song (last write wins, per-song files).
        let store = self.store
        Task.detached(priority: .utility) { store.save(diag) }
    }

    func diagnostics(for songID: UUID) -> AISongDiagnostics? {
        diagnosticsBySong[songID] ?? store.load(songID: songID)
    }

    /// Loads persisted diagnostics for all songs (e.g. for the debug view).
    func allDiagnostics() -> [AISongDiagnostics] {
        store.loadAll()
    }

    /// Developer export: all persisted diagnostics as JSONL in
    /// Documents/AIExport. Contains feature vectors + predictions + scores —
    /// never raw audio.
    func exportAllDiagnostics() -> URL? {
        store.exportAll()
    }

    /// True when all models are bundled and loadable (checked async).
    func availability() async -> (difficulty: Bool, event: Bool, pattern: Bool, error: String?) {
        let d = await engine.isDifficultyAvailable()
        let e = await engine.isEventAvailable()
        let p = await engine.isPatternAvailable()
        let err = await engine.lastError()
        return (d, e, p, err)
    }
}

/// Nonisolated bridge so the chart generator (a plain, nonisolated type) can
/// consult the MainActor `AISystem` without leaking actor isolation into the
/// generator's interface. All calls hop to the main actor and are async.
struct AIChartAdvisorBridge: AIChartAdvisor {
    let system: AISystem

    func difficultyOutcome(songID: UUID,
                           notes: [ChartNote],
                           metrics: DifficultyMetrics,
                           analysis: AudioAnalysis) async -> AIDifficultyOutcome? {
        await system.difficultyOutcome(songID: songID, notes: notes, metrics: metrics, analysis: analysis)
    }

    func eventImportance(songID: UUID,
                         events: [MusicalEvent],
                         analysis: AudioAnalysis) async -> [Double]? {
        await system.eventImportance(songID: songID, events: events, analysis: analysis)
    }

    func patternRanking(songID: UUID,
                        contexts: [PatternRankingContext],
                        analysis: AudioAnalysis,
                        difficulty: DifficultyLevel) async -> [PatternRanking]? {
        await system.patternRanking(songID: songID, contexts: contexts,
                                    analysis: analysis, difficulty: difficulty)
    }
}

/// JSON persistence for per-song AI diagnostics (application support, on-device).
struct AIDiagnosticsStore: Sendable {
    private static func url(for songID: UUID) -> URL {
        AppDirectories.aiDiagnosticsDirectory.appendingPathComponent(songID.uuidString + ".ai-diag.json")
    }

    func save(_ diag: AISongDiagnostics) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(diag).write(to: Self.url(for: diag.songID), options: .atomic)
    }

    func load(songID: UUID) -> AISongDiagnostics? {
        let url = Self.url(for: songID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AISongDiagnostics.self, from: Data(contentsOf: url))
    }

    func loadAll() -> [AISongDiagnostics] {
        let dir = AppDirectories.aiDiagnosticsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.compactMap {
            try? decoder.decode(AISongDiagnostics.self, from: Data(contentsOf: $0))
        }
    }

    /// JSONL export of every persisted diagnostics record (no audio).
    func exportAll() -> URL? {
        let records = loadAll()
        guard !records.isEmpty else { return nil }
        let dir = AppDirectories.documentsDirectory.appendingPathComponent("AIExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ai-diagnostics-\(Int(Date().timeIntervalSince1970)).jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var lines: [String] = []
        for record in records {
            if let data = try? encoder.encode(record), let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}