import CoreGraphics
import Foundation

/// Placement of the gameplay playfield as fractions (0…1) of the screen /
/// container. Defaults to the FULL container; on devices where the automatic
/// edge-to-edge layout doesn't line up, the "Fit Playfield" tool lets the
/// player drag the corners of an outline to match their physical screen, and
/// the resulting rect is applied to BOTH rendering and touch mapping so the
/// four lanes always align with what the player sees.
///
/// This is pure math on purpose (no UIKit/SwiftUI) so it is unit-testable in
/// the platform-neutral logic package.
struct PlayfieldFit: Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// Full-container placement — the default on every normal device.
    static let full = PlayfieldFit(x: 0, y: 0, width: 1, height: 1)

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Normalize a rect given in container points. A degenerate (zero-sized)
    /// container falls back to the full placement.
    init(rect: CGRect, in size: CGSize) {
        guard size.width > 0, size.height > 0 else {
            self = .full
            return
        }
        self.init(x: Double(rect.minX / size.width),
                  y: Double(rect.minY / size.height),
                  width: Double(rect.width / size.width),
                  height: Double(rect.height / size.height))
    }

    /// The playfield rect in container points.
    func rect(in size: CGSize) -> CGRect {
        CGRect(x: CGFloat(x) * size.width,
               y: CGFloat(y) * size.height,
               width: CGFloat(width) * size.width,
               height: CGFloat(height) * size.height)
    }

    /// Keep the playfield fully inside the container, with a minimum
    /// fractional size (`minFraction` of the container, 0…1). Used after
    /// every drag so the playfield can never be dragged off-screen or
    /// collapsed to nothing.
    func clamped(minFraction: Double = 0.15) -> PlayfieldFit {
        let minW = min(1, max(0, minFraction))
        let minH = min(1, max(0, minFraction))
        let w = min(1, max(minW, width))
        let h = min(1, max(minH, height))
        let x = min(1 - w, max(0, self.x))
        let y = min(1 - h, max(0, self.y))
        return PlayfieldFit(x: x, y: y, width: w, height: h)
    }

    /// Which part of the outline a drag gesture is attached to.
    enum DragPoint: Sendable {
        case topLeft, topRight, bottomLeft, bottomRight, center
    }

    /// Result of dragging `point` by a normalized delta (dx/dy are fractions
    /// of the container). Pure math so the fit tool and its tests share the
    /// exact same drag behavior.
    func applied(_ point: DragPoint, dx: Double, dy: Double) -> PlayfieldFit {
        switch point {
        case .topLeft:
            return PlayfieldFit(x: x + dx, y: y + dy, width: width - dx, height: height - dy)
        case .topRight:
            return PlayfieldFit(x: x, y: y + dy, width: width + dx, height: height - dy)
        case .bottomLeft:
            return PlayfieldFit(x: x + dx, y: y, width: width - dx, height: height + dy)
        case .bottomRight:
            return PlayfieldFit(x: x, y: y, width: width + dx, height: height + dy)
        case .center:
            return PlayfieldFit(x: x + dx, y: y + dy, width: width, height: height)
        }
    }
}