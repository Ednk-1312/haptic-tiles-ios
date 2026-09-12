import XCTest
@testable import Music_Haptics

/// Deterministic tests for the calibration algorithm. The exercise is fully
/// simulated with a synthetic monotonic anchor: taps are placed relative to
/// known cue times, and the recommended offset is verified against the input
/// latency — never requiring real audio, haptics, or a device.
final class CalibrationTests: XCTestCase {

    private var config: CalibrationSession.Config {
        var c = CalibrationSession.Config()
        c.countInBeats = 4
        c.tapBeats = 12
        c.interval = 0.667
        c.acceptanceWindow = 0.5
        c.minimumMeasurements = 4
        return c
    }

    /// Simulates a full exercise: taps land `latency` seconds after every
    /// measured cue (positive = late). Returns the recommended offset.
    private func simulate(latency: Double) -> Double? {
        var session = CalibrationSession(config: config)
        let anchor: Double = 1000
        session.start(at: anchor)
        for (i, cue) in session.measuredCueTimes(anchor: anchor).enumerated() {
            session.record(tapAt: cue + latency)
            XCTAssertEqual(session.taps.count, i + 1, "every measured cue should accept a tap")
        }
        return session.recommendedOffsetMs
    }

    // MARK: - Estimation

    func testPerfectTapsSuggestZeroOffset() {
        XCTAssertEqual(simulate(latency: 0)!, 0, accuracy: 5)
    }

    func testConsistentLateTapsSuggestNegativeOffset() {
        // Tapping 40 ms late should push the offset down by ~40 ms.
        let offset = simulate(latency: 0.04)!
        XCTAssertEqual(offset, -40, accuracy: 5)
        XCTAssertLessThan(offset, 0)
    }

    func testConsistentEarlyTapsSuggestPositiveOffset() {
        let offset = simulate(latency: -0.03)!
        XCTAssertEqual(offset, 30, accuracy: 5)
        XCTAssertGreaterThan(offset, 0)
    }

    func testRoundsToFiveMsSteps() {
        let median: Double = 0.0415 // 41.5 ms late → -41.5 → -40
        XCTAssertEqual(CalibrationSession.recommendedOffset(fromMedianError: median), -40, accuracy: 0.001)
        let early: Double = -0.027 // 27 early → +27 → +25
        XCTAssertEqual(CalibrationSession.recommendedOffset(fromMedianError: early), 25, accuracy: 0.001)
    }

    func testClampsToSettingsRange() {
        XCTAssertEqual(CalibrationSession.recommendedOffset(fromMedianError: -0.5), 100, accuracy: 0.001)
        XCTAssertEqual(CalibrationSession.recommendedOffset(fromMedianError: 0.9), -100, accuracy: 0.001)
    }

    func testMedianIsRobustToOutliers() {
        let values = [0.0, 0.01, -0.02, 0.0, 3.0] // one wildly bad tap
        XCTAssertEqual(CalibrationSession.median(values), 0.0, accuracy: 0.0001)
    }

    // MARK: - Acceptance / rejection

    func testMinimumMeasurementsRequired() {
        var session = CalibrationSession(config: config)
        session.start(at: 1000)
        let cues = session.measuredCueTimes(anchor: 1000)
        // Only 2 taps — below the minimum of 4.
        session.record(tapAt: cues[0])
        session.record(tapAt: cues[1])
        XCTAssertNil(session.recommendedOffsetMs)
        XCTAssertEqual(session.measurements.count, 2)
    }

    func testTapTooFarFromCueIsRejected() {
        // Window narrower than half the beat interval, so a mid-gap tap is
        // genuinely too far from its nearest cue.
        var c = config
        c.interval = 0.5
        c.acceptanceWindow = 0.1
        var session = CalibrationSession(config: c)
        session.start(at: 1000)
        let cue = session.measuredCueTimes(anchor: 1000)[0]
        session.record(tapAt: cue + 0.2) // nearest cue is 0.2 away > 0.1
        XCTAssertEqual(session.rejectedTaps, 1)
        XCTAssertTrue(session.measurements.isEmpty)
    }

    func testDoubleTapOnSameCueIsRejected() {
        var session = CalibrationSession(config: config)
        session.start(at: 1000)
        let cue = session.measuredCueTimes(anchor: 1000)[0]
        session.record(tapAt: cue + 0.01)
        session.record(tapAt: cue + 0.02) // 10 ms after the previous tap
        XCTAssertEqual(session.measurements.count, 1)
        XCTAssertEqual(session.rejectedTaps, 1)
    }

    func testOutOfOrderTapsMatchNearestUnconsumedCue() {
        var session = CalibrationSession(config: config)
        session.start(at: 1000)
        let cues = session.measuredCueTimes(anchor: 1000)
        // Hit cue 2 first, then cue 1 — each must consume its own cue.
        session.record(tapAt: cues[2] + 0.01)
        session.record(tapAt: cues[1] + 0.01)
        XCTAssertEqual(session.measurements.count, 2)
        XCTAssertEqual(session.measurements[0], 0.01, accuracy: 0.0001)
        XCTAssertEqual(session.measurements[1], 0.01, accuracy: 0.0001)
    }

    // MARK: - Exercise structure

    func testCountInIsNotMeasured() {
        var session = CalibrationSession(config: config)
        session.start(at: 1000)
        XCTAssertEqual(session.measuredCueTimes(anchor: 1000).count, config.tapBeats)
        XCTAssertEqual(session.cueTimes(anchor: 1000).count, config.countInBeats + config.tapBeats)
    }

    func testRecordBeforeStartReturnsNil() {
        var session = CalibrationSession(config: config)
        XCTAssertNil(session.record(tapAt: 1000))
        XCTAssertTrue(session.measurements.isEmpty)
    }

    func testRestartResetsAllState() {
        var session = CalibrationSession(config: config)
        session.start(at: 1000)
        let cues = session.measuredCueTimes(anchor: 1000)
        session.record(tapAt: cues[0])
        session.record(tapAt: cues[0] + 0.8) // rejected
        session.start(at: 2000)
        XCTAssertTrue(session.taps.isEmpty)
        XCTAssertTrue(session.measurements.isEmpty)
        XCTAssertEqual(session.rejectedTaps, 0)
    }

    func testMixedLatencyUsesMedianNotMean() {
        var session = CalibrationSession(config: config)
        session.start(at: 1000)
        let cues = session.measuredCueTimes(anchor: 1000)
        // 11 taps at +0.04, one wildly late outlier at +1.0 (still inside the
        // 0.5 window? no — 1.0 is beyond it, so use +0.35, which is within).
        for (i, cue) in cues.enumerated() {
            let latency = i == cues.count - 1 ? 0.35 : 0.04
            session.record(tapAt: cue + latency)
        }
        let offset = session.recommendedOffsetMs!
        // Mean would be ~-66; median is -40 — the robust estimate must win.
        XCTAssertEqual(offset, -40, accuracy: 5)
    }
}