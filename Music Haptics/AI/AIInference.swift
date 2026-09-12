@preconcurrency import CoreML
import Foundation

/// Defensive validation failure — the engine never traps; callers fall back
/// to the deterministic system.
enum AIInferenceError: LocalizedError {
    case featureCountMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .featureCountMismatch(let expected, let actual):
            return "feature vector has \(actual) values, expected \(expected)"
        }
    }
}

/// On-device Core ML inference for the two bundled models.
///
/// Framework choice (documented): **Core ML**, not Core AI.
/// - Core AI (iOS 26+) targets Apple-Intelligence-grade features and is gated
///   on specific hardware; these models are tiny numeric regressors (16
///   float features → 1 output) that run on every supported iPhone and in the
///   simulator.
/// - Core ML executes them as compiled programs with no network and
///   deterministic output, and `MLModel.compileModel` also lets the unit
///   tests load the exact shipped `.mlpackage` on macOS.
///
/// The engine is an actor so model loading and prediction never run on the
/// main thread. Every failure (missing file, load error, prediction throw)
/// returns `nil` — the caller falls back to the deterministic system; the game
/// never depends on AI availability.
actor AIEngine {
    private let difficultyModelURL: URL?
    private let eventModelURL: URL?
    private let patternModelURL: URL?

    private var difficultyModel: MLModel?
    private var eventModel: MLModel?
    private var patternModel: MLModel?
    private var lastLoadError: String?
    private var lastInferenceMs: Double?

    init(difficultyModelURL: URL? = nil, eventModelURL: URL? = nil, patternModelURL: URL? = nil) {
        self.difficultyModelURL = difficultyModelURL ?? Self.bundledModelURL(name: AIModelCatalog.difficultyModelFileName)
        self.eventModelURL = eventModelURL ?? Self.bundledModelURL(name: AIModelCatalog.eventModelFileName)
        self.patternModelURL = patternModelURL ?? Self.bundledModelURL(name: AIModelCatalog.patternModelFileName)
    }

    /// Looks for the Xcode-compiled `.mlmodelc` inside the app bundle.
    static func bundledModelURL(name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mlmodelc")
    }

    // MARK: - Availability

    func isDifficultyAvailable() async -> Bool {
        await loadDifficulty() != nil
    }

    func isEventAvailable() async -> Bool {
        await loadEvent() != nil
    }

    func isPatternAvailable() async -> Bool {
        await loadPattern() != nil
    }

    func lastError() -> String? { lastLoadError }

    /// Measured inference time of the most recent prediction call (ms).
    func lastPredictionTimeMs() -> Double? { lastInferenceMs }

    // MARK: - Prediction

    /// Raw AI difficulty score (0…10), or nil when the model is unavailable.
    func predictDifficulty(features: [Double]) async -> Double? {
        guard let model = await loadDifficulty() else { return nil }
        let started = ContinuousClock.now
        do {
            let provider = try makeProvider(features: features, count: AIModelCatalog.difficultyFeatureCount)
            let output = try await model.prediction(from: provider, options: MLPredictionOptions())
            lastInferenceMs = Self.elapsedMs(from: started)
            return Self.scalarOutput(from: output)
        } catch {
            lastLoadError = "prediction failed: \(error)"
            return nil
        }
    }

    /// Raw AI importance scores (0…1) for a batch of candidate events, in the
    /// same order as `batch`. nil when the model is unavailable. (Batch
    /// prediction is iOS-only in the current SDK; per-row prediction is
    /// universal and equally deterministic.)
    func predictEventImportance(batch: [[Double]]) async -> [Double]? {
        guard !batch.isEmpty, let model = await loadEvent() else { return nil }
        let started = ContinuousClock.now
        do {
            var scores: [Double] = []
            scores.reserveCapacity(batch.count)
            for features in batch {
                let provider = try makeProvider(features: features, count: AIModelCatalog.eventFeatureCount)
                let output = try await model.prediction(from: provider, options: MLPredictionOptions())
                scores.append(Self.scalarOutput(from: output) ?? 0)
            }
            lastInferenceMs = Self.elapsedMs(from: started)
            return scores
        } catch {
            lastLoadError = "batch prediction failed: \(error)"
            return nil
        }
    }

    /// Raw AI scores (0…1) for a batch of candidate patterns, in the same
    /// order as `batch` (phrase-major, candidates contiguous per phrase).
    /// nil when the model is unavailable.
    func predictPatternScores(batch: [[Double]]) async -> [Double]? {
        guard !batch.isEmpty, let model = await loadPattern() else { return nil }
        let started = ContinuousClock.now
        do {
            var scores: [Double] = []
            scores.reserveCapacity(batch.count)
            for features in batch {
                let provider = try makeProvider(features: features, count: AIModelCatalog.patternFeatureCount)
                let output = try await model.prediction(from: provider, options: MLPredictionOptions())
                scores.append(Self.scalarOutput(from: output) ?? 0)
            }
            lastInferenceMs = Self.elapsedMs(from: started)
            return scores
        } catch {
            lastLoadError = "pattern batch prediction failed: \(error)"
            return nil
        }
    }

    // MARK: - Internals

    private func loadDifficulty() async -> MLModel? {
        if let difficultyModel { return difficultyModel }
        guard let url = difficultyModelURL else {
            lastLoadError = "difficulty model not bundled"
            return nil
        }
        if let model = await loadModel(at: url) {
            difficultyModel = model
            return model
        }
        return nil
    }

    private func loadEvent() async -> MLModel? {
        if let eventModel { return eventModel }
        guard let url = eventModelURL else {
            lastLoadError = "event model not bundled"
            return nil
        }
        if let model = await loadModel(at: url) {
            eventModel = model
            return model
        }
        return nil
    }

    private func loadPattern() async -> MLModel? {
        if let patternModel { return patternModel }
        guard let url = patternModelURL else {
            lastLoadError = "pattern model not bundled"
            return nil
        }
        if let model = await loadModel(at: url) {
            patternModel = model
            return model
        }
        return nil
    }

    /// Loads a compiled model. If the URL is a raw `.mlmodel` (tests, dev
    /// workflows), compiles it on the fly first — the system caches compiled
    /// models, so this only costs the first call.
    private func loadModel(at url: URL) async -> MLModel? {
        do {
            return try await MLModel.load(contentsOf: url)
        } catch {
            if let compiled = try? await MLModel.compileModel(at: url) {
                do {
                    return try await MLModel.load(contentsOf: compiled)
                } catch {
                    lastLoadError = "load failed: \(error)"
                    return nil
                }
            }
            lastLoadError = "load failed: \(error)"
            return nil
        }
    }

    private func makeProvider(features: [Double], count: Int) throws -> MLDictionaryFeatureProvider {
        guard features.count == count else {
            throw AIInferenceError.featureCountMismatch(expected: count, actual: features.count)
        }
        // Classic spec models expect a multi-array input; build one from a
        // shaped array (the modern allocation API).
        var shaped = MLShapedArray<Float>(repeating: 0, shape: [count])
        for (i, value) in features.enumerated() {
            shaped[scalarAt: i] = Float(value)
        }
        let multi = MLMultiArray(shaped)
        let dict = ["features": MLFeatureValue(multiArray: multi)]
        return try MLDictionaryFeatureProvider(dictionary: dict)
    }

    /// Reads the regressor output ("prediction" — coremltools sklearn
    /// conversion) whether it comes back as a shaped array, a multi-array or a
    /// scalar double.
    private static func scalarOutput(from provider: MLFeatureProvider) -> Double? {
        guard let value = provider.featureValue(for: "prediction") else { return nil }
        if let shaped = value.shapedArrayValue(of: Float.self), !shaped.scalars.isEmpty {
            return Double(shaped.scalars[0])
        }
        if let multi = value.multiArrayValue {
            return Double(truncating: multi[0])
        }
        return value.doubleValue
    }

    private static func elapsedMs(from start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.attoseconds) / 1e15  // attoseconds → ms
    }
}

// Core ML's model and feature-provider types are documented thread-safe but
// not annotated Sendable in the SDK. The AIEngine actor fully serializes all
// access, so the unchecked conformances are sound.
extension MLModel: @unchecked @retroactive Sendable {}
extension MLDictionaryFeatureProvider: @unchecked @retroactive Sendable {}