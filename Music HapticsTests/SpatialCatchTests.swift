import XCTest
@testable import Music_Haptics

/// Spatial tap catching: tapping the tile you SEE must work. These tests pin
/// the PlayfieldGeometry contract and the SpatialCatch projection math the
/// engine and renderer share, so input and visuals can never drift apart.
final class SpatialCatchTests: XCTestCase {

    // MARK: - Geometry contract

    func testGeometryConstantsMatchRenderer() {
        // The renderer draws the hit line and tile height from these values;
        // if they change here without the renderer, tests below lose meaning.
        XCTAssertEqual(PlayfieldGeometry.hitLineY, 0.875, accuracy: 0.0001)
        XCTAssertEqual(PlayfieldGeometry.topY, 0.03, accuracy: 0.0001)
        XCTAssertEqual(PlayfieldGeometry.tileHeightFraction, 0.115, accuracy: 0.0001)
        XCTAssertGreaterThan(PlayfieldGeometry.spatialCatchDistance, 0.3,
                             "catch radius must be forgiving enough for real fingers")
        XCTAssertLessThan(PlayfieldGeometry.spatialCatchDistance, 2.0,
                          "catch radius must stay deliberate")
    }

    // MARK: - Projection math

    /// A note whose head has reached the hit line: its tile center sits
    /// exactly `tileHeight/2` above the line. A touch there → distance 0.
    func testDistanceZeroWhenTouchingTileCenterAtHitLine() {
        let lead = 1.8
        let tile = PlayfieldGeometry.tileHeightFraction
        let centerY = PlayfieldGeometry.hitLineY - tile / 2
        let d = SpatialCatch.distance(noteTime: 10.0, touchTime: 10.0,
                                      touchY: centerY, leadTime: lead,
                                      hitLineY: PlayfieldGeometry.hitLineY,
                                      topY: PlayfieldGeometry.topY,
                                      tileHeightFraction: tile)
        XCTAssertEqual(d, 0, accuracy: 0.0001)
    }

    /// A note one full lead-time away sits at the spawn line (its tile center
    /// one tile-height above). Touching exactly there is distance 0 again.
    func testDistanceZeroAtSpawnPosition() {
        let lead = 1.8
        let tile = PlayfieldGeometry.tileHeightFraction
        let spawnCenterY = PlayfieldGeometry.topY - tile / 2 + lead * 0 // sanity only
        _ = spawnCenterY
        // progress = (noteTime - touchTime)/lead = 1 → noteY = hitLineY - travel = topY
        let centerY = PlayfieldGeometry.topY - tile / 2
        let d = SpatialCatch.distance(noteTime: 11.8, touchTime: 10.0,
                                      touchY: centerY, leadTime: lead,
                                      hitLineY: PlayfieldGeometry.hitLineY,
                                      topY: PlayfieldGeometry.topY,
                                      tileHeightFraction: tile)
        XCTAssertEqual(d, 0, accuracy: 0.0001)
    }

    /// Half a travel-span off → half a tile-height distance. Confirms linear
    /// projection, not luck.
    func testDistanceIsLinearInTouchPosition() {
        let lead = 2.0
        let tile = PlayfieldGeometry.tileHeightFraction
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        // Note still 1s out → its bottom is exactly halfway down the lane.
        let noteY = PlayfieldGeometry.hitLineY - travel * 0.5
        let center = noteY - tile / 2
        let d = SpatialCatch.distance(noteTime: 11.0, touchTime: 10.0,
                                      touchY: center, leadTime: lead,
                                      hitLineY: PlayfieldGeometry.hitLineY,
                                      topY: PlayfieldGeometry.topY,
                                      tileHeightFraction: tile)
        XCTAssertEqual(d, 0, accuracy: 0.0001)
        // Touch one tile-height above the center → distance exactly 1.
        let d2 = SpatialCatch.distance(noteTime: 11.0, touchTime: 10.0,
                                       touchY: center - tile, leadTime: lead,
                                       hitLineY: PlayfieldGeometry.hitLineY,
                                       topY: PlayfieldGeometry.topY,
                                       tileHeightFraction: tile)
        XCTAssertEqual(d2, 1.0, accuracy: 0.0001)
    }

    func testUnspecifiedTouchSentinel() {
        XCTAssertEqual(SpatialCatch.unspecifiedTouch.x, 0.5)
        XCTAssertEqual(SpatialCatch.unspecifiedTouch.y, 0.5)
    }

    // MARK: - Hold span matching (Magic Tiles 3 body presses)

    /// A hold whose head sits at the hit line with a 1 s tail above: touching
    /// the MIDDLE of the visible body must be distance 0 — the whole long
    /// tile is the touch target, not just the head.
    func testHoldBodyTouchMatchesAnywhereOnTheSpan() {
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        let d = SpatialCatch.distance(noteTime: 10.0, touchTime: 10.0,
                                      touchY: PlayfieldGeometry.hitLineY - travel * 0.5,
                                      leadTime: 1.8,
                                      hitLineY: PlayfieldGeometry.hitLineY,
                                      topY: PlayfieldGeometry.topY,
                                      tileHeightFraction: PlayfieldGeometry.tileHeightFraction,
                                      holdTailTime: 11.0)
        XCTAssertEqual(d, 0, accuracy: 0.0001)
    }

    /// The same touch WITHOUT the span parameter (a plain tap) is far from
    /// the head-center target — proving the span is what makes body presses
    /// work, and tap tiles stay deliberate.
    func testSameTouchWithoutSpanDoesNotMatch() {
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        let d = SpatialCatch.distance(noteTime: 10.0, touchTime: 10.0,
                                      touchY: PlayfieldGeometry.hitLineY - travel * 0.5,
                                      leadTime: 1.8,
                                      hitLineY: PlayfieldGeometry.hitLineY,
                                      topY: PlayfieldGeometry.topY,
                                      tileHeightFraction: PlayfieldGeometry.tileHeightFraction)
        XCTAssertGreaterThan(d, PlayfieldGeometry.spatialCatchDistance)
    }

    /// A touch just above the tail (half a tile-height) still catches at
    /// distance 0.5 — inside the catch radius. (leadTime 2.0 puts a tail 1 s
    /// out at exactly half the travel span, keeping the numbers exact.)
    func testTouchJustAboveHoldTailStillCatches() {
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        let tailY = PlayfieldGeometry.hitLineY - travel * 0.5
        let d = SpatialCatch.distance(noteTime: 10.0, touchTime: 10.0,
                                      touchY: tailY - PlayfieldGeometry.tileHeightFraction / 2,
                                      leadTime: 2.0,
                                      hitLineY: PlayfieldGeometry.hitLineY,
                                      topY: PlayfieldGeometry.topY,
                                      tileHeightFraction: PlayfieldGeometry.tileHeightFraction,
                                      holdTailTime: 11.0)
        XCTAssertEqual(d, 0.5, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(d, PlayfieldGeometry.spatialCatchDistance)
    }

    /// A touch well above the hold's tail (two tile-heights) is outside the
    /// radius — body presses can't grab notes they aren't on.
    func testTouchFarAboveHoldTailDoesNotCatch() {
        let travel = PlayfieldGeometry.hitLineY - PlayfieldGeometry.topY
        let tailY = PlayfieldGeometry.hitLineY - travel * 0.5
        let d = SpatialCatch.distance(noteTime: 10.0, touchTime: 10.0,
                                      touchY: tailY - 2 * PlayfieldGeometry.tileHeightFraction,
                                      leadTime: 1.8,
                                      hitLineY: PlayfieldGeometry.hitLineY,
                                      topY: PlayfieldGeometry.topY,
                                      tileHeightFraction: PlayfieldGeometry.tileHeightFraction,
                                      holdTailTime: 11.0)
        XCTAssertGreaterThan(d, PlayfieldGeometry.spatialCatchDistance)
    }

    // MARK: - Partial hold banking

    func testPartialHoldBanksProportionalBonusWithoutComboBreak() {
        var score = ScoreManager()
        score.apply(.perfect)          // combo 1, multiplier grows
        let before = score.score
        score.bankPartialHold(progress: 0.5)
        XCTAssertGreaterThan(score.score, before, "half-sustained hold banks half the bonus")
        XCTAssertEqual(score.comboCount, 1, "partial bank must NOT break combo")
        XCTAssertEqual(score.holdsMissed, 0, "a genuine sustain is not a miss")
    }

    func testZeroProgressBankDoesNothing() {
        var score = ScoreManager()
        score.apply(.perfect)
        let before = score.score
        score.bankPartialHold(progress: 0)
        XCTAssertEqual(score.score, before)
        XCTAssertEqual(score.holdsCompleted, 0)
    }

    func testProgressAboveOneClampsToFullBonus() {
        var score = ScoreManager()
        score.apply(.perfect)
        score.bankPartialHold(progress: 2.5)
        XCTAssertEqual(score.holdsCompleted, 1)
    }
}
