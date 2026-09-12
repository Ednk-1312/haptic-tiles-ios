import CoreML
import XCTest
@testable import Music_Haptics

/// Evaluation of the REAL bundled Core ML models on held-out synthetic data.
///
/// These tests compile/load the actual `.mlmodel` files the app ships and
/// assert honest, measurable quality bounds (the training pipeline's held-out
/// numbers: difficulty MAE ≈ 0.03, events AUC ≈ 0.95). They also verify
/// inference determinism, throughput, and graceful fallback when the models
/// are missing.
final class AIModelEvaluationTests: XCTestCase {
    private var difficultyModelURL: URL {
        modelDir.appendingPathComponent("AIDifficulty.mlmodel")
    }
    private var eventModelURL: URL {
        modelDir.appendingPathComponent("AIEventRanking.mlmodel")
    }
    private var modelDir: URL {
        // The tests compile from TWO layouts: the LogicTests package
        // (LogicTests/Tests/MusicHapticsTests/…) and the iOS test target
        // (Music HapticsTests/…). Instead of a fixed relative hop, walk up
        // from the source file until "Music Haptics/AI/Models" is found.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Music Haptics/AI/Models")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return dir
    }

    private func engine() -> AIEngine {
        AIEngine(difficultyModelURL: difficultyModelURL, eventModelURL: eventModelURL)
    }

    // MARK: - Real model evaluation

    func testDifficultyModelAccuracyOnHeldOutSongs() async throws {
        // Held-out seed: different from the training seed (0x5EED_2026).
        let records = await TrainingDataSynthesis.generateRecords(seed: 0xE5A1_0001,
                                                                  songCount: 6,
                                                                  difficulties: [.easy, .medium, .hard, .extreme],
                                                                  densities: [1.0],
                                                                  maxEventsPerChart: 150)
        XCTAssertGreaterThanOrEqual(records.difficulty.count, 20)
        let engine = engine()
        var absErrors: [Double] = []
        var squaredErrors: [Double] = []
        var predicted: [Double] = []
        var actual: [Double] = []
        for record in records.difficulty {
            let result = await engine.predictDifficulty(features: record.features)
            let pred = try XCTUnwrap(result)
            XCTAssertTrue(pred >= 0 && pred <= 10, "prediction out of range: \(pred)")
            let err = abs(pred - record.labelScore)
            absErrors.append(err)
            squaredErrors.append(err * err)
            predicted.append(pred)
            actual.append(record.labelScore)
        }
        let mae = absErrors.reduce(0, +) / Double(absErrors.count)
        let rmse = (squaredErrors.reduce(0, +) / Double(squaredErrors.count)).squareRoot()
        let corr = pearson(actual, predicted)
        print("AI difficulty eval — MAE \(String(format: "%.4f", mae)), RMSE \(String(format: "%.4f", rmse)), corr \(String(format: "%.4f", corr))")
        // Bounds are comfortably looser than training-time metrics.
        XCTAssertLessThanOrEqual(mae, 0.15, "difficulty MAE too high")
        XCTAssertLessThanOrEqual(rmse, 0.25, "difficulty RMSE too high")
        XCTAssertGreaterThanOrEqual(corr, 0.97, "difficulty correlation too low")
    }

    func testEventModelAccuracyOnHeldOutSongs() async throws {
        let records = await TrainingDataSynthesis.generateRecords(seed: 0xE5A1_0001,
                                                                  songCount: 6,
                                                                  difficulties: [.easy, .medium, .hard, .extreme],
                                                                  densities: [1.0],
                                                                  maxEventsPerChart: 150)
        let engine = engine()
        let events = records.events
        XCTAssertGreaterThan(events.count, 1000)

        var positives: [Double] = []
        var negatives: [Double] = []
        var tp = 0, fp = 0, fn = 0, tn = 0
        var agreement = 0
        for record in events {
            let result = await engine.predictEventImportance(batch: [record.features])
            let pred = result?.first ?? -1
            let clamped = min(1, max(0, pred))
            let label = record.labelSelected == 1
            let decision = clamped >= 0.5
            if label { positives.append(clamped) } else { negatives.append(clamped) }
            if decision == label { agreement += 1 }
            if decision && label { tp += 1 } else if decision && !label { fp += 1 }
            else if !decision && label { fn += 1 } else { tn += 1 }
        }
        let auc = rankAUC(positives: positives, negatives: negatives)
        let precision = tp + fp > 0 ? Double(tp) / Double(tp + fp) : 0
        let recall = tp + fn > 0 ? Double(tp) / Double(tp + fn) : 0
        let agreementRate = Double(agreement) / Double(events.count)
        print("AI event eval — AUC \(String(format: "%.4f", auc)), P@0.5 \(String(format: "%.3f", precision)), R@0.5 \(String(format: "%.3f", recall)), agreement \(String(format: "%.3f", agreementRate))")
        XCTAssertGreaterThanOrEqual(auc, 0.85, "event AUC too low")
        XCTAssertGreaterThanOrEqual(agreementRate, 0.70, "agreement with deterministic selection too low")
        XCTAssertGreaterThanOrEqual(recall, 0.5)
    }

    // MARK: - Determinism + performance

    func testPredictionIsDeterministic() async throws {
        let engine = engine()
        let features = Array(repeating: 0.5, count: 16)
        let resultA = await engine.predictDifficulty(features: features)
        let resultB = await engine.predictDifficulty(features: features)
        let a = try XCTUnwrap(resultA)
        let b = try XCTUnwrap(resultB)
        XCTAssertEqual(a, b, accuracy: 1e-6)
    }

    func testInferenceThroughput() async throws {
        let engine = engine()
        let batch = (0..<1000).map { i in
            (0..<16).map { _ in Double((i * 7) % 100) / 100 }
        }
        let started = ContinuousClock.now
        let result = await engine.predictEventImportance(batch: batch)
        let scores = try XCTUnwrap(result)
        let elapsed = started.duration(to: .now)
        let ms = Double(elapsed.components.attoseconds) / 1e15
        XCTAssertEqual(scores.count, batch.count)
        let perPrediction = ms / Double(batch.count)
        print("AI inference — 1000 event predictions in \(String(format: "%.1f", ms)) ms (\(String(format: "%.3f", perPrediction)) ms/pred)")
        XCTAssertLessThan(ms, 3000, "inference too slow")
    }

    // MARK: - Fallback (no model / model failure)

    func testMissingModelFallsBackToDeterministic() async {
        let missing = AIEngine(difficultyModelURL: URL(fileURLWithPath: "/nonexistent/AIDifficulty.mlmodel"),
                               eventModelURL: URL(fileURLWithPath: "/nonexistent/AIEventRanking.mlmodel"))
        let difficultyAvailable = await missing.isDifficultyAvailable()
        let eventAvailable = await missing.isEventAvailable()
        XCTAssertFalse(difficultyAvailable)
        XCTAssertFalse(eventAvailable)
        let pred = await missing.predictDifficulty(features: Array(repeating: 0.5, count: 16))
        XCTAssertNil(pred)
        let events = await missing.predictEventImportance(batch: [Array(repeating: 0.5, count: 16)])
        XCTAssertNil(events)
    }

    @MainActor
    func testAISystemGracefulDegradation() async {
        // A system whose engine can't load must still produce the
        // deterministic difficulty and return nil event ranking.
        let system = AISystem(engine: AIEngine(difficultyModelURL: URL(fileURLWithPath: "/nope.mlmodel"),
                                               eventModelURL: URL(fileURLWithPath: "/nope2.mlmodel")))
        system.config = .default
        let analysis = SignalFixtures.metronomeAnalysis(bpm: 120, seconds: 20)
        let outcome = await system.difficultyOutcome(songID: UUID(), notes: [], metrics: sampleMetrics(),
                                                     analysis: analysis)
        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome?.finalScore, outcome?.deterministicScore)
        XCTAssertFalse(outcome?.usedAI ?? true)
        let ranking = await system.eventImportance(songID: UUID(), events: analysis.events, analysis: analysis)
        XCTAssertNil(ranking)
    }

    // MARK: - Helpers

    private func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var num = 0.0, dx = 0.0, dy = 0.0
        for (a, b) in zip(x, y) {
            num += (a - mx) * (b - my)
            dx += (a - mx) * (a - mx)
            dy += (b - my) * (b - my)
        }
        guard dx > 0, dy > 0 else { return 0 }
        return num / (dx.squareRoot() * dy.squareRoot())
    }

    /// Rank-based AUC (Mann–Whitney U), no external dependencies.
    private func rankAUC(positives: [Double], negatives: [Double]) -> Double {
        guard !positives.isEmpty, !negatives.isEmpty else { return 0.5 }
        var pairs = 0.0, wins = 0.0
        for p in positives {
            for n in negatives {
                pairs += 1
                if p > n { wins += 1 } else if p == n { wins += 0.5 }
            }
        }
        return wins / pairs
    }

    private func sampleMetrics() -> DifficultyMetrics {
        DifficultyMetrics(score10: 5, label: .medium, notesPerSecond: 3, averageInterval: 0.33,
                          maxBurstNPS: 5, simultaneityRatio: 0.1, averageJumpDistance: 1.2,
                          alternationRatio: 0.4, intervalStdDev: 0.12, spikeRatio: 1.8, sustainedNPS: 2.5)
    }
}