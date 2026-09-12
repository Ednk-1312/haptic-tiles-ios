import SwiftUI
import UIKit

/// Raw multi-touch input layer for the four gameplay lanes. UIKit's built-in
/// responder pipeline (with `isMultipleTouchEnabled`) delivers every finger
/// independently with reliable down/move/up/cancel tracking — far more
/// dependable than SwiftUI's single-DragGesture-per-view model, which drops
/// or merges simultaneous touches and has no cancellation event.
final class LaneTouchLayer: UIView {
    var onLaneDown: ((Int, CGPoint) -> Void)?          // lane, normalized (0…1) point
    var onLaneMove: ((Int, CGPoint) -> Void)?          // lane, normalized point
    var onLaneUp: ((Int) -> Void)?                     // lane (also fires on cancel)

    /// Touch (touch, button) identity → lane. UITouch objects are stable for
    /// the lifetime of a contact, so this is the canonical finger mapping.
    private var lanesByTouch = [UITouch: Int]()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        // True: fingers resting on the glass keep receiving updates (hold
        // sustain must not be dropped when the touch stops moving).
        isExclusiveTouch = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported; LaneTouchLayer is created in code")
    }

    private func laneIndex(at location: CGPoint) -> Int? {
        let width = bounds.width
        guard width > 0 else { return nil }
        let x = location.x
        guard x >= 0, x <= width else { return nil }
        return min(3, max(0, Int(x / (width / 4))))
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, bounds.width > 0 ? point.x / bounds.width : 0)),
                y: min(1, max(0, bounds.height > 0 ? point.y / bounds.height : 0)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        for touch in touches {
            let location = touch.location(in: self)
            guard let lane = laneIndex(at: location) else { continue }
            lanesByTouch[touch] = lane
            onLaneDown?(lane, normalized(location))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        for touch in touches {
            guard let lane = lanesByTouch[touch] else { continue }
            let location = touch.location(in: self)
            // A finger dragged out of the playfield no longer sustains its
            // lane (release at the old lane would read as a random early
            // release); drag INTO a lane starts sustaining it.
            let currentLane = laneIndex(at: location)
            if currentLane != lane {
                onLaneUp?(lane)
                if let currentLane {
                    lanesByTouch[touch] = currentLane
                    onLaneDown?(currentLane, normalized(location))
                } else {
                    lanesByTouch.removeValue(forKey: touch)
                }
            } else {
                onLaneMove?(lane, normalized(location))
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        for touch in touches {
            guard let lane = lanesByTouch.removeValue(forKey: touch) else { continue }
            onLaneUp?(lane)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        for touch in touches {
            guard let lane = lanesByTouch.removeValue(forKey: touch) else { continue }
            onLaneUp?(lane)
        }
    }

}

/// SwiftUI wrapper that installs the raw touch layer and keeps it filling
/// its container. All four lanes live in ONE view so multi-touch (chords +
/// hold + tap at once) is tracked correctly by identity.
struct LaneTouchLayerView: UIViewRepresentable {
    var onLaneDown: (Int, CGPoint) -> Void
    var onLaneMove: (Int, CGPoint) -> Void = { _, _ in }
    var onLaneUp: (Int) -> Void

    func makeUIView(context: Context) -> LaneTouchLayer {
        let view = LaneTouchLayer()
        view.onLaneDown = onLaneDown
        view.onLaneMove = onLaneMove
        view.onLaneUp = onLaneUp
        return view
    }

    func updateUIView(_ uiView: LaneTouchLayer, context: Context) {
        uiView.onLaneDown = onLaneDown
        uiView.onLaneMove = onLaneMove
        uiView.onLaneUp = onLaneUp
    }
}
