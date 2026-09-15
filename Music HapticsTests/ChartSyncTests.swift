import XCTest
@testable import Music_Haptics

/// Chart sync (Magic Tiles 3 behavior): tiles must land where the music
/// actually sounds. Two contract changes pin this —
///   1. Grid snapping prefers the highest-onset-support tick, breaking
///      near-ties toward the slot time (not a louder distant neighbor).
///   2. Real audio support always outranks the beat baseline, so estimated
///      (possibly drifted) beats never beat audible hits.
final class ChartSyncTests: XCTestCase {

    /// Events fixture: one audible hit per second, strong.
    private static func events(at times: [Double]) -> [MusicalEvent] {
        times.map { MusicalEvent(time: $0, strength: 0.9, confidence: 0.9,
                                 type: .kickLike, lowEnergy: 0.6, midEnergy: 0.5, highEnergy: 0.2,
                                 isOnBeat: true, beatStrength: 0.8, sectionIndex: 0, importance: 0.9) }
    }

    func testGeneratorVersionBumpedForOnsetFirstPlacement() {
        XCTAssertEqual(ChartStorage.chartVersion, ChartGenerator.currentVersion)
        XCTAssertEqual(ChartGenerator.currentVersion, 6,
                       "generator and storage stamps must move together")
    }

    /// End-to-end: a steady metronome's tiles must sit within a 16th of the
    /// audible clicks — the core "I can see the sync" guarantee.
    func testMetronomeChartNotesLandOnAudibleClicks() async throws {
        let analysis = SignalFixtures.metronomeAnalysis(bpm: 120, seconds: 30)
        let output = try await ChartGenerator().generate(
            analysis: analysis, songID: UUID(),
            request: ChartGenerator.Request(difficulty: .medium, densityMultiplier: 1.0, seed: 42))
        let notes = output.chart.notes
        XCTAssertFalse(notes.isEmpty)
        // Clicks every 0.5 s from ~0. A note may sit within a 16th of its
        // click (0.125 s at 120 BPM).
        let tolerance = 0.125 + 0.02
        for note in notes where note.type == .tap {
            let nearestClick = (note.time / 0.5).rounded() * 0.5
            XCTAssertLessThanOrEqual(abs(note.time - nearestClick), tolerance,
                                     "note at \(note.time) is not on an audible click")
        }
    }

    /// Density stays sane after the scoring rebalance (no onset dump).
    func testDensityRemainsBoundedAfterSyncRebalance() async throws {
        let analysis = SignalFixtures.metronomeAnalysis(bpm: 160, seconds: 60)
        let output = try await ChartGenerator().generate(
            analysis: analysis, songID: UUID(),
            request: ChartGenerator.Request(difficulty: .extreme, densityMultiplier: 1.4, seed: 1))
        let nps = Double(output.chart.notes.count) / 60.0
        XCTAssertLessThan(nps, 12, "hard global cap on notes per second still holds")
        XCTAssertGreaterThan(output.chart.notes.count, 40)
    }
}
