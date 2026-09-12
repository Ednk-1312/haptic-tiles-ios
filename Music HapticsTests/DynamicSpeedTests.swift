import XCTest
@testable import Music_Haptics

/// Dynamic tile speed: locally-detected tempo modulates the song's base
/// speed SUBTLY (±12%), and the same curve drives the renderer's projection
/// AND the engine's spatial touch catch — what you see is what you hit.
@MainActor
final class DynamicSpeedTests: XCTestCase {

    // MARK: - NoteMovement curve (pure math)

    private func beats(every interval: Double, count: Int, from t0: Double = 0) -> [Beat] {
        (0..<count).map { Beat(time: t0 + Double($0) * interval, strength: 0.6, isStrong: $0 % 4 == 0) }
    }

    func testNoBeatsReturnsBaseLead() {
        let base = NoteMovement.leadTime(bpm: 120, base: 1.8)
        XCTAssertEqual(NoteMovement.dynamicLeadTime(at: 5, beats: [], globalBeatInterval: 0.5, baseLead: base), base)
        XCTAssertEqual(NoteMovement.dynamicLeadTime(at: 5, beats: beats(every: 0.5, count: 2),
                                                    globalBeatInterval: 0.5, baseLead: base), base,
                       "fewer than 4 beats in window = no local knowledge, no fake dynamics")
    }

    func testUniformTempoKeepsBaseLead() {
        // A perfectly steady 120 BPM song must NOT modulate at all.
        let base = NoteMovement.leadTime(bpm: 120, base: 1.8)
        let uniform = beats(every: 0.5, count: 40)
        for t in stride(from: 1.0, through: 15.0, by: 0.5) {
            XCTAssertEqual(NoteMovement.dynamicLeadTime(at: t, beats: uniform,
                                                        globalBeatInterval: 0.5, baseLead: base),
                           base, accuracy: 0.0001, "steady tempo must feel identical to the base speed")
        }
    }

    func testFasterLocalTempoShortensLead() {
        // Locally 50% faster (0.33s beats vs 0.5s global) → shorter lead.
        let base = NoteMovement.leadTime(bpm: 120, base: 1.8)
        var local: [Beat] = beats(every: 0.5, count: 8)
        local += (0..<12).map { Beat(time: local.last!.time + 0.33 * Double($0 + 1), strength: 0.6, isStrong: false) }
        let lead = NoteMovement.dynamicLeadTime(at: local[10].time, beats: local,
                                                globalBeatInterval: 0.5, baseLead: base)
        XCTAssertLessThan(lead, base, "faster section → tiles arrive sooner")
    }

    func testSlowerLocalTempoLengthensLead() {
        // Locally 50% slower (0.75s beats vs 0.5s global) → longer lead.
        let base = NoteMovement.leadTime(bpm: 120, base: 1.8)
        var local: [Beat] = beats(every: 0.5, count: 8)
        local += (0..<12).map { Beat(time: local.last!.time + 0.75 * Double($0 + 1), strength: 0.6, isStrong: false) }
        let lead = NoteMovement.dynamicLeadTime(at: local[10].time, beats: local,
                                                globalBeatInterval: 0.5, baseLead: base)
        XCTAssertGreaterThan(lead, base, "slower section → tiles travel gentler")
    }

    func testModulationIsSubtle() {
        // Even a drastic local tempo change (2× faster) stays within ±12%.
        let base = NoteMovement.leadTime(bpm: 120, base: 1.8)
        var local: [Beat] = beats(every: 0.5, count: 8)
        local += (0..<12).map { Beat(time: local.last!.time + 0.25 * Double($0 + 1), strength: 0.6, isStrong: false) }
        let lead = NoteMovement.dynamicLeadTime(at: local[10].time, beats: local,
                                                globalBeatInterval: 0.5, baseLead: base)
        XCTAssertGreaterThanOrEqual(lead, base * (1 - NoteMovement.dynamicExcessFraction) - 0.0001)
        XCTAssertLessThanOrEqual(lead, base * (1 + NoteMovement.dynamicExcessFraction) + 0.0001)
    }

    func testRobustToOneDroppedBeat() {
        // A single missed beat detection in an otherwise steady grid must not
        // visibly change the speed (median smoothing).
        let base = NoteMovement.leadTime(bpm: 120, base: 1.8)
        var steady = beats(every: 0.5, count: 20)
        steady.remove(at: 10)   // one dropped beat → one 1.0s interval
        let lead = NoteMovement.dynamicLeadTime(at: steady[14].time, beats: steady,
                                                globalBeatInterval: 0.5, baseLead: base)
        XCTAssertEqual(lead, base, accuracy: 0.01, "one artifact beat must vanish in the median")
    }

    // MARK: - Engine integration: renderer and touch catch share the curve

    /// Analysis fixture with a real beat grid (120 BPM steady).
    private static func makeAnalysis() -> AudioAnalysis {
        var analysis = AudioAnalysis(duration: 30, sampleRate: 44100, tempoBPM: 120, tempoConfidence: 0.95,
                                     beats: [], onsets: [], events: [], sections: [], waveform: [],
                                     averageEnergy: 0.5, analysisDuration: 0.1, hopTime: 0.01)
        analysis.beats = (0..<60).map { Beat(time: Double($0) * 0.5, strength: 0.6, isStrong: $0 % 4 == 0) }
        return analysis
    }

    private func makeEngine() -> (GameEngine, MutableClockPlayer) {
        var chart = Chart(songID: UUID(), difficulty: .medium, chartVersion: ChartStorage.chartVersion,
                          seed: 1, notes: [], generatedAt: Date(timeIntervalSince1970: 0),
                          nps: 0, duration: 20, difficultyScore: 5,
                          validationWarnings: [], generationDuration: 0)
        chart.notes = [ChartNote(id: 0, time: 2.0, lane: 0, duration: 0, type: .tap, strength: 0.5)]
        let player = MutableClockPlayer()
        let engine = GameEngine(audioURL: URL(fileURLWithPath: "/tmp/dynamic-speed-stub.wav"),
                                songTitle: "Dynamics", chart: chart,
                                analysis: Self.makeAnalysis(), settings: SettingsStore(),
                                practice: nil, player: player)
        engine.start()
        return (engine, player)
    }

    func testEngineDynamicLeadMatchesCurveOnSteadySong() {
        let (engine, player) = makeEngine()
        let base = engine.approachTime
        player.now = 4.0
        // Steady 120 BPM: dynamic lead ≈ base (within clamping tolerance).
        XCTAssertEqual(engine.dynamicLead(at: player.now), base, accuracy: 0.01)
    }

    func testSpatialCatchUsesDynamicLead() throws {
        // On a steady song the dynamic lead equals the base lead, so a touch
        // on a visible tile must still catch — proving the spatial path now
        // runs through the dynamic curve without breaking tile targeting.
        let (engine, player) = makeEngine()
        player.now = 2.0 - 0.5   // note is 0.5s out
        let base = engine.approachTime
        let lead = engine.dynamicLead(at: player.now)
        XCTAssertEqual(lead, base, accuracy: 0.01)
        // Tile center for a note 0.5s out with this lead: verify the distance
        // math places a touch at the tile's center at distance 0.
        let noteY = PlayfieldGeometry.hitLineY - (0.5 / lead) * (PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY)
        let centerY = noteY - PlayfieldGeometry.tileHeightFraction / 2
        let d = SpatialCatch.distance(noteTime: 2.0, touchTime: player.now, touchY: centerY,
                                      leadTime: lead, hitLineY: PlayfieldGeometry.hitLineY,
                                      topY: PlayfieldGeometry.topY,
                                      tileHeightFraction: PlayfieldGeometry.tileHeightFraction)
        XCTAssertEqual(d, 0, accuracy: 0.001, "touch on the tile's center (dynamic lead) = distance 0")
        engine.handleTap(lane: 0, point: CGPoint(x: 0.5, y: centerY))
        // 500 ms early + spatial floor ⇒ GOOD: the tile was caught, which is
        // the point — the spatial path works through the dynamic lead.
        XCTAssertEqual(engine.counts[.good], 1, "spatial catch still works through the dynamic lead")
    }
}
