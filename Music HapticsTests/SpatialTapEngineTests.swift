import XCTest
@testable import Music_Haptics

/// The player-facing contract: tapping the tile you SEE works — anywhere in
/// the lane, not just near the bottom hit line — and hold tiles respond to
/// press-and-hold with visible sustain feedback. Drives the real GameEngine
/// on a stub clock, exactly the way the touch layer delivers input.
@MainActor
final class SpatialTapEngineTests: XCTestCase {

    private var player: MutableClockPlayer!
    private var engine: GameEngine!
    private var chart: Chart!

    override func setUp() {
        super.setUp()
        player = MutableClockPlayer()
        chart = Self.makeChart()
        engine = GameEngine(audioURL: URL(fileURLWithPath: "/tmp/spatial-tap-stub.wav"),
                            songTitle: "Spatial Tap", chart: chart,
                            analysis: nil, settings: SettingsStore(), practice: nil,
                            player: player)
        engine.start()
    }

    override func tearDown() {
        engine.cleanup()
        engine = nil
        super.tearDown()
    }

    /// Tap notes at 1.0 (lane 0), 2.0 (lane 2), hold 3.0–5.0 (lane 1).
    private static func makeChart() -> Chart {
        var chart = Chart(songID: UUID(), difficulty: .medium, chartVersion: ChartStorage.chartVersion,
                          seed: 1, notes: [], generatedAt: Date(timeIntervalSince1970: 0),
                          nps: 0, duration: 12, difficultyScore: 5,
                          validationWarnings: [], generationDuration: 0)
        chart.notes = [ChartNote(id: 0, time: 1.0, lane: 0, duration: 0, type: .tap, strength: 0.5),
                       ChartNote(id: 1, time: 2.0, lane: 2, duration: 0, type: .tap, strength: 0.5),
                       ChartNote(id: 2, time: 3.0, lane: 1, duration: 2.0, type: .hold, strength: 0.8)]
        return chart
    }

    // MARK: - Spatial taps on visible tiles

    func testTappingVisibleTileMidLaneJudgesTheNote() {
        // 0.6 s before the note: its tile is ~1/3 down the lane — clearly
        // visible, clearly NOT at the hit line. The old time-only matcher
        // silently dropped this tap; spatial matching must judge it.
        player.now = 0.4
        let lead = engine.approachTime
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        let progress = (1.0 - 0.4) / lead
        let noteY = PlayfieldGeometry.hitLineY - CGFloat(progress) * travel
        let tileCenterY = noteY - CGFloat(PlayfieldGeometry.tileHeightFraction) / 2

        engine.handleTap(lane: 0, point: CGPoint(x: 0.5, y: Double(tileCenterY)))

        XCTAssertEqual(engine.counts[.miss], nil, "tapping a visible tile must not miss")
        XCTAssertEqual(engine.counts.values.reduce(0, +), 1, "the tap must judge exactly one note")
    }

    func testTappingAtTheHitLineStillWorks() {
        // Classic behavior preserved: tap when the note reaches the line.
        player.now = 1.0
        engine.handleTap(lane: 0, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        XCTAssertEqual(engine.counts[.perfect], 1, "on-line tap at the note time is PERFECT")
    }

    func testTapOnEmptyAreaDoesNothing() {
        // 2 full seconds before any note, touching mid-lane hits nothing.
        player.now = 0.0
        engine.handleTap(lane: 0, point: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(engine.counts.values.reduce(0, +), 0)
    }

    func testSpatialTapCannotBeWorseThanGood() {
        // Early but ON the tile: aimed correctly, so the floor applies.
        player.now = 0.55
        let lead = engine.approachTime
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        let progress = (1.0 - 0.55) / lead
        let noteY = PlayfieldGeometry.hitLineY - CGFloat(progress) * travel
        engine.handleTap(lane: 0, point: CGPoint(x: 0.5, y: Double(noteY - 0.03)))
        let misses = engine.counts[.miss] ?? 0
        XCTAssertEqual(misses, 0, "a tap on the visible tile is never a MISS")
        XCTAssertEqual(engine.counts.values.reduce(0, +), 1)
    }

    // MARK: - Holds: press-and-hold with sustain

    func testHoldSustainsWhileFingerStaysDown() {
        player.now = 3.0
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        XCTAssertTrue(engine.holdActive(lane: 1), "head tap starts the hold")

        // Sustain: finger stays down through the tail.
        player.now = 5.01
        engine.handleTouchUp(lane: 1)

        XCTAssertEqual(engine.result?.holdsCompleted, nil, "run has not finished yet")
        XCTAssertTrue(engine.holdCompleted(id: 2), "sustaining past the tail completes the hold")
    }

    func testEarlyReleaseBanksPartialProgress() {
        player.now = 3.0
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        XCTAssertTrue(engine.holdActive(lane: 1))

        player.now = 4.0   // halfway through the 2s hold
        engine.handleTouchUp(lane: 1)

        XCTAssertFalse(engine.holdActive(lane: 1), "release ends the hold")
        XCTAssertTrue(engine.holdCompleted(id: 2) || engine.holdState(for: 2) == .releasedEarly,
                      "the hold must reach a terminal state")
        // The bank surfaces as hold feedback (points popup), NOT as a miss —
        // judgment counts stay untouched because the head was already judged.
        XCTAssertEqual(engine.counts[.miss] ?? 0, 0, "early release must not count as a miss")
        XCTAssertEqual(engine.holdPopups.last?.lane, 1, "a hold-points popup confirms the bank")
        XCTAssertGreaterThan(engine.holdPopups.last?.points ?? 0, 0, "partial progress banks real points")
    }

    func testHoldHeadIsHittableViaVisibleTileToo() {
        // 0.8s before the hold head: tile is high on the lane. Press-and-hold
        // THERE must start the sustain (this was impossible before).
        player.now = 2.2
        let lead = engine.approachTime
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        let progress = (3.0 - 2.2) / lead
        let noteY = PlayfieldGeometry.hitLineY - CGFloat(progress) * travel
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: Double(noteY)))

        XCTAssertTrue(engine.holdActive(lane: 1) || engine.counts.values.reduce(0, +) == 1,
                      "pressing the visible hold tile must register")
    }

    func testPressingTheHoldBodyMidLaneStartsTheSustain() {
        // THE Magic Tiles 3 behavior: the hold is a long tile; pressing its
        // BODY (halfway along the visible span, far from the head) must
        // start the sustain animation immediately.
        player.now = 3.0   // head at the hit line; body stretches up the lane
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        let bodyY = PlayfieldGeometry.hitLineY - travel * 0.5
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: bodyY))

        XCTAssertTrue(engine.holdActive(lane: 1),
                      "pressing the hold's BODY must start the sustain")
        XCTAssertNil(engine.counts[.miss], "a body press must not miss")
    }

    func testSlidingOntoTheHoldBodySustainsIt() {
        // Slide onto the long body mid-lane: the move path must catch it too.
        player.now = 3.2
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        let bodyY = PlayfieldGeometry.hitLineY - travel * 0.5
        engine.handleLaneMove(lane: 1, point: CGPoint(x: 0.5, y: bodyY))

        XCTAssertTrue(engine.holdActive(lane: 1) || engine.counts.values.reduce(0, +) == 1,
                      "sliding onto the hold body must judge it")
    }

    // MARK: - Tempo-driven scroll speed (Magic Tiles 3 feel)

    /// Minimal analysis fixture carrying just a tempo.
    private static func makeAnalysis(bpm: Double?) -> AudioAnalysis {
        AudioAnalysis(duration: 30, sampleRate: 44100, tempoBPM: bpm, tempoConfidence: 0.9,
                      beats: [], onsets: [], events: [], sections: [], waveform: [],
                      averageEnergy: 0.5, analysisDuration: 0.1, hopTime: 0.01)
    }

    private func makeEngine(analysis: AudioAnalysis?) -> GameEngine {
        let engine = GameEngine(audioURL: URL(fileURLWithPath: "/tmp/spatial-tap-stub.wav"),
                                songTitle: "Tempo Probe", chart: chart,
                                analysis: analysis, settings: SettingsStore(),
                                practice: nil, player: MutableClockPlayer())
        engine.start()
        return engine
    }

    func testApproachTimeFollowsSongTempo() {
        // The default base (120 BPM anchor) is 1.8 s.
        let neutral = makeEngine(analysis: Self.makeAnalysis(bpm: 120))
        defer { neutral.cleanup() }
        XCTAssertEqual(neutral.approachTime, 1.8, accuracy: 0.0001)

        // A 180 BPM song must fall noticeably faster than the anchor…
        let fast = makeEngine(analysis: Self.makeAnalysis(bpm: 180))
        defer { fast.cleanup() }
        XCTAssertLessThan(fast.approachTime, neutral.approachTime * 0.8,
                          "faster music must show fewer beats on screen")

        // …and a 60 BPM ballad noticeably slower.
        let slow = makeEngine(analysis: Self.makeAnalysis(bpm: 60))
        defer { slow.cleanup() }
        XCTAssertGreaterThan(slow.approachTime, neutral.approachTime * 1.4,
                             "slower music must show more beats on screen")
    }

    func testUnknownTempoKeepsReadableConstantSpeed() {
        // No analysis (or tempo detection failed) → the base value verbatim:
        // a constant, readable speed instead of an extreme.
        let plain = makeEngine(analysis: nil)
        defer { plain.cleanup() }
        XCTAssertEqual(plain.approachTime, 1.8, accuracy: 0.0001)
    }

    func testTempoSpeedStaysInsideReadableBounds() {
        // Even at extreme detected tempos the travel time stays playable.
        let extreme = makeEngine(analysis: Self.makeAnalysis(bpm: 290))
        defer { extreme.cleanup() }
        let floor = NoteMovement.scaledClamps(bpm: 290).min
        XCTAssertGreaterThanOrEqual(extreme.approachTime, floor)
        XCTAssertGreaterThan(extreme.approachTime, 0.3, "never a blink-and-miss speed")
    }

    // MARK: - Timing path regression guards

    func testTimeOnlyTapStillJudgesWithoutSpatialPoint() {
        // Accessibility/autoplay path: unspecified point → pure timing.
        player.now = 1.05
        engine.handleTap(lane: 0)   // default unspecified touch
        XCTAssertEqual(engine.counts[.perfect], 1)
    }

    func testWayEarlyTapStillMissesCleanly() {
        // More than a catch-radius away from any tile → nothing judged here;
        // the note will simply pass and miss on its own clock.
        player.now = 0.0
        engine.handleTap(lane: 0, point: CGPoint(x: 0.5, y: 0.99))
        XCTAssertEqual(engine.counts.values.reduce(0, +), 0)
    }
}

/// Externally-settable fake clock (mirrors the engine-test harness pattern).
@MainActor
final class MutableClockPlayer: AudioPlayer {
    var now: Double = 0
    /// Simulated driver output latency (the real player measures this from
    /// AVAudioSession; the fake just stores what a test assigns).
    override var outputLatency: Double {
        get { simulatedLatency }
        set { simulatedLatency = newValue }
    }
    private var simulatedLatency: Double = 0

    override var currentTime: Double { now }
    override var duration: Double { 30 }
    override var volume: Float {
        get { 1 }
        set {}
    }

    override func load(url: URL) throws { now = 0 }
    override func play(from time: Double = 0) { now = time }
    override func pause() {}
    override func resume() {}
    override func seek(to time: Double) { now = time }
    override func stop() { now = 0 }
    override func setRate(_ rate: Double) {}
}
