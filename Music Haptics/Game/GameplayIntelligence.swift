import Foundation
import Observation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The two analysis tiers share the same deterministic profile and gameplay
/// engine. The tier never changes scoring, note timestamps, or frame timing.
enum GameplayIntelligenceTier: String, Codable, Sendable, Equatable {
    case standardMath
    case enhancedOnDeviceAI

    var displayName: String {
        switch self {
        case .standardMath: return "Standard Math Engine"
        case .enhancedOnDeviceAI: return "Enhanced On-Device AI"
        }
    }
}

/// Current availability of Apple's system Foundation Model. This is refreshed
/// from the OS; it is deliberately not persisted as an app preference.
enum OnDeviceAIAvailability: String, Codable, Sendable, Equatable {
    case checking
    case enhancedAvailable
    case deviceNotEligible
    case appleIntelligenceDisabled
    case modelNotReady
    case unsupportedOS
    case temporaryFailure

    var supportsEnhancedTier: Bool { self == .enhancedAvailable }

    var tier: GameplayIntelligenceTier {
        supportsEnhancedTier ? .enhancedOnDeviceAI : .standardMath
    }

    var title: String {
        switch self {
        case .checking: return "Checking availability…"
        case .enhancedAvailable: return "Enhanced On-Device AI available"
        case .deviceNotEligible, .unsupportedOS: return "Standard Gameplay Intelligence"
        case .appleIntelligenceDisabled: return "Apple Intelligence is turned off"
        case .modelNotReady: return "Apple's model is not ready yet"
        case .temporaryFailure: return "Enhanced analysis unavailable"
        }
    }

    var message: String {
        switch self {
        case .checking:
            return "Checking Apple's current system availability."
        case .enhancedAvailable:
            return "Apple's on-device intelligence is ready for optional pre-game analysis."
        case .deviceNotEligible:
            return "Your device can't use Apple's on-device intelligence for Haptic Tiles. The Standard Math Engine will continue powering gameplay normally."
        case .appleIntelligenceDisabled:
            return "Apple Intelligence is turned off in the system. Haptic Tiles will continue using the Standard Math Engine."
        case .modelNotReady:
            return "Apple's system model is still preparing. Haptic Tiles will continue using the Standard Math Engine until it is ready."
        case .unsupportedOS:
            return "This iOS version does not provide Foundation Models. Haptic Tiles will continue using the Standard Math Engine."
        case .temporaryFailure:
            return "Apple's on-device model is temporarily unavailable. Haptic Tiles will continue using the Standard Math Engine."
        }
    }
}

/// Compact, bounded context passed to the optional Foundation Model. It describes
/// gameplay structure rather than raw audio or identity, and is also useful for
/// deterministic diagnostics when the model is unavailable.
struct GameplayAISectionContext: Codable, Sendable, Equatable {
    let index: Int
    let label: String
    let start: Double
    let end: Double
    let energy: Double
    let noteCount: Int
    let notesPerSecond: Double
    let chordCount: Int
    let chordFrequency: Double
    let holdCount: Int
    let holdFrequency: Double
    let averageHoldDuration: Double
    let maximumHoldDuration: Double
    let maximumLaneJump: Int
    let speedMultiplierMinimum: Double
    let speedMultiplierMaximum: Double
}

struct GameplayAIContext: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let duration: Double
    let bpm: Double?
    let difficulty: DifficultyLevel
    let noteCount: Int
    let notesPerSecond: Double
    let averageInterval: Double
    let minimumInterval: Double
    let chordCount: Int
    let holdCount: Int
    let averageHoldDuration: Double
    let maximumHoldDuration: Double
    let maximumLaneJump: Int
    let dynamicSpeedEnabled: Bool
    let dynamicSpeedIntensity: DynamicSpeedIntensity
    let standardSpeedPoints: [DynamicSpeedProfile.SpeedCurvePoint]
    let speedMultiplierMinimum: Double
    let speedMultiplierMaximum: Double
    let accelerationTransitionCount: Int
    let decelerationTransitionCount: Int
    let speedTransitionMagnitude: Double
    let maximumDensitySpike: Double
    let maximumSimultaneous: Int
    let holdOverlapCount: Int
    let holdClusterCount: Int
    let longHoldFraction: Double
    let repeatedIntervalRate: Double
    let spatialTravelRisk: Double
    let sections: [GameplayAISectionContext]

    /// Builds a bounded summary once during preparation. The real-time engine
    /// never constructs or reads this value.
    static func make(chart: Chart, analysis: AudioAnalysis?,
                     standardProfile: DynamicSpeedProfile,
                     dynamicSpeedEnabled: Bool,
                     dynamicSpeedIntensity: DynamicSpeedIntensity) -> GameplayAIContext {
        let duration = max(1, max(analysis?.duration ?? chart.duration, chart.lastNoteTime + 1))
        let notes = chart.notes.filter {
            $0.time.isFinite && $0.duration.isFinite && $0.time >= 0 && $0.time <= duration
        }.sorted { $0.time < $1.time }
        let intervals = zip(notes, notes.dropFirst()).map { $1.time - $0.time }
            .filter { $0.isFinite && $0 > 0.001 }
        let averageInterval = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        let minimumInterval = intervals.min() ?? 0
        let holds = notes.filter { $0.type == .hold && $0.duration > 0 }
        let averageHold = holds.isEmpty ? 0 : holds.map(\.duration).reduce(0, +) / Double(holds.count)
        let chordCount = chordGroupCount(notes)
        var maximumLaneJump = 0
        for pair in zip(notes, notes.dropFirst()) {
            maximumLaneJump = max(maximumLaneJump, abs(pair.1.lane - pair.0.lane))
        }

        let sections = (analysis?.sections ?? []).sorted { $0.start < $1.start }.prefix(24).map { section in
            let sectionNotes = notes.filter { $0.time >= section.start && $0.time < section.end }
            let sectionHolds = sectionNotes.filter { $0.type == .hold && $0.duration > 0 }
            let sectionChordCount = chordGroupCount(sectionNotes)
            let sectionDuration = max(0.25, section.end - section.start)
            var sectionMaximumJump = 0
            for pair in zip(sectionNotes, sectionNotes.dropFirst()) {
                sectionMaximumJump = max(sectionMaximumJump, abs(pair.1.lane - pair.0.lane))
            }
            let sectionSpeedValues = sectionNotes.map { standardProfile.multiplier(at: $0.time) }
            return GameplayAISectionContext(
                index: section.index,
                label: section.label.rawValue,
                start: max(0, section.start),
                end: min(duration, max(section.start, section.end)),
                energy: clamp(section.energy, 0, 1),
                noteCount: sectionNotes.count,
                notesPerSecond: Double(sectionNotes.count) / sectionDuration,
                chordCount: sectionChordCount,
                chordFrequency: sectionNotes.isEmpty ? 0 : Double(sectionChordCount) / Double(sectionNotes.count),
                holdCount: sectionHolds.count,
                holdFrequency: sectionNotes.isEmpty ? 0 : Double(sectionHolds.count) / Double(sectionNotes.count),
                averageHoldDuration: sectionHolds.isEmpty ? 0 : sectionHolds.map(\.duration).reduce(0, +) / Double(sectionHolds.count),
                maximumHoldDuration: sectionHolds.map(\.duration).max() ?? 0,
                maximumLaneJump: sectionMaximumJump,
                speedMultiplierMinimum: sectionSpeedValues.min() ?? standardProfile.multiplier(at: section.start),
                speedMultiplierMaximum: sectionSpeedValues.max() ?? standardProfile.multiplier(at: section.start))
        }

        let speedValues = standardProfile.points.map(\.multiplier)
        let speedTransitions = zip(speedValues, speedValues.dropFirst())
        let accelerationTransitionCount = speedTransitions.filter { $1 > $0 + 0.01 }.count
        let decelerationTransitionCount = speedTransitions.filter { $1 < $0 - 0.01 }.count
        let speedTransitionMagnitude = speedTransitions.map { abs($1 - $0) }.max() ?? 0
        let maximumSimultaneous = maximumSimultaneousCount(notes)
        let holdOverlapCount = holdOverlapCount(holds)
        let holdClusterCount = holdClusterCount(holds)
        let longHoldFraction = holds.isEmpty ? 0 : Double(holds.filter { $0.duration >= 1.5 }.count) / Double(holds.count)
        let repeatedIntervalRate = repeatedIntervalRate(intervals)
        let maximumDensitySpike = maximumDensitySpike(notes: notes, duration: duration)
        let spatialTravelRisk = min(1, (Double(maximumLaneJump) / 3) * 0.55
                                    + (maximumSimultaneous > 1 ? 0.20 : 0)
                                    + (repeatedIntervalRate * 0.15)
                                    + (speedTransitionMagnitude * 0.10))

        return GameplayAIContext(
            schemaVersion: schemaVersion,
            duration: duration,
            bpm: analysis?.tempoBPM,
            difficulty: chart.difficulty,
            noteCount: notes.count,
            notesPerSecond: Double(notes.count) / duration,
            averageInterval: averageInterval,
            minimumInterval: minimumInterval,
            chordCount: chordCount,
            holdCount: holds.count,
            averageHoldDuration: averageHold,
            maximumHoldDuration: holds.map(\.duration).max() ?? 0,
            maximumLaneJump: maximumLaneJump,
            dynamicSpeedEnabled: dynamicSpeedEnabled,
            dynamicSpeedIntensity: dynamicSpeedIntensity,
            standardSpeedPoints: standardProfile.points.prefix(16).map {
                // The model contract uses normalized signals (-1…1), not raw
                // multipliers. Keeping that distinction explicit prevents an
                // AI response from learning the wrong scale.
                DynamicSpeedProfile.SpeedCurvePoint(time: $0.time,
                                                    intensity: clamp($0.multiplier - 1, -1, 1))
            },
            speedMultiplierMinimum: speedValues.min() ?? 1,
            speedMultiplierMaximum: speedValues.max() ?? 1,
            accelerationTransitionCount: accelerationTransitionCount,
            decelerationTransitionCount: decelerationTransitionCount,
            speedTransitionMagnitude: speedTransitionMagnitude,
            maximumDensitySpike: maximumDensitySpike,
            maximumSimultaneous: maximumSimultaneous,
            holdOverlapCount: holdOverlapCount,
            holdClusterCount: holdClusterCount,
            longHoldFraction: longHoldFraction,
            repeatedIntervalRate: repeatedIntervalRate,
            spatialTravelRisk: spatialTravelRisk,
            sections: Array(sections))
    }

    private static func chordGroupCount(_ notes: [ChartNote]) -> Int {
        guard notes.count > 1 else { return 0 }
        var result = 0
        var index = 0
        while index < notes.count {
            var end = index + 1
            while end < notes.count && notes[end].time - notes[index].time < 0.1 { end += 1 }
            if end - index > 1 { result += 1 }
            index = end
        }
        return result
    }

    private static func maximumSimultaneousCount(_ notes: [ChartNote]) -> Int {
        guard !notes.isEmpty else { return 0 }
        var best = 1
        var right = 0
        for left in notes.indices {
            while right < notes.count && notes[right].time - notes[left].time < 0.1 { right += 1 }
            best = max(best, right - left)
        }
        return best
    }

    private static func holdOverlapCount(_ holds: [ChartNote]) -> Int {
        guard holds.count > 1 else { return 0 }
        var count = 0
        let sorted = holds.sorted { $0.time < $1.time }
        for i in 1..<sorted.count {
            let current = sorted[i]
            if sorted[..<i].contains(where: { $0.lane == current.lane && $0.time + $0.duration > current.time }) {
                count += 1
            }
        }
        return count
    }

    private static func holdClusterCount(_ holds: [ChartNote]) -> Int {
        guard !holds.isEmpty else { return 0 }
        let sorted = holds.sorted { $0.time < $1.time }
        var clusters = 1
        for pair in zip(sorted, sorted.dropFirst()) where pair.1.time - pair.0.time > 0.75 {
            clusters += 1
        }
        return clusters
    }

    private static func repeatedIntervalRate(_ intervals: [Double]) -> Double {
        guard intervals.count >= 3 else { return 0 }
        var bins: [Int: Int] = [:]
        for interval in intervals {
            bins[Int((interval * 50).rounded()), default: 0] += 1
        }
        let repeated = bins.values.filter { $0 > 1 }.reduce(0) { $0 + $1 }
        return min(1, Double(repeated) / Double(intervals.count))
    }

    private static func maximumDensitySpike(notes: [ChartNote], duration: Double) -> Double {
        guard notes.count >= 4 else { return 1 }
        let bucketCount = min(24, max(4, Int((duration / 4).rounded())))
        let length = duration / Double(bucketCount)
        var counts = Array(repeating: 0, count: bucketCount)
        for note in notes {
            let index = min(bucketCount - 1, max(0, Int(note.time / max(length, 0.001))))
            counts[index] += 1
        }
        let densities = counts.map { Double($0) / max(length, 0.001) }
        let mean = densities.reduce(0, +) / Double(densities.count)
        return mean > 0 ? min(12, (densities.max() ?? mean) / mean) : 1
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value.isFinite ? value : 0))
    }
}

/// A finding is advisory metadata for diagnostics and future chart-review UI.
/// It cannot mutate chart events or timing.
struct GameplayAIQualityFinding: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let category: String
    let severity: Double
    let sectionIndex: Int?
    let explanation: String
    let suggestedCorrection: String

    init(id: UUID = UUID(), category: String, severity: Double,
         sectionIndex: Int?, explanation: String, suggestedCorrection: String) {
        self.id = id
        self.category = category
        self.severity = severity
        self.sectionIndex = sectionIndex
        self.explanation = explanation
        self.suggestedCorrection = suggestedCorrection
    }
}

/// The persisted result of one bounded pre-game AI planning pass. Points are
/// normalized signals consumed by the existing deterministic speed profile;
/// findings are advisory and never rewrite the chart.
struct PreparedGameplayPlan: Codable, Sendable, Equatable {
    static let schemaVersion = 2
    static let modelVersion = 3

    let songID: UUID
    let chartVersion: Int
    let noteCount: Int
    let duration: Double
    let points: [DynamicSpeedProfile.SpeedCurvePoint]
    let findings: [GameplayAIQualityFinding]
    let confidence: Double
    let dynamicSpeedIntensity: DynamicSpeedIntensity
    let recommendedDifficulty: DifficultyLevel?
    let recommendedHoldDensity: Double?
    let recommendedChordDensity: Double?
    let schemaVersion: Int
    let modelVersion: Int
}

/// A validated, compact result from pre-game Foundation Models analysis. Only
/// normalized signals are stored; raw audio, prompts, and player identity are
/// never persisted.
struct PreparedGameplaySpeedCurve: Codable, Sendable, Equatable {
    static let schemaVersion = 1
    static let modelVersion = 1

    let songID: UUID
    let chartVersion: Int
    let noteCount: Int
    let duration: Double
    let points: [DynamicSpeedProfile.SpeedCurvePoint]
    let schemaVersion: Int
    let modelVersion: Int
}

/// A recommendation generated from local historical gameplay. It is advisory:
/// it never changes settings until the player explicitly applies it.
struct PlayerRecommendation: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let generatedAt: Date
    let summary: String
    let recommendedDifficulty: DifficultyLevel
    let dynamicSpeedEnabled: Bool
    let dynamicSpeedIntensity: DynamicSpeedIntensity
    let confidence: Double
}

/// Validation boundary for all model-produced speed points and recommendations.
/// Keeping this pure makes it testable without a Foundation Models runtime.
enum GameplayIntelligenceValidation {
    static func speedPoints(_ raw: [DynamicSpeedProfile.SpeedCurvePoint],
                            duration: Double) -> [DynamicSpeedProfile.SpeedCurvePoint]? {
        guard raw.count <= 24 else { return nil }
        let safeDuration = max(1, duration.isFinite ? duration : 1)
        let points = raw.compactMap { point -> DynamicSpeedProfile.SpeedCurvePoint? in
            guard point.time.isFinite, point.intensity.isFinite else { return nil }
            return DynamicSpeedProfile.SpeedCurvePoint(
                time: min(safeDuration, max(0, point.time)),
                intensity: min(1, max(-1, point.intensity)))
        }.sorted { $0.time < $1.time }

        var deduplicated: [DynamicSpeedProfile.SpeedCurvePoint] = []
        for point in points {
            if let last = deduplicated.last, abs(last.time - point.time) < 0.01 {
                deduplicated[deduplicated.count - 1] = point
            } else {
                deduplicated.append(point)
            }
        }
        guard deduplicated.count >= 2 else { return nil }
        if deduplicated[0].time > 0 {
            deduplicated.insert(DynamicSpeedProfile.SpeedCurvePoint(time: 0,
                                                                     intensity: deduplicated[0].intensity), at: 0)
        }
        if deduplicated.last?.time ?? 0 < safeDuration {
            deduplicated.append(DynamicSpeedProfile.SpeedCurvePoint(
                time: safeDuration,
                intensity: deduplicated.last?.intensity ?? 0))
        }
        return deduplicated
    }

    static func qualityFindings(_ raw: [GameplayAIQualityFinding], sectionCount: Int) -> [GameplayAIQualityFinding] {
        raw.prefix(24).map { finding in
            let index: Int?
            if let sectionIndex = finding.sectionIndex, sectionCount > 0 {
                index = min(sectionCount - 1, max(0, sectionIndex))
            } else {
                index = nil
            }
            return GameplayAIQualityFinding(
                category: String(finding.category.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48)),
                severity: min(1, max(0, finding.severity.isFinite ? finding.severity : 0)),
                sectionIndex: index,
                explanation: String(finding.explanation.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)),
                suggestedCorrection: String(finding.suggestedCorrection.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)))
        }.filter { !$0.category.isEmpty && !$0.explanation.isEmpty }
    }

    static func gameplayPlan(points rawPoints: [DynamicSpeedProfile.SpeedCurvePoint],
                             findings rawFindings: [GameplayAIQualityFinding],
                             confidence: Double, songID: UUID, chart: Chart,
                             duration: Double, sectionCount: Int,
                             intensity: DynamicSpeedIntensity = .standard,
                             recommendedDifficulty: DifficultyLevel? = nil,
                             recommendedHoldDensity: Double? = nil,
                             recommendedChordDensity: Double? = nil) -> PreparedGameplayPlan? {
        guard let points = speedPoints(rawPoints, duration: duration) else { return nil }
        return PreparedGameplayPlan(
            songID: songID,
            chartVersion: chart.chartVersion,
            noteCount: chart.notes.count,
            duration: max(1, duration),
            points: points,
            findings: qualityFindings(rawFindings, sectionCount: sectionCount),
            confidence: min(1, max(0, confidence.isFinite ? confidence : 0)),
            dynamicSpeedIntensity: intensity,
            recommendedDifficulty: recommendedDifficulty,
            recommendedHoldDensity: boundedRecommendation(recommendedHoldDensity),
            recommendedChordDensity: boundedRecommendation(recommendedChordDensity),
            schemaVersion: PreparedGameplayPlan.schemaVersion,
            modelVersion: PreparedGameplayPlan.modelVersion)
    }

    private static func boundedRecommendation(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    static func hasSufficientHistory(_ snapshot: StatsSnapshot,
                                     minimumAttempts: Int = 3) -> Bool {
        guard minimumAttempts > 0 else { return true }
        let attempts = snapshot.stats.reduce(0) { total, song in
            total + song.perDifficulty.reduce(0) { $0 + max(0, $1.attempts) }
        }
        return attempts >= minimumAttempts
    }
    static func playerRecommendation(summary: String,
                                     difficulty: String,
                                     dynamicSpeed: Bool,
                                     intensity: String,
                                     confidence: Double,
                                     generatedAt: Date = Date()) -> PlayerRecommendation? {
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSummary.isEmpty else { return nil }
        let normalizedDifficulty = difficulty.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedIntensity = intensity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let difficulty = DifficultyLevel(rawValue: normalizedDifficulty),
              let intensity = DynamicSpeedIntensity(rawValue: normalizedIntensity) else {
            return nil
        }
        return PlayerRecommendation(id: UUID(), generatedAt: generatedAt,
                                    summary: String(cleanSummary.prefix(320)),
                                    recommendedDifficulty: difficulty,
                                    dynamicSpeedEnabled: dynamicSpeed,
                                    dynamicSpeedIntensity: intensity,
                                    confidence: min(1, max(0, confidence.isFinite ? confidence : 0)))
    }
}

/// App-level coordinator for the optional enhanced tier. It owns only cached
/// pre-game analysis and post-game recommendations; no method is called by the
/// per-frame renderer, input judge, or scoring loop.
@MainActor
@Observable
final class OnDeviceAIService {
    private(set) var availability: OnDeviceAIAvailability = .checking
    private(set) var lastError: String?
    private(set) var latestRecommendation: PlayerRecommendation?
    private(set) var latestGameplayPlan: PreparedGameplayPlan?
    /// Mirrors the user's current preference for post-game analysis. Availability
    /// is still refreshed from the system and is never persisted here.
    var settingsAllowsAnalysis = false
    private var cachedCurves: [UUID: PreparedGameplaySpeedCurve] = [:]
    private var cachedPlans: [UUID: PreparedGameplayPlan] = [:]

    init() {
        latestRecommendation = PlayerRecommendationStore.load()
    }

    /// Reads Apple's actual system availability. On iOS versions before 26,
    /// the app never loads or downloads a model and stays on Standard Math.
    @discardableResult
    func refresh() async -> OnDeviceAIAvailability {
        availability = .checking
        lastError = nil
        availability = Self.readSystemAvailability()
        return availability
    }

    /// Prepares a structured chart/hold quality plan before gameplay. The model
    /// receives only a compact local context; the returned plan is validated
    /// before any speed signal reaches the deterministic profile.
    func prepareGameplayPlan(songID: UUID, chart: Chart, analysis: AudioAnalysis?, enabled: Bool,
                             intensity: DynamicSpeedIntensity = .standard) async -> PreparedGameplayPlan? {
        guard enabled else {
            #if DEBUG
            print("[AI] gameplay plan skipped: disabled")
            #endif
            return nil
        }
        await refresh()
        guard availability == .enhancedAvailable else {
            #if DEBUG
            print("[AI] gameplay plan fallback: \(availability.rawValue)")
            #endif
            return nil
        }
        guard let analysis else { return nil }
        let standardProfile = DynamicSpeedProfile.make(analysis: analysis, chart: chart,
                                                        enabled: true, intensity: intensity)
        let context = GameplayAIContext.make(chart: chart, analysis: analysis,
                                             standardProfile: standardProfile,
                                             dynamicSpeedEnabled: true,
                                             dynamicSpeedIntensity: intensity)
        let duration = context.duration
        if let memory = cachedPlans[songID], Self.matches(memory, songID: songID, chart: chart, duration: duration,
                                currentIntensity: intensity) {
            latestGameplayPlan = memory
            #if DEBUG
            print("[AI] gameplay plan accepted: cache")
            #endif
            return memory
        }
        let cached = await Task.detached(priority: .utility) {
            GameplayIntelligenceCache.loadPlan(songID: songID)
        }.value
        if let cached, Self.matches(cached, songID: songID, chart: chart, duration: duration,
                                     currentIntensity: intensity) {
            cachedPlans[songID] = cached
            latestGameplayPlan = cached
            #if DEBUG
            print("[AI] gameplay plan accepted: disk cache")
            #endif
            return cached
        }
        guard #available(iOS 26.0, *) else { return nil }
        let result = await Self.boundedResult(timeout: .seconds(2), fallback: nil) {
            await FoundationModelsGameplayAnalyzer.analyze(context: context)
        }
        guard let result else {
            #if DEBUG
            print("[AI] gameplay plan fallback: timed out or unavailable")
            #endif
            return nil
        }
        let requestedDifficulty = DifficultyLevel(rawValue: result.recommendedDifficulty.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let safeHoldDensity = result.recommendedHoldDensity.isFinite ? result.recommendedHoldDensity : nil
        let safeChordDensity = result.recommendedChordDensity.isFinite ? result.recommendedChordDensity : nil
        guard let plan = GameplayIntelligenceValidation.gameplayPlan(
                points: result.points.map { DynamicSpeedProfile.SpeedCurvePoint(time: $0.time, intensity: $0.intensity) },
                findings: result.findings.map {
                    GameplayAIQualityFinding(category: $0.category, severity: $0.severity,
                                             sectionIndex: $0.sectionIndex < 0 ? nil : $0.sectionIndex,
                                             explanation: $0.explanation,
                                             suggestedCorrection: $0.suggestedCorrection)
                },
                confidence: result.confidence,
                songID: songID, chart: chart, duration: duration,
                sectionCount: context.sections.count, intensity: intensity,
                recommendedDifficulty: requestedDifficulty,
                recommendedHoldDensity: safeHoldDensity,
                recommendedChordDensity: safeChordDensity) else {
            #if DEBUG
            print("[AI] gameplay plan rejected: invalid structured output")
            #endif
            return nil
        }
        cachedPlans[songID] = plan
        latestGameplayPlan = plan
        let toSave = plan
        Task.detached(priority: .utility) {
            GameplayIntelligenceCache.savePlan(toSave)
        }
        #if DEBUG
        print("[AI] gameplay plan accepted: points=\(plan.points.count) findings=\(plan.findings.count)")
        #endif
        return plan
    }

    /// Compatibility API used by existing call sites/tests. It now delegates
    /// to the richer structured plan and returns only its validated pacing
    /// points to the existing deterministic movement engine.
    func prepareSpeedCurve(songID: UUID, chart: Chart, analysis: AudioAnalysis?, enabled: Bool,
                           intensity: DynamicSpeedIntensity = .standard)
        async -> [DynamicSpeedProfile.SpeedCurvePoint]? {
        await prepareGameplayPlan(songID: songID, chart: chart, analysis: analysis,
                                  enabled: enabled, intensity: intensity)?.points
    }

    /// Returns validated pre-game speed advice, or nil for the deterministic
    /// Standard Math fallback. The Foundation Models request is bounded so a
    /// slow/preparing system model can never block starting a song forever.
    /* legacy implementation moved to prepareGameplayPlan */
    /*
    func prepareSpeedCurve(songID: UUID, chart: Chart, analysis: AudioAnalysis?, enabled: Bool)
        async -> [DynamicSpeedProfile.SpeedCurvePoint]? {
        guard enabled else { return nil }
        // Foundation Models availability can change while the app remains
        // open (system settings, storage, or model preparation). Refresh at
        // the pre-game boundary so cached advice can never bypass a current
        // unavailable state.
        await refresh()
        guard availability == .enhancedAvailable else { return nil }

        let duration = max(1, max(analysis?.duration ?? chart.duration, chart.lastNoteTime + 1))
        if let memory = cachedCurves[songID], Self.matches(memory, songID: songID,
                                                           chart: chart, duration: duration) {
            return memory.points
        }

        let cached = await Task.detached(priority: .utility) {
            GameplayIntelligenceCache.load(songID: songID)
        }.value
        if let cached, Self.matches(cached, songID: songID, chart: chart, duration: duration) {
            cachedCurves[songID] = cached
            return cached.points
        }

        if availability == .checking {
            await refresh()
        }
        guard availability == .enhancedAvailable, let analysis else { return nil }
        guard #available(iOS 26.0, *) else { return nil }

        let result = await Self.boundedResult(timeout: .seconds(2), fallback: nil) {
            await FoundationModelsSpeedAnalyzer.analyze(chart: chart, analysis: analysis)
        }
        guard let points = result,
              let validated = GameplayIntelligenceValidation.speedPoints(points, duration: duration) else {
            return nil
        }

        let prepared = PreparedGameplaySpeedCurve(
            songID: songID,
            chartVersion: chart.chartVersion,
            noteCount: chart.notes.count,
            duration: duration,
            points: validated,
            schemaVersion: PreparedGameplaySpeedCurve.schemaVersion,
            modelVersion: PreparedGameplaySpeedCurve.modelVersion)
        cachedCurves[songID] = prepared
        let toSave = prepared
        Task.detached(priority: .utility) {
            GameplayIntelligenceCache.save(toSave)
        }
        return validated
    }
    */

    /// Runs the optional post-game player analysis only while the app is idle
    /// on results/settings. The caller cancels this work before another song
    /// starts, so model work never enters active gameplay.
    func analyzePlayerHistory(snapshot: StatsSnapshot, latestResult: GameplayResult) async {
        guard settingsAllowsAnalysis, availability == .enhancedAvailable else { return }
        guard GameplayIntelligenceValidation.hasSufficientHistory(snapshot) else { return }
        guard #available(iOS 26.0, *) else { return }
        let result = await Self.boundedResult(timeout: .seconds(2), fallback: nil) {
            await FoundationModelsPlayerAnalyzer.analyze(snapshot: snapshot,
                                                         latestResult: latestResult)
        }
        guard let result else { return }
        latestRecommendation = result
        PlayerRecommendationStore.save(result)
    }

    /// Returns the first result or the fallback at the deadline. The worker is
    /// intentionally unstructured: a Foundation Models request that is slow
    /// to honor cancellation cannot hold the caller past the two-second bound.
    private nonisolated static func boundedResult<T: Sendable>(
        timeout: Duration,
        fallback: T,
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        let stream = AsyncStream<T>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let worker = Task {
                let value = await operation()
                continuation.yield(value)
                continuation.finish()
            }
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                worker.cancel()
                continuation.yield(fallback)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                worker.cancel()
                timeoutTask.cancel()
            }
        }
        for await value in stream {
            return value
        }
        return fallback
    }


    func tier(enabled: Bool) -> GameplayIntelligenceTier {
        enabled && availability.supportsEnhancedTier ? .enhancedOnDeviceAI : .standardMath
    }

    private static func matches(_ plan: PreparedGameplayPlan,
                                songID: UUID, chart: Chart, duration: Double,
                                currentIntensity: DynamicSpeedIntensity = .standard) -> Bool {
        plan.songID == songID
            && plan.chartVersion == chart.chartVersion
            && plan.noteCount == chart.notes.count
            && abs(plan.duration - duration) < 0.01
            && plan.schemaVersion == PreparedGameplayPlan.schemaVersion
            && plan.modelVersion == PreparedGameplayPlan.modelVersion
            && plan.dynamicSpeedIntensity == currentIntensity
            && plan.points.count >= 2
            && GameplayIntelligenceValidation.speedPoints(plan.points, duration: duration) != nil
            && plan.confidence.isFinite && (0...1).contains(plan.confidence)
            && plan.points.allSatisfy { $0.time.isFinite && $0.intensity.isFinite }
            && plan.findings.count <= 24
            && plan.findings.allSatisfy {
                $0.category.count <= 48
                    && !$0.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.explanation.count <= 240
                    && !$0.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.suggestedCorrection.count <= 240
                    && $0.severity.isFinite && (0...1).contains($0.severity)
                    && ($0.sectionIndex == nil || (0..<24).contains($0.sectionIndex!))
            }
            && [plan.recommendedHoldDensity, plan.recommendedChordDensity].compactMap { $0 }.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    private static func matches(_ curve: PreparedGameplaySpeedCurve,
                                songID: UUID, chart: Chart, duration: Double) -> Bool {
        curve.songID == songID
            && curve.chartVersion == chart.chartVersion
            && curve.noteCount == chart.notes.count
            && abs(curve.duration - duration) < 0.01
            && curve.schemaVersion == PreparedGameplaySpeedCurve.schemaVersion
            && curve.modelVersion == PreparedGameplaySpeedCurve.modelVersion
            && curve.points.count >= 2
    }

    private static func readSystemAvailability() -> OnDeviceAIAvailability {
        #if os(iOS) && canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .enhancedAvailable
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .appleIntelligenceDisabled
                case .modelNotReady: return .modelNotReady
                @unknown default: return .temporaryFailure
                }
            }
        }
        return .unsupportedOS
        #else
        return .unsupportedOS
        #endif
    }
}

/// Local JSON cache for prepared speed curves. Deleting it never affects the
/// chart, score, timing rules, or Standard Math fallback.
enum GameplayIntelligenceCache {
    private static func url(for songID: UUID) -> URL {
        AppDirectories.aiDiagnosticsDirectory
            .appendingPathComponent(songID.uuidString + ".speed-curve.json")
    }

    static func loadPlan(songID: UUID) -> PreparedGameplayPlan? {
        guard let data = try? Data(contentsOf: url(for: songID, suffix: ".gameplay-plan.json")) else { return nil }
        return try? JSONDecoder().decode(PreparedGameplayPlan.self, from: data)
    }

    static func savePlan(_ plan: PreparedGameplayPlan) {
        guard let data = try? JSONEncoder().encode(plan) else { return }
        try? data.write(to: url(for: plan.songID, suffix: ".gameplay-plan.json"), options: .atomic)
    }

    private static func url(for songID: UUID, suffix: String) -> URL {
        AppDirectories.aiDiagnosticsDirectory.appendingPathComponent(songID.uuidString + suffix)
    }

    static func load(songID: UUID) -> PreparedGameplaySpeedCurve? {
        guard let data = try? Data(contentsOf: url(for: songID)) else { return nil }
        return try? JSONDecoder().decode(PreparedGameplaySpeedCurve.self, from: data)
    }

    static func save(_ curve: PreparedGameplaySpeedCurve) {
        guard let data = try? JSONEncoder().encode(curve) else { return }
        try? data.write(to: url(for: curve.songID), options: .atomic)
    }
}

enum PlayerRecommendationStore {
    private static var url: URL {
        AppDirectories.aiDiagnosticsDirectory.appendingPathComponent("player-recommendation.json")
    }

    static func load() -> PlayerRecommendation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PlayerRecommendation.self, from: data)
    }

    static func save(_ recommendation: PlayerRecommendation) {
        guard let data = try? JSONEncoder().encode(recommendation) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

#if os(iOS) && canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable(description: "A bounded speed-curve point for a rhythm-game chart.")
private struct FoundationModelGameplayPoint {
    var time: Double
    var intensity: Double
}

@available(iOS 26.0, *)
@Generable(description: "A concise, actionable rhythm-chart quality finding.")
private struct FoundationModelGameplayFinding {
    var category: String
    var severity: Double
    var sectionIndex: Int
    var explanation: String
    var suggestedCorrection: String
}

@available(iOS 26.0, *)
@Generable(description: "Structured pre-game rhythm-chart gameplay plan.")
private struct FoundationModelGameplayAnalysis {
    var points: [FoundationModelGameplayPoint]
    var findings: [FoundationModelGameplayFinding]
    var confidence: Double
    var recommendedDifficulty: String
    var recommendedHoldDensity: Double
    var recommendedChordDensity: Double
}

@available(iOS 26.0, *)
private enum FoundationModelsGameplayAnalyzer {
    static func analyze(context: GameplayAIContext) async -> FoundationModelGameplayAnalysis? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let encoded = (try? JSONEncoder().encode(context)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
        let prompt = """
        Analyze this compact, local rhythm-game context before gameplay begins.
        Return a structured gameplay plan, not prose. Points are visual intensity
        signals only: keep 4 to 12 ordered points, with times inside 0..duration
        and intensity from -1 to 1. Findings should identify real chart/hold/
        transition/pacing issues when supported by the data. Recommend a valid
        difficulty name only when the structure supports it, plus hold/chord
        density in 0..1. If a recommendation is not justified, use an empty
        difficulty string. Do not invent audio, player identity, or missing
        sections. Never change note timestamps, scoring, hit windows, hold
        timing, or input behavior.

        Context JSON:
        \(encoded)
        """
        do {
            let session = LanguageModelSession(
                instructions: "Use only the supplied bounded chart context. Return valid structured data.")
            let response = try await session.respond(to: prompt,
                                                      generating: FoundationModelGameplayAnalysis.self)
            return response.content
        } catch {
            return nil
        }
    }
}

@available(iOS 26.0, *)
@Generable(description: "A compact visual pacing analysis for a rhythm game chart.")
private struct FoundationModelSpeedPoint {
    var time: Double
    var intensity: Double
}

@available(iOS 26.0, *)
@Generable(description: "Structured rhythm chart pacing observations. Never change note timing or scoring.")
private struct FoundationModelSpeedAnalysis {
    var points: [FoundationModelSpeedPoint]
}

@available(iOS 26.0, *)
private enum FoundationModelsSpeedAnalyzer {
    static func analyze(chart: Chart, analysis: AudioAnalysis)
        async -> [DynamicSpeedProfile.SpeedCurvePoint]? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let duration = max(1, max(analysis.duration, chart.lastNoteTime + 1))
        let prompt = """
        Analyze this compact rhythm-chart summary and return a smooth visual pacing curve.
        Return only the structured result. Use 4 to 12 points from time 0 through \(String(format: "%.2f", duration)).
        Each intensity is between -1 and 1. Sparse intros and breakdowns are lower;
        dense choruses, drops, and finales are higher. Follow the supplied structure,
        avoid abrupt changes, and never propose note timestamps or scoring changes.

        \(makeSectionSummary(chart: chart, analysis: analysis, duration: duration))
        """
        do {
            let session = LanguageModelSession(
                instructions: "Analyze only the supplied chart structure. Do not invent audio, identity, or player data.")
            let response = try await session.respond(to: prompt,
                                                      generating: FoundationModelSpeedAnalysis.self)
            return response.content.points.map {
                DynamicSpeedProfile.SpeedCurvePoint(time: $0.time, intensity: $0.intensity)
            }
        } catch {
            return nil
        }
    }

    private static func makeSectionSummary(chart: Chart, analysis: AudioAnalysis,
                                           duration: Double) -> String {
        if analysis.sections.isEmpty {
            let count = min(12, max(4, Int((duration / 8).rounded())))
            let length = duration / Double(count)
            return (0..<count).map { index in
                let start = Double(index) * length
                let end = index == count - 1 ? duration : start + length
                let notes = chart.notes.filter { $0.time >= start && $0.time < end }.count
                return String(format: "%.2f-%.2f density=%d", start, end, notes)
            }.joined(separator: "\n")
        }
        return analysis.sections.prefix(24).map { section in
            let notes = chart.notes.filter { $0.time >= section.start && $0.time < section.end }.count
            let span = max(section.end - section.start, 0.25)
            return String(format: "%.2f-%.2f label=%@ energy=%.2f density=%.2f",
                          max(0, section.start), min(duration, section.end),
                          section.label.rawValue, section.energy, Double(notes) / span)
        }.joined(separator: "\n")
    }
}

@available(iOS 26.0, *)
@Generable(description: "A concise local rhythm-game recommendation based only on aggregate play history.")
private struct FoundationModelPlayerRecommendation {
    var summary: String
    var difficulty: String
    var dynamicSpeed: Bool
    var intensity: String
    var confidence: Double
}

@available(iOS 26.0, *)
private enum FoundationModelsPlayerAnalyzer {
    static func analyze(snapshot: StatsSnapshot, latestResult: GameplayResult)
        async -> PlayerRecommendation? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let prompt = """
        Give one concise, explainable rhythm-game recommendation from this aggregate local history.
        Do not mention AI, personal identity, or data collection. Recommend only a difficulty,
        whether Dynamic Speed should be on, and one intensity level: subtle, standard, or expressive.
        Never recommend changing scoring windows. Keep the summary under 240 characters.

        Latest result: difficulty=\(latestResult.difficulty.rawValue), accuracy=\(String(format: "%.3f", latestResult.accuracy)), combo=\(latestResult.maxCombo), misses=\(latestResult.missCount)
        History:
        \(summary(snapshot))
        """
        do {
            let session = LanguageModelSession(
                instructions: "Return a grounded recommendation using only the supplied aggregate history.")
            let response = try await session.respond(to: prompt,
                                                      generating: FoundationModelPlayerRecommendation.self)
            return GameplayIntelligenceValidation.playerRecommendation(
                summary: response.content.summary,
                difficulty: response.content.difficulty,
                dynamicSpeed: response.content.dynamicSpeed,
                intensity: response.content.intensity,
                confidence: response.content.confidence)
        } catch {
            return nil
        }
    }

    private static func summary(_ snapshot: StatsSnapshot) -> String {
        snapshot.stats.prefix(24).flatMap { song in
            song.perDifficulty.map {
                "difficulty=\($0.difficulty.rawValue) attempts=\($0.attempts) bestAccuracy=\(String(format: "%.3f", $0.bestAccuracy)) combo=\($0.highestCombo) misses=\($0.missCount)"
            }
        }.joined(separator: "\n")
    }
}
#else
private enum FoundationModelsGameplayAnalyzer {
    static func analyze(context: GameplayAIContext) async -> Never? {
        _ = context
        return nil
    }
}

private enum FoundationModelsSpeedAnalyzer {
    static func analyze(chart: Chart, analysis: AudioAnalysis)
        async -> [DynamicSpeedProfile.SpeedCurvePoint]? {
        _ = (chart, analysis)
        return nil
    }
}

private enum FoundationModelsPlayerAnalyzer {
    static func analyze(snapshot: StatsSnapshot, latestResult: GameplayResult)
        async -> PlayerRecommendation? {
        _ = (snapshot, latestResult)
        return nil
    }
}
#endif
