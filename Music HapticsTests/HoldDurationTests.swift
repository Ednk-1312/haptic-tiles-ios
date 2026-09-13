import XCTest
@testable import Music_Haptics

/// Hold-duration contract: a hold completes in proportion to how long the
/// finger actually stayed down — never instantly, never all-or-nothing.
/// Pins the press-time anchor (progress starts when the finger goes down,
/// not at the chart timestamp) and the measured release progress that the
/// renderer's fill and the partial bank both consume.
@MainActor
final class HoldDurationTests: XCTestCase {

    private var player: MutableClockPlayer!
    private var engine: GameEngine!
    private var chart: Chart!

    override func setUp() {
        super.setUp()
        player = MutableClockPlayer()
        chart = Self.makeChart()
        engine = GameEngine(audioURL: URL(fileURLWithPath: "/tmp/hold-duration-stub.wav"),
                            songTitle: "Hold Duration", chart: chart,
                            analysis: nil, settings: SettingsStore(), practice: nil,
                            player: player)
        engine.start()
    }

    override func tearDown() {
        engine.cleanup()
        engine = nil
        player = nil
        chart = nil
        super.tearDown()
    }

    /// One 3.0 → 5.0 hold (2 s) in lane 1, plus a tap far away in lane 3.
    private static func makeChart() -> Chart {
        var chart = Chart(songID: UUID(), difficulty: .medium, chartVersion: ChartStorage.chartVersion,
                          seed: 1, notes: [], generatedAt: Date(timeIntervalSince1970: 0),
                          nps: 0, duration: 12, difficultyScore: 5,
                          validationWarnings: [], generationDuration: 0)
        chart.notes = [ChartNote(id: 0, time: 3.0, lane: 1, duration: 2.0, type: .hold, strength: 0.8),
                       ChartNote(id: 1, time: 9.0, lane: 3, duration: 0, type: .tap, strength: 0.5)]
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

        // Re-querying the (now removed) active hold must not fabricate a value.
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

    // MARK: - Engine level: press-time anchoring

    func testProgressAnchorsAtActualPressTime() {
        // Press the hold's body mid-lane while the head is still inbound.
        // The visible fill must start at ZERO on the press and grow with the
        // finger — never jump to the head's chart timestamp (the "instantly
        // goes" bug). The fill completes exactly at the musical tail.
        player.now = 3.6
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        let bodyY = PlayfieldGeometry.hitLineY - travel * 0.5
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: Double(bodyY)))
        XCTAssertTrue(engine.holdActive(lane: 1), "body press starts the sustain")

        player.now = 3.7   // 100 ms of real pressing
        let early = engine.holdProgress(lane: 1) ?? -1
        XCTAssertLessThan(early, 0.15,
                          "fill starts near zero at the press (was ~35% pre-filled)")

        player.now = 4.1   // 0.5 s of pressing, 1.4 s span to the tail
        let progress = engine.holdProgress(lane: 1) ?? -1
        XCTAssertEqual(progress, 0.5 / 1.4, accuracy: 0.01,
                       "fill is measured from the press toward the tail")
    }

    func testHeadPressProgressUsesFullMusicalSpan() {
        // The common case: pressing at the head, the span IS the duration.
        player.now = 3.0
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        player.now = 4.0
        XCTAssertEqual(engine.holdProgress(lane: 1) ?? -1, 0.5, accuracy: 0.01,
                       "half a 2 s hold held = half filled")
    }

    func testEarlyReleaseBanksProportionalPoints() {
        player.now = 3.0
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        XCTAssertTrue(engine.holdActive(lane: 1))

        player.now = 4.0   // exactly half the 2 s hold
        engine.handleTouchUp(lane: 1)

        XCTAssertFalse(engine.holdActive(lane: 1))
        let points = engine.holdPopups.last?.points ?? 0
        // Default holdCompleteBonus is 500 → half a hold banks 250.
        XCTAssertEqual(points, Int(Double(SettingsStore().holdCompleteBonus) * 0.5),
                       "half a hold must bank half the bonus — measured, not instant")
        XCTAssertEqual(engine.counts[.miss] ?? 0, 0)
    }

    func testHoldNeverCompletesBeforeItsTail() {
        // A release clearly before the tail (outside the 60 ms grace) must
        // NOT complete — and must record the honest fraction achieved.
        player.now = 3.0
        engine.handleTap(lane: 1, point: CGPoint(x: 0.5, y: PlayfieldGeometry.hitLineY))
        player.now = 4.90   // 1.9 s held, 100 ms early
        engine.handleTouchUp(lane: 1)
        XCTAssertEqual(engine.holdState(for: 0), .releasedEarly)
        XCTAssertEqual(engine.recordedHoldProgress(id: 0) ?? -1, 0.95, accuracy: 0.01,
                       "nearly-full release records nearly-full progress")
    }
}
