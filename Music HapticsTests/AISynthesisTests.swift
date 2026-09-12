import XCTest
@testable import Music_Haptics

/// Training-data synthesis must be deterministic and must produce labels that
/// actually reflect the deterministic pipeline (both classes present, charts
/// playable).
final class AISynthesisTests: XCTestCase {
    func testSynthesisIsDeterministic() {
        let a = TrainingDataSynthesis.synthesizeAnalysis(seed: 1234)
        let b = TrainingDataSynthesis.synthesizeAnalysis(seed: 1234)
        XCTAssertEqual(a.beats.count, b.beats.count)
        XCTAssertEqual(a.events.count, b.events.count)
        XCTAssertEqual(a.events.first?.time, b.events.first?.time)
        XCTAssertEqual(a.sections.count, b.sections.count)
        XCTAssertEqual(a.tempoBPM, b.tempoBPM)
        // Different seeds → different material.
        let c = TrainingDataSynthesis.synthesizeAnalysis(seed: 9999)
        XCTAssertNotEqual(a.events.count, c.events.count)
    }

    func testSynthesisProducesMusicallyVariedMaterial() {
        var bpms: Set<Double> = []
        var durations: [Double] = []
        var labelSet: Set<SectionLabel> = []
        for seed in 0..<24 {
            let analysis = TrainingDataSynthesis.synthesizeAnalysis(seed: UInt64(seed * 7919 + 1))
            if let bpm = analysis.tempoBPM { bpms.insert(bpm) }
            durations.append(analysis.duration)
            for section in analysis.sections { labelSet.insert(section.label) }
        }
        XCTAssertGreaterThanOrEqual(bpms.count, 15, "BPM variety across seeds")
        XCTAssertGreaterThanOrEqual(labelSet.count, 3, "section label variety")
        XCTAssertGreaterThan(durations.max() ?? 0, durations.min() ?? 0)
    }

    func testGeneratedChartsArePlayableAndLabeled() async {
        let records = await TrainingDataSynthesis.generateRecords(seed: 0xABC, songCount: 3,
                                                                  difficulties: [.easy, .hard],
                                                                  densities: [1.0],
                                                                  maxEventsPerChart: 60)
        XCTAssertEqual(records.difficulty.count, 6)   // 3 songs × 2 difficulties
        XCTAssertFalse(records.events.isEmpty)

        // Difficulty labels spread across levels.
        let levels = Set(records.difficulty.map(\.labelLevel))
        XCTAssertGreaterThanOrEqual(levels.count, 2)

        // Both label classes present for events (selected + skipped).
        let selected = records.events.filter { $0.labelSelected == 1 }.count
        let skipped = records.events.filter { $0.labelSelected == 0 }.count
        XCTAssertGreaterThan(selected, 0)
        XCTAssertGreaterThan(skipped, 0)
        let ratio = Double(selected) / Double(records.events.count)
        XCTAssertTrue(ratio > 0.05 && ratio < 0.95, "label balance off: \(ratio)")
    }

    func testRecordDeterminism() async {
        let a = await TrainingDataSynthesis.generateRecords(seed: 77, songCount: 2,
                                                            difficulties: [.medium],
                                                            densities: [1.0],
                                                            maxEventsPerChart: 40)
        let b = await TrainingDataSynthesis.generateRecords(seed: 77, songCount: 2,
                                                            difficulties: [.medium],
                                                            densities: [1.0],
                                                            maxEventsPerChart: 40)
        XCTAssertEqual(a.difficulty.count, b.difficulty.count)
        XCTAssertEqual(a.events.count, b.events.count)
        for (x, y) in zip(a.difficulty, b.difficulty) {
            XCTAssertEqual(x.features, y.features)
            XCTAssertEqual(x.labelScore, y.labelScore)
        }
        for (x, y) in zip(a.events.prefix(20), b.events.prefix(20)) {
            XCTAssertEqual(x.features, y.features)
            XCTAssertEqual(x.labelSelected, y.labelSelected)
        }
    }

    func testFeatureSchemaStability() {
        // The model manifest (written by training) must match the code schema.
        XCTAssertEqual(AIModelCatalog.difficultyFeatureCount, 16)
        XCTAssertEqual(AIModelCatalog.eventFeatureCount, 16)
        XCTAssertEqual(AIModelCatalog.featureSchemaVersion, 1)
        XCTAssertEqual(AIModelCatalog.difficultyModelVersion, 1)
        XCTAssertEqual(AIModelCatalog.eventModelVersion, 1)
    }
}