import XCTest
@testable import Music_Haptics

final class TempoEstimatorTests: XCTestCase {
    private let hopTime = 512.0 / 44100.0

    func testDetects120BPMClickTrack() {
        var times: [Double] = []
        var t = 0.0
        while t < 30 { times.append(t); t += 0.5 }   // 120 BPM
        let flux = SignalFixtures.impulseFlux(times: times, hopTime: hopTime, length: Int(30 / hopTime))
        let estimate = TempoEstimator.estimate(flux: flux, hopTime: hopTime)
        XCTAssertGreaterThan(estimate.bpm, 0)
        XCTAssertEqual(estimate.bpm, 120, accuracy: 4)
        XCTAssertGreaterThan(estimate.confidence, 0.3)
    }

    func testOctavePreferenceStaysMusical() {
        // Ground truth 70 BPM; must resolve to ~70 or its octave double.
        var times: [Double] = []
        var t = 0.0
        while t < 40 { times.append(t); t += 60.0 / 70.0 }
        let flux = SignalFixtures.impulseFlux(times: times, hopTime: hopTime, length: Int(40 / hopTime))
        let estimate = TempoEstimator.estimate(flux: flux, hopTime: hopTime)
        XCTAssertGreaterThan(estimate.bpm, 0)
        XCTAssertTrue(abs(estimate.bpm - 70) < 5 || abs(estimate.bpm - 140) < 8,
                      "unexpected BPM \(estimate.bpm)")
    }

    /// Hop-quantized sixteenth grid at 8.34-hop spacing (~155 BPM) with kick
    /// accents every 4 beats (33.36 hops), like the dense trap/rap fixture:
    /// the raw ACF favors the 3× sub-harmonic (~51.7 BPM) because the
    /// fractional-hop drift degrades the beat-lag peak. The estimator must
    /// resolve it to the musical-range multiple (~156 BPM).
    func testSubHarmonicCorrectionResolvesTripleOctave() {
        var flux = [Float](repeating: 0, count: 1200)
        var i = 0
        while Double(i) * 8.34 < Double(flux.count) {
            let idx = Int((Double(i) * 8.34).rounded())
            if idx < flux.count { flux[idx] = 1 }
            i += 1
        }
        var j = 0
        while Double(j) * 33.36 < Double(flux.count) {
            let idx = Int((Double(j) * 33.36).rounded())
            if idx < flux.count { flux[idx] = 3.5 }
            j += 1
        }
        let estimate = TempoEstimator.estimate(flux: flux, hopTime: hopTime)
        XCTAssertGreaterThan(estimate.bpm, 0)
        XCTAssertTrue((150...165).contains(estimate.bpm), "got \(estimate.bpm), expected ~156")
        XCTAssertEqual(estimate.bpm, TempoEstimator.estimate(flux: flux, hopTime: hopTime).bpm)
    }

    /// Clean 12-hop impulse train with a strong accent every 4 impulses
    /// (bar-level periodicity at lag 48): the first in-range ACF peak is
    /// ~215 BPM (above the musical range); the accent anchors the ÷2
    /// multiple (~107.6 BPM) as the winner.
    func testSuperHarmonicCorrectionHalvesFastPeak() {
        var flux = [Float](repeating: 0, count: 1200)
        var i = 12
        while i < flux.count {
            flux[i] = (i % 48 == 0) ? 2.5 : 1
            i += 12
        }
        let estimate = TempoEstimator.estimate(flux: flux, hopTime: hopTime)
        XCTAssertGreaterThan(estimate.bpm, 0)
        XCTAssertTrue((102...113).contains(estimate.bpm), "got \(estimate.bpm), expected ~107.6")
        XCTAssertEqual(estimate.bpm, TempoEstimator.estimate(flux: flux, hopTime: hopTime).bpm)
    }

    func testSilenceHasNoTempo() {
        let flux = [Float](repeating: 0.0001, count: Int(10 / hopTime))
        let estimate = TempoEstimator.estimate(flux: flux, hopTime: hopTime)
        XCTAssertEqual(estimate.bpm, 0)
        XCTAssertEqual(estimate.confidence, 0)
    }
}