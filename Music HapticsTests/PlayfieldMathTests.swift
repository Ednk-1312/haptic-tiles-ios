import CoreGraphics
import XCTest
@testable import Music_Haptics

final class PlayfieldMathTests: XCTestCase {

    // MARK: - Touch → lane mapping (whole-lane hit targets)

    func testLaneMappingAtBoundaries() {
        let width: CGFloat = 400
        // Left edge of each lane belongs to that lane; the divider goes right.
        XCTAssertEqual(InputGeometry.lane(forX: 0, width: width), 0)
        XCTAssertEqual(InputGeometry.lane(forX: 99.9, width: width), 0)
        XCTAssertEqual(InputGeometry.lane(forX: 100, width: width), 1)
        XCTAssertEqual(InputGeometry.lane(forX: 199.9, width: width), 1)
        XCTAssertEqual(InputGeometry.lane(forX: 200, width: width), 2)
        XCTAssertEqual(InputGeometry.lane(forX: 299.9, width: width), 2)
        XCTAssertEqual(InputGeometry.lane(forX: 300, width: width), 3)
        XCTAssertEqual(InputGeometry.lane(forX: 399.9, width: width), 3)
    }

    func testLaneMappingClampsOutOfRangeTouches() {
        let width: CGFloat = 400
        XCTAssertEqual(InputGeometry.lane(forX: -5, width: width), 0)
        XCTAssertEqual(InputGeometry.lane(forX: 4000, width: width), 3)
        XCTAssertEqual(InputGeometry.lane(forX: 50, width: 0), 0)
    }

    func testLaneMappingUsesWholeLaneWidth() {
        // Touches near the center AND near the edge of a lane map to the same
        // lane — no pixel-perfect aiming required. (Fractions here are of the
        // WHOLE playfield: lane 0 is 0…0.25, lane 1 is 0.25…0.5, etc.)
        let width: CGFloat = 400
        for fraction in [0.02, 0.12, 0.24] {
            XCTAssertEqual(InputGeometry.lane(forX: width * fraction, width: width), 0,
                           "x=\(fraction) must stay in lane 0")
        }
        for fraction in [0.26, 0.37, 0.49] {
            XCTAssertEqual(InputGeometry.lane(forX: width * fraction, width: width), 1,
                           "x=\(fraction) must stay in lane 1")
        }
        for fraction in [0.51, 0.62, 0.74] {
            XCTAssertEqual(InputGeometry.lane(forX: width * fraction, width: width), 2,
                           "x=\(fraction) must stay in lane 2")
        }
        for fraction in [0.76, 0.9, 0.99] {
            XCTAssertEqual(InputGeometry.lane(forX: width * fraction, width: width), 3,
                           "x=\(fraction) must stay in lane 3")
        }
    }

    func testLaneCenterX() {
        let width: CGFloat = 400
        XCTAssertEqual(InputGeometry.centerX(ofLane: 0, width: width), 50)
        XCTAssertEqual(InputGeometry.centerX(ofLane: 3, width: width), 350)
    }

    /// Every X across the full playfield width maps to exactly one lane, and
    /// each lane's span is exactly W/4 — checked at compact, standard and
    /// large iPhone widths (including non-integer quarter boundaries).
    func testFullWidthSweepAcrossDeviceSizes() {
        let widths: [CGFloat] = [320, 390, 402, 430, 456, 493]   // SE…Pro Max
        for width in widths {
            let laneWidth = width / 4
            var perLane: [Int] = [0, 0, 0, 0]
            var previous: Int? = nil
            var step: CGFloat = 0.5
            // Non-integer boundaries (e.g. 402/4 = 100.5) must still land
            // deterministically on the right side of the divider.
            var x: CGFloat = 0
            while x <= width {
                let lane = InputGeometry.lane(forX: x, width: width)
                XCTAssertGreaterThanOrEqual(lane, 0, "width=\(width) x=\(x)")
                XCTAssertLessThanOrEqual(lane, 3, "width=\(width) x=\(x)")
                perLane[lane] += 1
                if let previous, abs(lane - previous) > 1 {
                    XCTFail("width=\(width): lane jump at x=\(x)")
                }
                previous = lane
                x += step
            }
            // Every lane is reachable and each gets its full quarter.
            for lane in 0..<4 {
                XCTAssertGreaterThan(perLane[lane], 0, "width=\(width): lane \(lane) unreachable")
            }
            // Spot-check the quarter spans at this width.
            for lane in 0..<4 {
                let lo = CGFloat(lane) * laneWidth
                let hi = (CGFloat(lane) + 1) * laneWidth
                XCTAssertEqual(InputGeometry.lane(forX: lo, width: width), lane, "width=\(width) lane \(lane) left edge")
                if lane < 3 {
                    XCTAssertEqual(InputGeometry.lane(forX: hi - 0.01, width: width), lane,
                                   "width=\(width) lane \(lane) right edge")
                    XCTAssertEqual(InputGeometry.lane(forX: hi, width: width), lane + 1,
                                   "width=\(width) divider at x=\(hi)")
                } else {
                    XCTAssertEqual(InputGeometry.lane(forX: width - 0.01, width: width), 3)
                }
            }
        }
    }

    /// Extreme edge touches: the very first and last pixels of the screen.
    func testExtremeEdgesMapToOuterLanes() {
        let width: CGFloat = 402
        XCTAssertEqual(InputGeometry.lane(forX: 0, width: width), 0)
        XCTAssertEqual(InputGeometry.lane(forX: 0.001, width: width), 0)
        XCTAssertEqual(InputGeometry.lane(forX: width - 0.001, width: width), 3)
        XCTAssertEqual(InputGeometry.lane(forX: width - 1, width: width), 3)
        // Past the edge clamps deterministically (never crashes, never "lane 4").
        XCTAssertEqual(InputGeometry.lane(forX: width + 1, width: width), 3)
        XCTAssertEqual(InputGeometry.lane(forX: -1, width: width), 0)
    }

    /// The structural contract the live input layer relies on: four equal
    /// quarters of the playfield width, i.e. the HStack gives every lane
    /// exactly W/4 — matching the renderer's laneWidth.
    func testFourEqualQuarters() {
        for width in [320.0, 402.0, 430.0, 493.0] {
            let quarter = width / 4
            for lane in 0..<4 {
                XCTAssertEqual(InputGeometry.centerX(ofLane: lane, width: CGFloat(width)),
                               (CGFloat(lane) + 0.5) * quarter, accuracy: 0.0001)
            }
        }
    }

    // MARK: - Hit-tile effect timing (80–150 ms HIT state)

    func testHitEffectDurationIsFixedAndBounded() {
        // Tile is removed at exactly 160 ms — never lingers, never vanishes
        // before the flash has read.
        XCTAssertNil(HitTileTiming.progress(age: -0.001))
        XCTAssertEqual(HitTileTiming.progress(age: 0) ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(HitTileTiming.progress(age: 0.08) ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(HitTileTiming.progress(age: 0.15) ?? -1, 0.9375, accuracy: 0.0001)
        XCTAssertNil(HitTileTiming.progress(age: HitTileTiming.totalDuration))
        XCTAssertNil(HitTileTiming.progress(age: 1.0), "hit tile must be removed after the effect")
        // The effect is independent of note travel speed by construction.
        XCTAssertEqual(HitTileTiming.totalDuration, 0.16, accuracy: 0.0001)
        XCTAssertEqual(HitTileTiming.pressDuration, 0.10, accuracy: 0.0001)
    }

    func testHitCompressionPressesThenHolds() {
        // Just hit: not compressed yet.
        XCTAssertEqual(HitTileTiming.compression(age: 0), 0, accuracy: 0.0001)
        // Mid-press: growing toward the peak.
        XCTAssertEqual(HitTileTiming.compression(age: 0.05), 0.07, accuracy: 0.0001)
        // Peak at the press boundary…
        XCTAssertEqual(HitTileTiming.compression(age: 0.10), HitTileTiming.maxCompression, accuracy: 0.0001)
        // …and held through the release fade (the tile shrinks once, reads,
        // then fades out while still pressed).
        XCTAssertEqual(HitTileTiming.compression(age: 0.13), HitTileTiming.maxCompression, accuracy: 0.0001)
        // Negative age (clock jitter) behaves as "not yet hit".
        XCTAssertEqual(HitTileTiming.compression(age: -1), 0, accuracy: 0.0001)
    }

    func testHitFadeCurve() {
        // Press phase: fully opaque.
        XCTAssertEqual(HitTileTiming.fade(age: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(HitTileTiming.fade(age: 0.05), 1, accuracy: 0.0001)
        // Release: linear 1 → 0 over the last 60 ms.
        XCTAssertEqual(HitTileTiming.fade(age: 0.13), 0.5, accuracy: 0.0001)
        XCTAssertEqual(HitTileTiming.fade(age: 0.16), 0, accuracy: 0.0001)
        XCTAssertEqual(HitTileTiming.fade(age: 0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(HitTileTiming.fade(age: -1), 0, accuracy: 0.0001)
    }

    // MARK: - Miss-tile effect timing (visible miss before removal)

    func testMissEffectIsFixedDurationAndRemovesTile() {
        XCTAssertNil(MissTileTiming.progress(age: -0.001))
        XCTAssertEqual(MissTileTiming.progress(age: 0) ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(MissTileTiming.progress(age: 0.07) ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertNil(MissTileTiming.progress(age: MissTileTiming.duration))
        XCTAssertNil(MissTileTiming.progress(age: 1.0), "missed tile must be removed after the effect")
        XCTAssertEqual(MissTileTiming.duration, 0.14, accuracy: 0.0001)
    }

    func testMissCollapseShrinkAndFade() {
        // Full size at declaration, fully collapsed (gone) at the end.
        XCTAssertEqual(MissTileTiming.collapse(age: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(MissTileTiming.collapse(age: 0.07), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MissTileTiming.collapse(age: 0.14), 1, accuracy: 0.0001)
        XCTAssertEqual(MissTileTiming.collapse(age: 5), 1, accuracy: 0.0001)
        XCTAssertEqual(MissTileTiming.collapse(age: -1), 0, accuracy: 0.0001)
        // Fade runs the full effect.
        XCTAssertEqual(MissTileTiming.fade(age: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(MissTileTiming.fade(age: 0.07), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MissTileTiming.fade(age: 0.14), 0, accuracy: 0.0001)
        // Red flash is strong up front and decays fast.
        XCTAssertEqual(MissTileTiming.flash(age: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(MissTileTiming.flash(age: 0.025), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MissTileTiming.flash(age: 0.06), 0, accuracy: 0.0001)
    }

    // MARK: - Note position math

    func testNoteProgress() {
        // progress = (noteTime − audioTime) / leadTime
        XCTAssertEqual(InputGeometry.progress(noteTime: 10, currentAudioTime: 8, leadTime: 2), 1, accuracy: 0.0001)
        XCTAssertEqual(InputGeometry.progress(noteTime: 10, currentAudioTime: 10, leadTime: 2), 0, accuracy: 0.0001)
        XCTAssertEqual(InputGeometry.progress(noteTime: 10, currentAudioTime: 10.5, leadTime: 2), -0.25, accuracy: 0.0001)
        // Guard against zero lead time.
        XCTAssertEqual(InputGeometry.progress(noteTime: 10, currentAudioTime: 9, leadTime: 0), 0)
    }

    // MARK: - BPM-aware lead time (Magic Tiles 3 anchoring)

    func testLeadTimeScalesWithBPMAndClamps() {
        // 120 BPM → base unchanged (the anchor).
        XCTAssertEqual(NoteMovement.leadTime(bpm: 120, base: 1.8), 1.8, accuracy: 0.0001)
        // Slow music (60 BPM): travel time roughly doubles (slow tiles).
        XCTAssertEqual(NoteMovement.leadTime(bpm: 60, base: 1.8), 3.134, accuracy: 0.01)
        // Fast music (240 BPM): travel time shrinks (~40% faster tiles).
        XCTAssertEqual(NoteMovement.leadTime(bpm: 240, base: 1.8), 1.034, accuracy: 0.01)
        // 220 BPM: between the anchor and the 240 case.
        XCTAssertEqual(NoteMovement.leadTime(bpm: 220, base: 1.8), 1.108, accuracy: 0.01)
        // Out-of-range BPM behaves like "unknown": plain base, clamped.
        XCTAssertEqual(NoteMovement.leadTime(bpm: 400, base: 1.8), 1.8, accuracy: 0.0001)
        // Unknown BPM: plain base, clamped.
        XCTAssertEqual(NoteMovement.leadTime(bpm: nil, base: 1.8), 1.8, accuracy: 0.0001)
        XCTAssertEqual(NoteMovement.leadTime(bpm: nil, base: 5), NoteMovement.maximumLeadTime, accuracy: 0.0001)
        XCTAssertEqual(NoteMovement.leadTime(bpm: nil, base: 0.2), NoteMovement.minimumLeadTime, accuracy: 0.0001)
    }

    func testLeadTimeMonotonicInBase() {
        let slowBase = NoteMovement.leadTime(bpm: 120, base: 1.2)
        let fastBase = NoteMovement.leadTime(bpm: 120, base: 2.2)
        XCTAssertGreaterThan(fastBase, slowBase)
    }

    func testLeadTimeIsStrictlyMonotonicInTempo() {
        // The Magic Tiles 3 contract: faster songs ALWAYS get faster-falling
        // notes — no plateau where two different tempos feel identical.
        var previous = NoteMovement.leadTime(bpm: 50, base: 1.8)
        for bpm in stride(from: 60.0, through: 280.0, by: 10.0) {
            let current = NoteMovement.leadTime(bpm: bpm, base: 1.8)
            XCTAssertLessThan(current, previous, "\(bpm) BPM must fall faster than the tempo below it")
            previous = current
        }
    }

    func testClampsScaleWithTempo() {
        // A 200 BPM song must be able to travel faster than the 120 BPM
        // floor — otherwise extreme tempos all squash into one value.
        let fastFloor = NoteMovement.scaledClamps(bpm: 200).min
        XCTAssertLessThan(fastFloor, NoteMovement.minimumLeadTime)
        // And a 50 BPM ballad may travel slower than the 120 BPM ceiling.
        let slowCeiling = NoteMovement.scaledClamps(bpm: 50).max
        XCTAssertGreaterThan(slowCeiling, NoteMovement.maximumLeadTime)
    }
}