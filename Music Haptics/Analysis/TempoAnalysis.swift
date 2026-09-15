@preconcurrency import CoreML
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which tempo-analysis path produced a result. The value is persisted with the
/// analysis so diagnostics can distinguish a real model result from a fallback.
enum TempoAnalyzerKind: String, Codable, Sendable, Equatable {
    case dsp
    case intelligentHeuristic
    case intelligentCoreML

    var displayName: String {
        switch self {
        case .dsp: return "DSP / Standard Math"
        case .intelligentHeuristic: return "Enhanced on-device heuristic"
        case .intelligentCoreML: return "Enhanced Core ML"
        }
    }
}

/// Compact signal input shared by both analyzers. The full waveform is never
/// passed to the intelligent tier; only the already-computed analysis envelope
/// is used. This keeps the work bounded and makes the boundary testable.
struct TempoAnalysisInput: Sendable {
    let flux: [Float]
    let hopTime: Double
}

/// Result of one pre-game tempo analysis. `bpm` is the only value consumed by
/// the existing beat/chart pipeline; the remaining fields are diagnostics and
/// cache metadata. No field is consulted by the frame loop or scoring engine.
struct TempoAnalysisResult: Codable, Sendable, Equatable {
    static let analyzerVersion = 1

    let bpm: Double
    let confidence: Double
    let stability: Double
    let halfDoubleAmbiguity: Double
    let tempoChangeDetected: Bool
    let analyzer: TempoAnalyzerKind
    let analyzerVersion: Int
    let analysisDuration: Double
    let inferenceDuration: Double?
    let fallbackReason: String?
    var cacheHit: Bool

    static func invalid(kind: TempoAnalyzerKind = .dsp,
                        reason: String? = nil) -> TempoAnalysisResult {
        TempoAnalysisResult(bpm: 0, confidence: 0, stability: 0,
                            halfDoubleAmbiguity: 0, tempoChangeDetected: false,
                            analyzer: kind, analyzerVersion: analyzerVersion,
                            analysisDuration: 0, inferenceDuration: nil,
                            fallbackReason: reason, cacheHit: false)
    }
}

protocol TempoAnalyzer: Sendable {
    var kind: TempoAnalyzerKind { get }
    func analyze(_ input: TempoAnalysisInput) async throws -> TempoAnalysisResult
}

/// Actual OS capability used for tier selection. The app does not infer support
/// from a marketing device name: Foundation Models' live availability is the
/// gate, and Core ML is treated as the optional execution backend.
struct TempoAnalyzerDeviceCapabilities: Sendable, Equatable {
    let foundationModelsAvailable: Bool
    let coreMLAvailable: Bool
    /// A validated, app-bundled tempo model is a separate requirement from
    /// Core ML framework support. The current app intentionally ships no
    /// unvalidated tempo model, so the live app remains on DSP until one is
    /// added and evaluated.
    let tempoModelAvailable: Bool

    init(foundationModelsAvailable: Bool,
         coreMLAvailable: Bool,
         tempoModelAvailable: Bool = false) {
        self.foundationModelsAvailable = foundationModelsAvailable
        self.coreMLAvailable = coreMLAvailable
        self.tempoModelAvailable = tempoModelAvailable
    }

    var supportsIntelligentTempoAnalysis: Bool {
        foundationModelsAvailable && coreMLAvailable && tempoModelAvailable
    }

    static func current() -> TempoAnalyzerDeviceCapabilities {
        #if os(iOS) && canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let foundationAvailable: Bool
            switch SystemLanguageModel.default.availability {
            case .available:
                foundationAvailable = true
            case .unavailable:
                foundationAvailable = false
            }
            let tempoModelAvailable = Bundle.main.url(forResource: "AITempo",
                                                       withExtension: "mlmodelc") != nil
            return TempoAnalyzerDeviceCapabilities(
                foundationModelsAvailable: foundationAvailable,
                coreMLAvailable: true,
                tempoModelAvailable: tempoModelAvailable)
        }
        #endif
        return TempoAnalyzerDeviceCapabilities(foundationModelsAvailable: false,
                                               coreMLAvailable: false,
                                               tempoModelAvailable: false)
    }
}

enum TempoAnalyzerFactory {
    static func make(enabled: Bool = true,
                     capabilities: TempoAnalyzerDeviceCapabilities = .current(),
                     modelScorer: (any TempoMLScorer)? = nil) -> any TempoAnalyzer {
        guard enabled, capabilities.supportsIntelligentTempoAnalysis else {
            return DSPTempoAnalyzer()
        }
        return IntelligentTempoAnalyzer(modelScorer: modelScorer ?? CoreMLTempoScorer())
    }
}

/// Standard fallback used on every device when Foundation Models are not
/// actually available, and also whenever enhanced analysis is unreliable.
struct DSPTempoAnalyzer: TempoAnalyzer {
    let kind: TempoAnalyzerKind = .dsp

    func analyze(_ input: TempoAnalysisInput) async throws -> TempoAnalysisResult {
        let started = Date()
        let global = TempoEstimator.estimate(flux: input.flux, hopTime: input.hopTime)
        let windows = TempoAnalysisMath.windowEstimates(flux: input.flux, hopTime: input.hopTime)
        let summary = TempoAnalysisMath.summarize(global: global, windows: windows,
                                                  flux: input.flux, hopTime: input.hopTime)
        return TempoAnalysisResult(
            bpm: summary.bpm,
            confidence: summary.confidence,
            stability: summary.stability,
            halfDoubleAmbiguity: summary.ambiguity,
            tempoChangeDetected: summary.tempoChangeDetected,
            analyzer: .dsp,
            analyzerVersion: TempoAnalysisResult.analyzerVersion,
            analysisDuration: Date().timeIntervalSince(started),
            inferenceDuration: nil,
            fallbackReason: nil,
            cacheHit: false)
    }
}

/// A small interface around a purpose-built tempo Core ML model. Keeping this
/// contract separate means the app can ship the model only after it has been
/// validated; there is no fabricated inference when the model is absent.
protocol TempoMLScorer: Sendable {
    func predict(features: [[Double]]) async -> TempoMLPrediction?
}

struct TempoMLPrediction: Sendable, Equatable {
    let scores: [Double]
    let confidence: Double
    let inferenceDuration: Double
}

/// Enhanced path. It first computes the same reliable DSP baseline, then lets
/// an optional validated model rank half/normal/double-time candidates. If the
/// model is missing, fails, disagrees with the stable signal, or reports low
/// confidence, the DSP result is returned unchanged except for an explicit
/// fallback reason. This is never part of gameplay timing.
struct IntelligentTempoAnalyzer: TempoAnalyzer {
    let kind: TempoAnalyzerKind = .intelligentHeuristic
    private let modelScorer: any TempoMLScorer
    private let dsp = DSPTempoAnalyzer()

    init(modelScorer: any TempoMLScorer = CoreMLTempoScorer()) {
        self.modelScorer = modelScorer
    }

    func analyze(_ input: TempoAnalysisInput) async throws -> TempoAnalysisResult {
        let baseline = try await dsp.analyze(input)
        guard baseline.bpm > 0 else { return baseline }

        let candidates = TempoAnalysisMath.tempoCandidates(around: baseline.bpm)
        let features = candidates.map {
            TempoAnalysisMath.modelFeatures(candidateBPM: $0, baseline: baseline,
                                            flux: input.flux, hopTime: input.hopTime)
        }
        let prediction = await modelScorer.predict(features: features)
        guard let prediction,
              prediction.scores.count == candidates.count,
              prediction.scores.allSatisfy({ $0.isFinite }),
              prediction.confidence >= 0.50 else {
            return TempoAnalysisResult(
                bpm: baseline.bpm,
                confidence: baseline.confidence,
                stability: baseline.stability,
                halfDoubleAmbiguity: baseline.halfDoubleAmbiguity,
                tempoChangeDetected: baseline.tempoChangeDetected,
                analyzer: .intelligentHeuristic,
                analyzerVersion: TempoAnalysisResult.analyzerVersion,
                analysisDuration: baseline.analysisDuration,
                inferenceDuration: prediction?.inferenceDuration,
                fallbackReason: "Core ML tempo model unavailable or low confidence",
                cacheHit: false)
        }

        guard let winner = prediction.scores.indices.max(by: {
            prediction.scores[$0] < prediction.scores[$1]
        }) else { return baseline }
        let sortedScores = prediction.scores.sorted(by: >)
        let margin = sortedScores.count > 1 ? sortedScores[0] - sortedScores[1] : 1
        guard margin >= 0.08 else {
            return TempoAnalysisResult(
                bpm: baseline.bpm,
                confidence: baseline.confidence,
                stability: baseline.stability,
                halfDoubleAmbiguity: baseline.halfDoubleAmbiguity,
                tempoChangeDetected: baseline.tempoChangeDetected,
                analyzer: .intelligentCoreML,
                analyzerVersion: TempoAnalysisResult.analyzerVersion,
                analysisDuration: baseline.analysisDuration,
                inferenceDuration: prediction.inferenceDuration,
                fallbackReason: "Core ML candidates were ambiguous",
                cacheHit: false)
        }

        let chosenBPM = candidates[winner]
        let confidence = min(1, max(baseline.confidence,
                                    baseline.confidence * 0.75 + prediction.confidence * 0.25))
        return TempoAnalysisResult(
            bpm: chosenBPM,
            confidence: confidence,
            stability: baseline.stability,
            halfDoubleAmbiguity: baseline.halfDoubleAmbiguity,
            tempoChangeDetected: baseline.tempoChangeDetected,
            analyzer: .intelligentCoreML,
            analyzerVersion: TempoAnalysisResult.analyzerVersion,
            analysisDuration: baseline.analysisDuration,
            inferenceDuration: prediction.inferenceDuration,
            fallbackReason: nil,
            cacheHit: false)
    }
}

/// Pure tempo math used by both tiers and tests.
enum TempoAnalysisMath {
    struct WindowEstimate: Sendable, Equatable {
        let bpm: Double
        let confidence: Double
    }

    struct Summary: Sendable, Equatable {
        let bpm: Double
        let confidence: Double
        let stability: Double
        let ambiguity: Double
        let tempoChangeDetected: Bool
    }

    static func windowEstimates(flux: [Float], hopTime: Double) -> [WindowEstimate] {
        guard flux.count > 96, hopTime > 0 else { return [] }
        let windowDuration = min(16.0, max(6.0, Double(flux.count) * hopTime / 4.0))
        let windowCount = min(6, max(2, Int((Double(flux.count) * hopTime / windowDuration).rounded(.down))))
        guard windowCount >= 2 else { return [] }
        let windowLength = max(17, Int(windowDuration / hopTime))
        var result: [WindowEstimate] = []
        result.reserveCapacity(windowCount)
        for index in 0..<windowCount {
            let start = min(max(0, flux.count - windowLength),
                            Int(Double(index) / Double(windowCount) * Double(flux.count - windowLength)))
            let end = min(flux.count, start + windowLength)
            guard end - start >= 17 else { continue }
            let estimate = TempoEstimator.estimate(flux: Array(flux[start..<end]), hopTime: hopTime)
            if estimate.bpm > 0 {
                result.append(WindowEstimate(bpm: estimate.bpm, confidence: estimate.confidence))
            }
        }
        return result
    }

    static func summarize(global: TempoEstimate, windows: [WindowEstimate],
                          flux: [Float], hopTime: Double) -> Summary {
        guard global.bpm > 0 else {
            return Summary(bpm: 0, confidence: 0, stability: 0,
                           ambiguity: 0, tempoChangeDetected: false)
        }
        let reliable = windows.filter { $0.confidence >= 0.10 && $0.bpm > 0 }
        let sortedWindows = reliable.map(\.bpm).sorted()
        let medianWindow: Double
        if sortedWindows.isEmpty {
            medianWindow = global.bpm
        } else if sortedWindows.count.isMultiple(of: 2) {
            let upper = sortedWindows.count / 2
            medianWindow = (sortedWindows[upper - 1] + sortedWindows[upper]) / 2
        } else {
            medianWindow = sortedWindows[sortedWindows.count / 2]
        }
        let changes = reliable.contains { abs($0.bpm - global.bpm) / global.bpm > 0.08 }
        let mean = reliable.isEmpty ? global.bpm : reliable.map(\.bpm).reduce(0, +) / Double(reliable.count)
        let variance = reliable.isEmpty ? 0 : reliable.map { pow($0.bpm - mean, 2) }.reduce(0, +) / Double(reliable.count)
        let coefficient = mean > 0 ? sqrt(variance) / mean : 1
        let stability = min(1, max(0, 1 - coefficient * 4))
        let ambiguity = ambiguityScore(bpm: global.bpm, flux: flux, hopTime: hopTime)
        let chosen = changes ? global.bpm : medianWindow
        let confidence = min(1, max(0, global.confidence * (0.70 + 0.30 * stability)))
        return Summary(bpm: chosen, confidence: confidence, stability: stability,
                       ambiguity: ambiguity, tempoChangeDetected: changes)
    }

    static func tempoCandidates(around bpm: Double) -> [Double] {
        guard bpm.isFinite, bpm > 0 else { return [] }
        let raw = [bpm / 2, bpm, bpm * 2]
        return raw.map { min(220, max(40, $0)) }
            .filter { $0.isFinite }
            .reduce(into: [Double]()) { result, value in
                if !result.contains(where: { abs($0 - value) < 0.001 }) { result.append(value) }
            }
    }

    static func modelFeatures(candidateBPM: Double, baseline: TempoAnalysisResult,
                              flux: [Float], hopTime: Double) -> [Double] {
        let primary = periodicity(bpm: baseline.bpm, flux: flux, hopTime: hopTime)
        let candidate = periodicity(bpm: candidateBPM, flux: flux, hopTime: hopTime)
        return [
            min(1, max(0, (candidateBPM - 40) / 180)),
            min(1, max(0, candidate)),
            min(1, max(0, primary)),
            min(1, max(0, baseline.confidence)),
            min(1, max(0, baseline.stability)),
            min(1, max(0, baseline.halfDoubleAmbiguity)),
            baseline.tempoChangeDetected ? 1 : 0,
            candidateBPM < baseline.bpm ? 1 : 0,
            candidateBPM > baseline.bpm ? 1 : 0,
            min(1, max(0, abs(candidateBPM - baseline.bpm) / 120)),
            min(1, max(0, Double(flux.count) * hopTime / 60)),
            min(1, max(0, hopTime * 100))
        ]
    }

    static func normalizedBPM(_ bpm: Double) -> Double {
        guard bpm.isFinite, bpm > 0 else { return 0 }
        let candidates = [bpm / 2, bpm, bpm * 2].filter { (40...220).contains($0) }
        guard let musical = candidates.first(where: { (80...190).contains($0) }) else {
            return min(220, max(40, bpm))
        }
        return musical
    }

    static func periodicity(bpm: Double, flux: [Float], hopTime: Double) -> Double {
        guard bpm > 0, hopTime > 0, flux.count > 8 else { return 0 }
        let lag = Int((60 / bpm / hopTime).rounded())
        guard lag > 0, lag < flux.count - 1 else { return 0 }
        let values = flux.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        let centered = values.map { $0 - mean }
        let denominator = centered.map { $0 * $0 }.reduce(0, +)
        guard denominator > 1e-12 else { return 0 }
        let numerator = zip(centered, centered.dropFirst(lag))
            .map { $0 * $1 }.reduce(0, +)
        return min(1, max(0, numerator / denominator))
    }

    static func ambiguityScore(bpm: Double, flux: [Float], hopTime: Double) -> Double {
        guard bpm > 0 else { return 0 }
        let primary = periodicity(bpm: bpm, flux: flux, hopTime: hopTime)
        let half = periodicity(bpm: bpm / 2, flux: flux, hopTime: hopTime)
        let double = periodicity(bpm: bpm * 2, flux: flux, hopTime: hopTime)
        return min(1, max(0, max(half, double) - primary))
    }
}

/// A tiny Core ML adapter. The app intentionally ships without an unvalidated
/// tempo model today; when `AITempo.mlmodel` is added, its contract is exactly
/// 12 Float features in `features` and one scalar `prediction` per candidate.
/// Missing/invalid models return nil and never affect playback.
actor CoreMLTempoScorer: TempoMLScorer {
    private let modelURL: URL?
    private var model: MLModel?

    init(modelURL: URL? = nil) {
        self.modelURL = modelURL ?? Bundle.main.url(forResource: "AITempo", withExtension: "mlmodelc")
    }

    func predict(features: [[Double]]) async -> TempoMLPrediction? {
        guard !features.isEmpty, let url = modelURL else { return nil }
        do {
            if model == nil {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .all
                model = try await MLModel.load(contentsOf: url, configuration: configuration)
            }
            guard let model else { return nil }
            let started = ContinuousClock.now
            var scores: [Double] = []
            scores.reserveCapacity(features.count)
            for row in features {
                guard row.count == 12 else { return nil }
                var shaped = MLShapedArray<Float>(repeating: 0, shape: [12])
                for (index, value) in row.enumerated() {
                    shaped[scalarAt: index] = Float(value)
                }
                let provider = try MLDictionaryFeatureProvider(dictionary: [
                    "features": MLFeatureValue(multiArray: MLMultiArray(shaped))
                ])
                let output = try await model.prediction(from: provider)
                guard let value = output.featureValue(for: "prediction") else { return nil }
                if let shaped = value.shapedArrayValue(of: Float.self), let scalar = shaped.scalars.first {
                    scores.append(Double(scalar))
                } else if let multi = value.multiArrayValue {
                    scores.append(Double(truncating: multi[0]))
                } else {
                    scores.append(value.doubleValue)
                }
            }
            let elapsed = started.duration(to: .now)
            let milliseconds = Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15
            let finiteScores = scores.map { min(1, max(0, $0.isFinite ? $0 : 0)) }
            let sorted = finiteScores.sorted(by: >)
            let confidence = sorted.count > 1 ? min(1, max(0, sorted[0] - sorted[1] + 0.5)) : 1
            return TempoMLPrediction(scores: finiteScores, confidence: confidence,
                                     inferenceDuration: milliseconds)
        } catch {
            model = nil
            return nil
        }
    }
}

/// On-device JSON cache for tempo-only results. The key includes the source
/// identity plus a compact content fingerprint, so replacing an imported file
/// cannot reuse another file's BPM. Analyzer-version changes invalidate entries.
enum TempoAnalysisCache {
    private struct Entry: Codable {
        let version: Int
        let key: String
        let result: TempoAnalysisResult
    }

    static func key(url: URL, sampleRate: Double, duration: Double, flux: [Float],
                    analyzerKind: TempoAnalyzerKind = .dsp) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let identity = "\(url.absoluteString)|\(sampleRate)|\(duration)|\(flux.count)|\(analyzerKind.rawValue)|v\(TempoAnalysisResult.analyzerVersion)"
        for byte in identity.utf8 { hash ^= UInt64(byte); hash &*= 0x0000_0100_0000_01B3 }
        for value in flux where value.isFinite {
            var bits = value.bitPattern
            withUnsafeBytes(of: &bits) { bytes in
                for byte in bytes { hash ^= UInt64(byte); hash &*= 0x0000_0100_0000_01B3 }
            }
        }
        return String(format: "%016llx", hash)
    }

    static func load(key: String) -> TempoAnalysisResult? {
        let url = cacheURL(key: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == TempoAnalysisResult.analyzerVersion,
              entry.key == key,
              entry.result.analyzerVersion == TempoAnalysisResult.analyzerVersion else {
            return nil
        }
        var result = entry.result
        result.cacheHit = true
        return result
    }

    static func save(_ result: TempoAnalysisResult, key: String) {
        var stored = result
        stored.cacheHit = false
        let entry = Entry(version: TempoAnalysisResult.analyzerVersion, key: key, result: stored)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: cacheURL(key: key), options: .atomic)
    }

    static func cacheURLForTesting(key: String) -> URL { cacheURL(key: key) }

    private static func cacheURL(key: String) -> URL {
        AppDirectories.analysisDirectory.appendingPathComponent("tempo-\(key).json")
    }
}
