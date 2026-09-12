import XCTest
@testable import Music_Haptics

final class ChartGeneratorTests: XCTestCase {
    func testMetronomeProducesPlayableChart() async throws {
        let analysis = SignalFixtures.metronomeAnalysis(bpm: 120, seconds: 30)
        let generator = ChartGenerator()
        let output = try await generator.generate(
            analysis: analysis, songID: UUID(),
            request: ChartGenerator.Request(difficulty: .medium, densityMultiplier: 1.0, seed: 42))

        let notes = output.chart.notes
        XCTAssertGreaterThan(notes.count, 20, "chart should have a reasonable number of notes")
        XCTAssertLessThan(notes.count, 600, "chart must not be absurdly dense")

        // Hard spacing rule from the validator: consecutive notes within 0.1s
        // of a chord group's first note are chord voices (allowed); spacing
        // applies between chord groups.
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        var anchor = notes.first
        for note in notes.dropFirst() {
            if note.time - (anchor?.time ?? 0) < 0.1 { continue }   // chord voice
            XCTAssertGreaterThanOrEqual(note.time - (anchor?.time ?? 0),
                                        constraints.minSpacing - 0.001,
                                        "notes too close together")
            anchor = note
        }
        // Lane sanity.
        for note in notes {
            XCTAssertTrue((0..<4).contains(note.lane))
        }
        XCTAssertEqual(output.chart.chartVersion, ChartStorage.chartVersion)
    }

    func testGenerationIsDeterministic() async throws {
        let analysis = SignalFixtures.metronomeAnalysis(bpm: 100, seconds: 20)
        let request = ChartGenerator.Request(difficulty: .hard, densityMultiplier: 1.0, seed: 7)
        let a = try await ChartGenerator().generate(analysis: analysis, songID: UUID(), request: request)
        let b = try await ChartGenerator().generate(analysis: analysis, songID: UUID(), request: request)
        XCTAssertEqual(a.chart.notes, b.chart.notes, "same seed must produce the same chart")
    }

    func testDensityCapAcrossDifficulties() async throws {
        let analysis = SignalFixtures.metronomeAnalysis(bpm: 160, seconds: 60)
        let request = ChartGenerator.Request(difficulty: .extreme, densityMultiplier: 1.4, seed: 1)
        let output = try await ChartGenerator().generate(analysis: analysis, songID: UUID(), request: request)
        let nps = Double(output.chart.notes.count) / 60.0
        XCTAssertLessThan(nps, 12, "hard global cap on notes per second")
    }
}