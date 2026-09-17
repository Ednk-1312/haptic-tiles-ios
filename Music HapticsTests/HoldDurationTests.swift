import XCTest
@testable import Music_Haptics

/// Hold-duration contract: a hold completes in proportion to how long the
/// finger actually stayed down — never instantly, never all-or-nothing.
/// The chart tail remains authoritative; input latency and tap calibration must
/// not make the player sustain beyond the musical interval.
@MainActor
final class HoldDurationTests: XCTestCase {

    private var player: MutableClockPlayer!
    private var engine: GameEngine!
    private var chart: Chart!
    private var settings: SettingsStore!

    override func setUp() {
        super.setUp()
        // SettingsStore persists calibration by design. Keep this suite isolated
        // so the calibration test cannot leak a point-judgment offset into the
        // hold or latency suites that run after it.
        UserDefaults.standard.removeObject(forKey: "settings.calibrationOffsetMs")
        player = MutableClockPlayer()
        chart = Self.makeChart()
        settings = SettingsStore()
        engine = GameEngine(audioURL: URL(fileURLWithPath: "/tmp/hold-duration-stub.wav"),
                            songTitle: "Hold Duration", chart: chart,
                            analysis: nil, settings: settings, practice: nil,
                            player: player)
        engine.start()
    }

    override func tearDown() {
        engine.cleanup()
        engine = nil
        player = nil
        chart = nil
        settings?.calibrationOffsetMs = 0
        UserDefaults.standard.removeObject(forKey: "settings.calibrationOffsetMs")
        settings = nil
        super.tearDown()
    }

    /// One 3.0 → 5.0 hold (2 s) in lane 1, plus a tap far away in lane 3.
    private static func makeChart() -> Chart {
        var chart = Chart(songID: UUID(), difficulty: .medium, chartVersion: ChartStorage.chartVersion,
                          seed: 1, notes: [], generatedAt: Date(timeIntervalSince1970: 0),
                          nps: 0, duration: 12, difficultyScore: 5,
                          validationWarnings: [], generationDuration: 0)
        chart.notes = [ChartNote(id: 0, time: 3.0, lane: 1, duration: 2.0, type: .hold, strength: 0.8),
                       ChartNote(id: 1, time: 6.5, lane: 1, duration: 0, type: .tap, strength: 0.5),
                       ChartNote(id: 2, time: 9.0, lane: 3, duration: 0, type: .tap, strength: 0.5)]
        return chart
    }

    // MARK: - Tracker level

    func testReleaseCarriesMeasuredProgress() {
        var holds = HoldTracker()
        holds.start(lane: 0, index: 0, noteID: 7, startTime: 3.0, endTime: 5.0)

        let half = holds.release(lane: 0, at: 4.0)!
        XCTAssertEqual(half.progress, 0.5, accuracy: 0.0001,
                       "releasing halfway through must measure half")
        XCTAssertEqual(holds.recordedProgress(noteID: 7) ?? -1, 0.5, accuracy: 0.0001,
                       "the measured fraction survives release for the renderer")
        XCTAssertNil(holds.progress(lane: 0, at: 4.0))
    }

    func testTinyPressMeasuresTinyProgress() {
        var holds = HoldTracker()
        holds.start(lane: 1, index: 0, noteID: 1, startTime: 3.0, endTime: 5.0)
        let brief = holds.release(lane: 1, at: 3.1)!
        XCTAssertFalse(brief.completed)
        XCTAssertEqual(brief.progress, 0.05, accuracy: 0.0001,
                       "a 100 ms press is 5% of a 2 s hold — not zero, not full")
    }

    func testCompletionRecordsFullProgress() {
        var holds = HoldTracker()
        holds.start(lane: 2, index: 0, noteID: 3, startTime: 3.0, endTime: 5.0)
        _ = holds.complete(lane: 2)
        XCTAssertEqual(holds.recordedProgress(noteID: 3) ?? -1, 1, accuracy: 0.0001)
    }

    // MARK: - Engine level: duration and release behavior

    func testProgressAnchorsAtActualPressTime() {
        // A body catch starts the interaction before the head reaches the
        // line, but the measured sustain is still bounded by the chart tail.
        player.now = 3.6
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        let bodyY = PlayfieldGeometry.hitLineY - travel * 0.5
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: Double(bodyY)))
        XCTAssertTrue(engine.holdActive(lane: 1), "body press starts the sustain")

        player.now = 3.7
        let progress = engine.holdProgress(lane: 1) ?? -1
        XCTAssertEqual(progress, 0.1 / 1.4, accuracy: 0.01,
                       "a body catch starts the remaining physical sustain at the touch-down time")

        let visualAtPress = engine.holdVisualProgress(lane: 1, at: 3.6) ?? -1
        let visualAfterPress = engine.holdVisualProgress(lane: 1, at: 3.7) ?? -1
        XCTAssertEqual(visualAtPress, 0, accuracy: 0.001,
                       "the hold animation starts at the body press")
        XCTAssertGreaterThan(visualAfterPress, visualAtPress,
                             "the hold animation must advance before the head reaches the bottom line")
    }

    func testHeadPressProgressUsesFullMusicalSpan() {
        player.now = 3.0
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        player.now = 4.0
        XCTAssertEqual(engine.holdProgress(lane: 1) ?? -1, 0.5, accuracy: 0.01,
                       "half a 2 s hold held = half filled")
    }

    func testEarlyBodyPressVisualProgressCompletesAtTail() {
        // Starting on the visible body must immediately own the hold, and its
        // visual fill must still reach completion at the chart tail instead of
        // waiting for the head to reach the hit line first.
        player.now = 2.2
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        let bodyY = PlayfieldGeometry.hitLineY - travel * 0.5
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: Double(bodyY)))

        let atPress = engine.holdVisualProgress(lane: 1, at: 2.2) ?? -1
        let beforeTail = engine.holdVisualProgress(lane: 1, at: 4.9) ?? -1
        let atTail = engine.holdVisualProgress(lane: 1, at: 5.0) ?? -1
        XCTAssertEqual(atPress, 0, accuracy: 0.001)
        XCTAssertGreaterThan(atPress, -0.001)
        XCTAssertGreaterThan(beforeTail, atPress)
        XCTAssertEqual(atTail, 1, accuracy: 0.001,
                       "a hold started anywhere on its body must visually complete at its tail")
    }

    func testEarlyReleaseBanksProportionalPoints() {
        player.now = 3.0
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        XCTAssertTrue(engine.holdActive(lane: 1))

        player.now = 4.0
        engine.handleTouchUp(lane: 1)

        XCTAssertFalse(engine.holdActive(lane: 1))
        let points = engine.holdPopups.last?.points ?? 0
        XCTAssertEqual(points, Int(Double(SettingsStore().holdCompleteBonus) * 0.5),
                       "half a hold must bank half the bonus")
        XCTAssertEqual(engine.counts[.miss] ?? 0, 0)
    }

    func testBodyCatchBeforeHeadDoesNotExtendPhysicalHold() {
        // A visible body can be touched before the chart head reaches the
        // line. The player must not be forced to hold from that early catch
        // all the way to the tail.
        player.now = 2.2
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        let bodyY = PlayfieldGeometry.hitLineY - travel * 0.5
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: Double(bodyY)))

        XCTAssertTrue(engine.holdActive(lane: 1))
        XCTAssertEqual(engine.holdStartTime(lane: 1) ?? -1, 3.0, accuracy: 0.001,
                       "an early body catch must not extend the required physical duration")
        XCTAssertEqual(engine.holdTailTime(lane: 1) ?? -1, 5.0, accuracy: 0.001,
                       "the chart tail remains authoritative")
    }

    func testTailReleaseAtMusicalEndpointCompletes() {
        player.now = 3.0
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        player.now = 5.0
        engine.handleTouchUp(lane: 1)

        XCTAssertEqual(engine.holdState(for: 0), .completed)
        XCTAssertEqual(engine.recordedHoldProgress(id: 0) ?? -1, 1, accuracy: 0.0001)
    }

    func testReleaseGraceIsSmallAndDoesNotExtendTheHold() {
        player.now = 3.0
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))

        player.now = 4.95
        engine.handleTouchUp(lane: 1)
        XCTAssertEqual(engine.holdState(for: 0), .completed,
                       "release inside the small tail grace completes")

        engine.restart()
        player.now = 3.0
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        player.now = 4.90
        engine.handleTouchUp(lane: 1)
        XCTAssertEqual(engine.holdState(for: 0), .releasedEarly)
        XCTAssertEqual(engine.recordedHoldProgress(id: 0) ?? -1, 0.95, accuracy: 0.01)
    }

    func testTapCalibrationCannotStretchHoldDuration() {
        settings.calibrationOffsetMs = 100
        player.now = 3.0
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        player.now = 4.90
        engine.handleTouchUp(lane: 1)

        XCTAssertEqual(engine.holdState(for: 0), .releasedEarly,
                       "tap calibration must not move the hold tail or release clock")
        XCTAssertEqual(engine.recordedHoldProgress(id: 0) ?? -1, 0.95, accuracy: 0.01)
    }

    func testOutputLatencyDoesNotAddToPhysicalHoldDuration() {
        player.outputLatency = 0.12
        player.now = 3.12
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        player.now = 5.12
        engine.handleTouchUp(lane: 1)

        XCTAssertEqual(engine.holdState(for: 0), .completed,
                       "driver latency is projected once, not added to required finger time")
    }

    func testAutomaticHoldCompletionReleasesLaneForNextTap() {
        player.now = 3.0
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        XCTAssertTrue(engine.holdActive(lane: 1))

        // The 60 Hz engine path completes the hold without waiting for touch-up.
        player.now = 5.01
        engine.tickForTesting()
        XCTAssertFalse(engine.holdActive(lane: 1))

        // A later note in the same lane must be accepted even if the original
        // finger cancellation/touch-up callback never arrived.
        player.now = 6.5
        engine.handleTap(lane: 1)
        XCTAssertEqual(engine.counts[.perfect], 2,
                       "automatic completion must release the lane lock")
    }

    func testPauseCancelsActiveHoldWithoutMovingItsChartTail() {
        player.now = 3.0
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        XCTAssertTrue(engine.holdActive(lane: 1))

        player.now = 3.5
        engine.pause()
        XCTAssertFalse(engine.holdActive(lane: 1),
                       "pausing releases the physical contact instead of extending it through paused time")

        player.now = 20.0
        engine.resume()
        XCTAssertFalse(engine.holdActive(lane: 1),
                       "resume must not resurrect or extend a stale hold")
    }
}
