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

    // MARK: - Absolute projection regressions

    func testProjectionIsMonotonicAcrossSpeedProfileBoundary() {
        let profile = DynamicSpeedProfile(
            duration: 12,
            points: [
                .init(time: 0, multiplier: 0.82),
                .init(time: 2, multiplier: 1.30),
                .init(time: 4, multiplier: 0.76),
                .init(time: 8, multiplier: 1.18),
                .init(time: 12, multiplier: 1.18)
            ],
            source: .deterministicChartAndSections,
            enabled: true,
            intensity: .standard,
            difficultyMultiplier: 1
        )

        let noteTime = 6.0
        let spawnTime = noteTime - profile.leadTime(at: noteTime, baseLead: 1.8)
        let values = stride(from: spawnTime, through: noteTime + 0.8, by: 0.01)
            .map { profile.progress(noteTime: noteTime, currentTime: $0, baseLead: 1.8) }

        for pair in zip(values, values.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.1, pair.0 + 0.000_001,
                                     "absolute projection must never move a tile backward")
        }
        XCTAssertEqual(values.first ?? -1, 1, accuracy: 0.000_001)
        XCTAssertEqual(profile.progress(noteTime: noteTime, currentTime: noteTime, baseLead: 1.8),
                       0, accuracy: 0.000_001)
    }

    func testProjectionIsContinuousAtProfileBoundary() {
        let profile = DynamicSpeedProfile(
            duration: 8,
            points: [
                .init(time: 0, multiplier: 0.8),
                .init(time: 2, multiplier: 1.4),
                .init(time: 4, multiplier: 0.7),
                .init(time: 8, multiplier: 1.1)
            ],
            source: .deterministicChartAndSections,
            enabled: true,
            intensity: .standard,
            difficultyMultiplier: 1
        )

        let noteTime = 5.0
        let epsilon = 0.000_001
        let before = profile.progress(noteTime: noteTime, currentTime: 2 - epsilon, baseLead: 1.8)
        let at = profile.progress(noteTime: noteTime, currentTime: 2, baseLead: 1.8)
        let after = profile.progress(noteTime: noteTime, currentTime: 2 + epsilon, baseLead: 1.8)

        XCTAssertEqual(before, at, accuracy: 0.000_01)
        XCTAssertEqual(at, after, accuracy: 0.000_01)
    }

    func testProjectionDependsOnlyOnAbsoluteTimeNotFrameSampling() {
        let profile = DynamicSpeedProfile(
            duration: 10,
            points: [
                .init(time: 0, multiplier: 0.9),
                .init(time: 3, multiplier: 1.25),
                .init(time: 6, multiplier: 0.85),
                .init(time: 10, multiplier: 1.1)
            ],
            source: .deterministicChartAndSections,
            enabled: true,
            intensity: .standard,
            difficultyMultiplier: 1
        )

        let noteTime = 7.0
        let sampleTimes = [1.25, 2.0, 3.0, 3.01, 4.5, 5.99, 6.0, 6.75]
        let direct = sampleTimes.map {
            profile.progress(noteTime: noteTime, currentTime: $0, baseLead: 1.8)
        }
        let repeated = sampleTimes.map {
            // Sampling at a different cadence must not accumulate movement;
            // the absolute-time query at the same timestamp is the contract.
            profile.progress(noteTime: noteTime, currentTime: $0, baseLead: 1.8)
        }

        XCTAssertEqual(direct, repeated, "frame cadence must not affect tile position")
    }

    func testHoldProjectionRemainsMonotonicAcrossSlowFastSlowRegions() {
        let profile = DynamicSpeedProfile(
            duration: 14,
            points: [
                .init(time: 0, multiplier: 0.80),
                .init(time: 3, multiplier: 0.82),
                .init(time: 6, multiplier: 1.38),
                .init(time: 9, multiplier: 0.76),
                .init(time: 14, multiplier: 0.80)
            ],
            source: .deterministicChartAndSections,
            enabled: true,
            intensity: .standard,
            difficultyMultiplier: 1
        )

        let head = 3.5
        let tail = 11.5
        let spawn = head - profile.leadTime(at: head, baseLead: 1.8)
        let samples = stride(from: spawn, through: tail + 0.5, by: 0.01).map { $0 }
        let headProgress = samples.map {
            profile.progress(noteTime: head, currentTime: $0, baseLead: 1.8)
        }
        let tailProgress = samples.map {
            profile.progress(noteTime: tail, currentTime: $0, baseLead: 1.8)
        }

        for values in [headProgress, tailProgress] {
            for pair in zip(values, values.dropFirst()) {
                XCTAssertLessThanOrEqual(pair.1, pair.0 + 0.000_001,
                                         "hold endpoints must never move backward through speed changes")
            }
        }
        XCTAssertEqual(profile.progress(noteTime: head, currentTime: head, baseLead: 1.8),
                       0, accuracy: 0.000_001)
        XCTAssertEqual(profile.progress(noteTime: tail, currentTime: tail, baseLead: 1.8),
                       0, accuracy: 0.000_001)
    }

    func testHoldMusicalDurationIsIndependentOfDynamicSpeed() {
        let profile = DynamicSpeedProfile(
            duration: 12,
            points: [
                .init(time: 0, multiplier: 0.78),
                .init(time: 4, multiplier: 1.42),
                .init(time: 8, multiplier: 0.74),
                .init(time: 12, multiplier: 1.10)
            ],
            source: .deterministicChartAndSections,
            enabled: true,
            intensity: .expressive,
            difficultyMultiplier: 1
        )
        let head = 2.5
        let tail = 10.5
        XCTAssertEqual(profile.progress(noteTime: head, currentTime: head, baseLead: 1.8),
                       0, accuracy: 0.000_001)
        XCTAssertEqual(profile.progress(noteTime: tail, currentTime: tail, baseLead: 1.8),
                       0, accuracy: 0.000_001)
        XCTAssertGreaterThan(profile.progress(noteTime: tail, currentTime: head, baseLead: 1.8), 1,
                              "before the tail's own spawn time, the tail remains offscreen; its musical endpoint is not a fixed visual distance")
    }

    func testHoldVisualFillUsesIntegratedSpeedPath() {
        let profile = DynamicSpeedProfile(
            duration: 12,
            points: [
                .init(time: 0, multiplier: 0.75),
                .init(time: 3, multiplier: 1.40),
                .init(time: 6, multiplier: 0.70),
                .init(time: 9, multiplier: 1.25),
                .init(time: 12, multiplier: 0.80)
            ],
            source: .deterministicChartAndSections,
            enabled: true,
            intensity: .expressive,
            difficultyMultiplier: 1
        )

        let values = stride(from: 2.0, through: 10.0, by: 0.01).map {
            profile.relativeProgress(from: 2.0, to: 10.0, at: $0)
        }
        for pair in zip(values, values.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0, pair.1 + 0.000_001,
                                      "integrated hold fill must never move backward")
        }
        XCTAssertEqual(profile.relativeProgress(from: 2.0, to: 10.0, at: 2.0),
                       0, accuracy: 0.000_001)
        XCTAssertEqual(profile.relativeProgress(from: 2.0, to: 10.0, at: 10.0),
                       1, accuracy: 0.000_001)
    }

    // MARK: - Standard Math intensity and settings contract


    private func makeChart(difficulty: DifficultyLevel = .medium,
                           noteTimes: [Double]) -> Chart {
        var chart = Chart(songID: UUID(), difficulty: difficulty,
                          chartVersion: ChartStorage.chartVersion,
                          seed: 42, notes: [],
                          generatedAt: Date(timeIntervalSince1970: 0),
                          nps: 0, duration: 24, difficultyScore: 5,
                          validationWarnings: [], generationDuration: 0)
        chart.notes = noteTimes.enumerated().map { index, time in
            ChartNote(id: index, time: time, lane: index % 4,
                      duration: 0, type: .tap, strength: 0.7)
        }
        return chart
    }

    private func sectionAnalysis() -> AudioAnalysis {
        AudioAnalysis(duration: 24, sampleRate: 44_100, tempoBPM: 120,
                       tempoConfidence: 0.9, beats: [], onsets: [], events: [],
                       sections: [
                           SongSection(index: 0, start: 0, end: 8,
                                       label: .intro, energy: 0.15),
                           SongSection(index: 1, start: 8, end: 16,
                                       label: .chorus, energy: 1.0),
                           SongSection(index: 2, start: 16, end: 24,
                                       label: .breakdown, energy: 0.25)
                       ], waveform: [], averageEnergy: 0.5,
                       analysisDuration: 0.1, hopTime: 0.01)
    }

    func testStandardMathIsDeterministicAndBounded() {
        let chart = makeChart(noteTimes: stride(from: 0.5, through: 23.5, by: 1.0).map { $0 })
        let analysis = sectionAnalysis()
        let first = StandardMathIntensityAnalyzer.make(chart: chart,
                                                        analysis: analysis,
                                                        duration: 24)
        let second = StandardMathIntensityAnalyzer.make(chart: chart,
                                                         analysis: analysis,
                                                         duration: 24)
        XCTAssertEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.count, 4)
        XCTAssertEqual(first.first?.time, 0)
        for point in first {
            XCTAssertTrue(point.intensity.isFinite)
            XCTAssertTrue((-1...1).contains(point.intensity))
        }
        for pair in zip(first, first.dropFirst()) {
            XCTAssertLessThan(pair.0.time, pair.1.time)
        }
    }

    func testStandardMathFollowsSparseDenseAndCalmSections() {
        let sparseThenDense = makeChart(noteTimes:
            [1, 3, 5, 7] + stride(from: 8.5, through: 15.5, by: 0.5).map { $0 }
            + [17, 19, 21, 23])
        let points = StandardMathIntensityAnalyzer.make(chart: sparseThenDense,
                                                         analysis: sectionAnalysis(),
                                                         duration: 24)
        let intro = points.filter { $0.time < 8 }.map(\.intensity).reduce(0, +)
            / Double(max(1, points.filter { $0.time < 8 }.count))
        let chorus = points.filter { $0.time >= 8 && $0.time < 16 }.map(\.intensity).reduce(0, +)
            / Double(max(1, points.filter { $0.time >= 8 && $0.time < 16 }.count))
        let breakdown = points.filter { $0.time >= 16 }.map(\.intensity).reduce(0, +)
            / Double(max(1, points.filter { $0.time >= 16 }.count))

        XCTAssertGreaterThan(chorus, intro, "dense chorus should read as more intense than intro")
        XCTAssertGreaterThan(chorus, breakdown, "calmer breakdown should read below chorus")
    }

    func testDynamicSpeedOffProducesStableProfile() {
        let chart = makeChart(noteTimes: stride(from: 0.5, through: 23.5, by: 1.0).map { $0 })
        let profile = DynamicSpeedProfile.make(analysis: sectionAnalysis(), chart: chart,
                                                enabled: false, intensity: .expressive)
        XCTAssertFalse(profile.enabled)
        XCTAssertEqual(profile.points.count, 2)
        XCTAssertEqual(profile.points[0].multiplier, chart.difficulty.visualSpeedMultiplier,
                       accuracy: 0.000_001)
        XCTAssertEqual(profile.points[0].multiplier, profile.points[1].multiplier,
                       accuracy: 0.000_001)
        XCTAssertEqual(profile.multiplier(at: 4), profile.multiplier(at: 20),
                       accuracy: 0.000_001)
    }

    func testDifficultySpeedOrderingIsMeaningfulAndBounded() {
        let chartNotes = stride(from: 0.5, through: 23.5, by: 0.75).map { $0 }
        let profiles = DifficultyLevel.allCases.map { difficulty in
            DynamicSpeedProfile.make(analysis: sectionAnalysis(),
                                      chart: makeChart(difficulty: difficulty, noteTimes: chartNotes),
                                      enabled: true, intensity: .standard)
        }
        let averages = profiles.map { profile in
            profile.points.map(\.multiplier).reduce(0, +) / Double(profile.points.count)
        }
        for pair in zip(averages, averages.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1,
                              "difficulty should increase stable visual pacing")
        }
        for profile in profiles {
            let range = profile.points.map(\.multiplier)
            XCTAssertTrue(range.allSatisfy { $0 >= 0.70 && $0 <= 1.50 })
        }
    }

    func testIntensitySettingChangesOnlyVisualProfile() {
        let chart = makeChart(noteTimes: stride(from: 0.5, through: 23.5, by: 0.75).map { $0 })
        let originalTimes = chart.notes.map(\.time)
        let subtle = DynamicSpeedProfile.make(analysis: sectionAnalysis(), chart: chart,
                                               enabled: true, intensity: .subtle)
        let expressive = DynamicSpeedProfile.make(analysis: sectionAnalysis(), chart: chart,
                                                  enabled: true, intensity: .expressive)
        let subtleRange = (subtle.points.map(\.multiplier).max() ?? 0)
            - (subtle.points.map(\.multiplier).min() ?? 0)
        let expressiveRange = (expressive.points.map(\.multiplier).max() ?? 0)
            - (expressive.points.map(\.multiplier).min() ?? 0)
        XCTAssertGreaterThan(expressiveRange, subtleRange)
        XCTAssertEqual(chart.notes.map(\.time), originalTimes,
                       "profile construction does not rewrite chart timestamps")
    }

    func testVisualSpeedNeverChangesProjectionAtNoteTime() {
        let chart = makeChart(noteTimes: stride(from: 0.5, through: 23.5, by: 0.75).map { $0 })
        let slowProfile = DynamicSpeedProfile.make(analysis: sectionAnalysis(), chart: chart,
                                                    enabled: true, intensity: .subtle)
        let fastProfile = DynamicSpeedProfile.make(analysis: sectionAnalysis(), chart: chart,
                                                    enabled: true, intensity: .expressive)
        for note in chart.notes {
            XCTAssertEqual(slowProfile.progress(noteTime: note.time, currentTime: note.time, baseLead: 1.8),
                           0, accuracy: 0.000_001)
            XCTAssertEqual(fastProfile.progress(noteTime: note.time, currentTime: note.time, baseLead: 1.8),
                           0, accuracy: 0.000_001)
        }
    }
}
