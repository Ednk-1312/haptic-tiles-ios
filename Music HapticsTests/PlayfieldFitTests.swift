import CoreGraphics
import XCTest
@testable import Music_Haptics

/// Deterministic tests for the normalized playfield-placement math used by
/// the "Fit Playfield to Screen" tool. Everything is pure: mapping between
/// normalized fractions and container points, clamping (off-screen / tiny /
/// oversized), and the drag behavior for all four corners and the center.
final class PlayfieldFitTests: XCTestCase {

    private let container = CGSize(width: 402, height: 874)

    private func assertRect(_ rect: CGRect, _ x: CGFloat, _ y: CGFloat,
                            _ w: CGFloat, _ h: CGFloat, accuracy: CGFloat = 0.001,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.minX, x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.minY, y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.width, w, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.height, h, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - Default

    func testFullDefaultCoversContainerExactly() {
        let rect = PlayfieldFit.full.rect(in: container)
        assertRect(rect, 0, 0, 402, 874)
    }

    func testFullDefaultSurvivesAnyContainerSize() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 430, height: 932),
                     CGSize(width: 402, height: 996), CGSize(width: 768, height: 1024)] {
            let rect = PlayfieldFit.full.rect(in: size)
            XCTAssertEqual(rect.size, size)
        }
    }

    // MARK: - Rect mapping (normalized <-> points)

    func testRectMappingIntoContainer() {
        let fit = PlayfieldFit(x: 0.25, y: 0.1, width: 0.5, height: 0.7)
        let rect = fit.rect(in: container)
        assertRect(rect, 100.5, 87.4, 201, 611.8)
    }

    func testNormalizationRoundTrip() {
        let rect = CGRect(x: 80, y: 120, width: 260, height: 640)
        let fit = PlayfieldFit(rect: rect, in: container)
        let back = fit.rect(in: container)
        assertRect(back, 80, 120, 260, 640)
    }

    func testDegenerateContainerFallsBackToFull() {
        XCTAssertEqual(PlayfieldFit(rect: CGRect(x: 10, y: 10, width: 50, height: 50),
                                    in: .zero), PlayfieldFit.full)
        XCTAssertEqual(PlayfieldFit(rect: CGRect(x: 10, y: 10, width: 50, height: 50),
                                    in: CGSize(width: 0, height: 800)), PlayfieldFit.full)
    }

    // MARK: - Clamping

    func testClampKeepsInsideContainer() {
        let fit = PlayfieldFit(x: -0.3, y: 0.5, width: 0.6, height: 0.7).clamped()
        XCTAssertEqual(fit.x, 0)
        XCTAssertEqual(fit.y, 0.3, accuracy: 0.0001)
        XCTAssertEqual(fit.width, 0.6, accuracy: 0.0001)
        XCTAssertEqual(fit.height, 0.7, accuracy: 0.0001)
    }

    func testClampOversizedFitsContainer() {
        let fit = PlayfieldFit(x: 0.2, y: 0.1, width: 1.4, height: 2.0).clamped()
        XCTAssertEqual(fit.width, 1.0)
        XCTAssertEqual(fit.height, 1.0)
        XCTAssertEqual(fit.x, 0.0)
        XCTAssertEqual(fit.y, 0.0)
    }

    func testClampEnforcesMinimumSize() {
        let fit = PlayfieldFit(x: 0.5, y: 0.5, width: 0.01, height: 0.01)
            .clamped(minFraction: 0.15)
        XCTAssertEqual(fit.width, 0.15, accuracy: 0.0001)
        XCTAssertEqual(fit.height, 0.15, accuracy: 0.0001)
        // The shrunk playfield still fits at x=0.5 (0.5…0.65), so the
        // clamp keeps the position untouched — only size was repaired.
        XCTAssertEqual(fit.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(fit.y, 0.5, accuracy: 0.0001)
    }

    func testClampedFullScreenIsIdentity() {
        let fit = PlayfieldFit.full.clamped(minFraction: 0.15)
        XCTAssertEqual(fit, .full)
    }

    func testClampedResultAlwaysFullyInside() {
        for _ in 0..<500 {
            let fit = PlayfieldFit(x: Double.random(in: -1...2), y: Double.random(in: -1...2),
                                   width: Double.random(in: 0...1.5), height: Double.random(in: 0...1.5))
            let c = fit.clamped(minFraction: 0.15)
            XCTAssertGreaterThanOrEqual(c.x, 0)
            XCTAssertGreaterThanOrEqual(c.y, 0)
            XCTAssertLessThanOrEqual(c.x + c.width, 1.0001)
            XCTAssertLessThanOrEqual(c.y + c.height, 1.0001)
            XCTAssertGreaterThanOrEqual(c.width, 0.1499)
            XCTAssertGreaterThanOrEqual(c.height, 0.1499)
        }
    }

    // MARK: - Drag behavior (all handles)

    func testTopLeftCornerDrag() {
        let fit = PlayfieldFit.full.applied(.topLeft, dx: 0.1, dy: 0.05)
        assertFit(fit, 0.1, 0.05, 0.9, 0.95)
    }

    func testTopRightCornerDrag() {
        let fit = PlayfieldFit.full.applied(.topRight, dx: -0.1, dy: 0.05)
        assertFit(fit, 0, 0.05, 0.9, 0.95)
    }

    func testBottomLeftCornerDrag() {
        let fit = PlayfieldFit.full.applied(.bottomLeft, dx: 0.1, dy: -0.05)
        assertFit(fit, 0.1, 0, 0.9, 0.95)
    }

    func testBottomRightCornerDrag() {
        let fit = PlayfieldFit.full.applied(.bottomRight, dx: -0.1, dy: -0.05)
        assertFit(fit, 0, 0, 0.9, 0.95)
    }

    func testCenterDragMovesWithoutResizing() {
        let fit = PlayfieldFit.full.applied(.center, dx: 0.1, dy: 0.05)
        assertFit(fit, 0.1, 0.05, 1.0, 1.0)
    }

    func testDragThenClampStaysPlayable() {
        // Drag top-left corner far past the edges, then clamp: the playfield
        // must end up fully on-screen at the minimum size.
        let dragged = PlayfieldFit.full.applied(.topLeft, dx: 5, dy: 5)
        let fit = dragged.clamped(minFraction: 0.15)
        XCTAssertGreaterThanOrEqual(fit.x, 0)
        XCTAssertGreaterThanOrEqual(fit.y, 0)
        XCTAssertLessThanOrEqual(fit.x + fit.width, 1.0001)
        XCTAssertLessThanOrEqual(fit.y + fit.height, 1.0001)
        XCTAssertEqual(fit.width, 0.15, accuracy: 0.0001)
        XCTAssertEqual(fit.height, 0.15, accuracy: 0.0001)
    }

    // MARK: - Determinism / stability

    func testFitIsDeterministicAndEquatable() {
        let a = PlayfieldFit(x: 0.125, y: 0.25, width: 0.75, height: 0.6)
        let b = PlayfieldFit(x: 0.125, y: 0.25, width: 0.75, height: 0.6)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.rect(in: container), b.rect(in: container))
        XCTAssertNotEqual(a, .full)
    }

    private func assertFit(_ fit: PlayfieldFit, _ x: Double, _ y: Double,
                           _ w: Double, _ h: Double, accuracy: Double = 0.0001,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fit.x, x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(fit.y, y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(fit.width, w, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(fit.height, h, accuracy: accuracy, file: file, line: line)
    }
}