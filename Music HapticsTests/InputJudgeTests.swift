import XCTest
@testable import Music_Haptics

final class InputJudgeTests: XCTestCase {
    func testJudgmentWindows() {
        let judge = InputJudge(config: .standard)
        XCTAssertEqual(judge.classify(tapTime: 1.0, noteTime: 1.0), .perfect)
        XCTAssertEqual(judge.classify(tapTime: 1.08, noteTime: 1.0), .great)    // 80 ms late
        XCTAssertEqual(judge.classify(tapTime: 0.85, noteTime: 1.0), .good)     // 150 ms early
        XCTAssertEqual(judge.classify(tapTime: 1.30, noteTime: 1.0), .miss)     // 300 ms late
    }

    func testCalibrationShiftsJudgment() {
        var config = InputJudge.Config.standard
        config.calibrationOffset = -0.05   // user habitually taps 50 ms late
        let judge = InputJudge(config: config)
        XCTAssertEqual(judge.classify(tapTime: 1.05, noteTime: 1.0), .perfect)
    }

    func testNegativeOffsetCompensatesAudioLatency() {
        // Audio is 40 ms delayed → taps land 40 ms late; -40 ms calibration fixes it.
        var config = InputJudge.Config.standard
        config.calibrationOffset = -0.04
        let judge = InputJudge(config: config)
        XCTAssertEqual(judge.classify(tapTime: 1.04, noteTime: 1.0), .perfect)
    }

    func testEdgeGracePreventsPhantomMisses() {
        let judge = InputJudge(config: .standard)
        // 220 ms late is past GOOD (200 ms) but inside the 40 ms grace: a tap
        // clearly aimed at the note must NOT become a MISS.
        XCTAssertEqual(judge.classify(tapTime: 1.22, noteTime: 1.0), .miss)
        XCTAssertEqual(judge.classifyForgiving(tapTime: 1.22, noteTime: 1.0), .good)
        // Beyond grace: genuine miss (pure timeouts miss regardless).
        XCTAssertEqual(judge.classifyForgiving(tapTime: 1.26, noteTime: 1.0), .miss)
        // Inside normal windows nothing changes.
        XCTAssertEqual(judge.classifyForgiving(tapTime: 1.05, noteTime: 1.0), .perfect)
        XCTAssertEqual(judge.classifyForgiving(tapTime: 1.12, noteTime: 1.0), .great)
        XCTAssertEqual(judge.classifyForgiving(tapTime: 1.15, noteTime: 1.0), .good)
    }
}