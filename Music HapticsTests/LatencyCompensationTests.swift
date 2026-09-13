import XCTest
@testable import Music_Haptics

/// The accuracy contract: taps are judged against what the player HEARS, not
/// the decoder's scheduled clock. These tests pin the output-latency
/// compensation so a system-level delay can never resurface as a hidden
/// accuracy penalty.
@MainActor
final class LatencyCompensationTests: XCTestCase {

    // MARK: - Pure judge behavior

    func testJudgeCompensatesPositiveOffset() {
        // calibrationOffset is added to the tap: a +80 ms offset makes a
        // 80 ms-early tap grade PERFECT (the shape of output-latency
        // compensation when expressed through the judge).
        let judge = InputJudge(config: .init(perfectWindow: 0.07, greatWindow: 0.13,
                                             goodWindow: 0.20, missWindow: 0.20,
                                             calibrationOffset: 0.08))
        // Tap 80 ms before the note → judged against heard time = note time.
        XCTAssertEqual(judge.classify(tapTime: 1.0 - 0.08, noteTime: 1.0), .perfect)
        XCTAssertEqual(judge.classify(tapTime: 1.0, noteTime: 1.0), .great,
                       "an uncompensated on-time tap IS 80 ms late relative to the heard anchor")
    }

    // MARK: - Engine-level compensation

    private var player: MutableClockPlayer!
    private var engine: GameEngine!
    private var chart: Chart!

    override func setUp() {
        super.setUp()
        player = MutableClockPlayer()
        chart = Self.makeChart()
        engine = GameEngine(audioURL: URL(fileURLWithPath: "/tmp/latency-stub.wav"),
                            songTitle: "Latency", chart: chart,
                            analysis: nil, settings: SettingsStore(), practice: nil,
                            player: player)
    }

    override func tearDown() {
        engine.cleanup()
        engine = nil
        player = nil
        super.tearDown()
    }

    private static func makeChart() -> Chart {
        var chart = Chart(songID: UUID(), difficulty: .medium, chartVersion: ChartStorage.chartVersion,
                          seed: 1, notes: [], generatedAt: Date(timeIntervalSince1970: 0),
                          nps: 0, duration: 12, difficultyScore: 5,
                          validationWarnings: [], generationDuration: 0)
        chart.notes = [ChartNote(id: 0, time: 2.0, lane: 1, duration: 0, type: .tap, strength: 0.5)]
        return chart
    }

    /// A tap the DECODER would call 30 ms late, but the player heard as
    /// exactly on-time (their sound arrived 30 ms behind the clock) — must
    /// grade PERFECT once the engine knows the output latency.
    func testTapGradedAgainstHeardTimeWhenLatencyKnown() {
        engine.start()
        player.outputLatency = 0.03
        // Tap at note time + 30 ms: against the heard clock (t − 30 ms) this
        // is dead-on.
        player.now = 2.0 + 0.03
        engine.handleTap(lane: 1)
        XCTAssertEqual(engine.counts[.perfect], 1,
                       "a tap on the heard beat must grade PERFECT despite output latency")
    }

    /// Autoplay must remain bit-exact: it taps AT the chart time with zero
    /// latency, and compensation must not shift validation.
    func testAutoplayKeepsPureTiming() {
        engine.start()
        engine.setAutoplay(true)
        player.outputLatency = 0.03
        player.now = 2.0
        // One tick past the note lets autoplay judge it at the exact time.
        player.now = 2.001
        engine.tickForTesting()
        XCTAssertEqual(engine.counts[.perfect], 1,
                       "autoplay taps at exact chart times must still grade PERFECT")
    }

    /// No latency measured (0): judgment must be identical to the raw clock.
    func testZeroLatencyPreservesLegacyBehavior() {
        engine.start()
        player.outputLatency = 0
        player.now = 2.0
        engine.handleTap(lane: 1)
        XCTAssertEqual(engine.counts[.perfect], 1)
    }

    /// Rolling bias telemetry: records signed deltas for the live HUD.
    func testRecentBiasReflectsMeasuredDeltas() {
        engine.start()
        player.outputLatency = 0
        player.now = 2.0
        engine.handleTap(lane: 1)   // dead-on → delta ≈ 0
        XCTAssertEqual(engine.recentTapBiasCount, 1)
        XCTAssertTrue(engine.recentTapBiasMs.magnitude < 5.0)
    }

    /// Render anchor: advances with ticks and subtracts latency so the
    /// renderer projects the heard position.
    func testRenderAnchorLeadsByLatency() {
        engine.start()
        player.outputLatency = 0.05
        player.now = 3.0
        engine.tickForTesting()
        XCTAssertEqual(engine.renderAnchorAudio, 3.0 - 0.05, accuracy: 0.001)
        XCTAssertEqual(engine.clockRate, 1.0)
    }
}
