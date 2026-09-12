import XCTest
@testable import Music_Haptics

final class OnsetDetectorTests: XCTestCase {
    private let hopTime = 512.0 / 44100.0

    func testDetectsKnownImpulseTimes() {
        let times = [1.0, 1.5, 2.0, 2.5, 3.0]
        let flux = SignalFixtures.impulseFlux(times: times, hopTime: hopTime, length: Int(5 / hopTime))
        let onsets = OnsetDetector.detect(flux: flux, hopTime: hopTime)
        XCTAssertEqual(onsets.count, times.count)
        for (onset, expected) in zip(onsets, times) {
            XCTAssertEqual(onset.time, expected, accuracy: 0.03)
        }
    }

    func testMergesDoubleDetectionsCloserThanSeparation() {
        // Two impulses 20 ms apart should merge into one onset.
        let times = [1.0, 1.02]
        let flux = SignalFixtures.impulseFlux(times: times, hopTime: hopTime, length: Int(4 / hopTime))
        let onsets = OnsetDetector.detect(flux: flux, hopTime: hopTime)
        XCTAssertEqual(onsets.count, 1)
    }

    func testSilenceProducesNoOnsets() {
        let flux = [Float](repeating: 0.0001, count: Int(10 / hopTime))
        let onsets = OnsetDetector.detect(flux: flux, hopTime: hopTime)
        XCTAssertTrue(onsets.isEmpty)
    }
}