import SwiftUI

/// The four-lane playfield — the visual heart of the game.
///
/// Visual model (per the product spec / reference):
/// - FOUR unmistakable, equal-width, edge-to-edge columns (each lane is
///   exactly 25% of the playfield width) separated by crisp thin white
///   divider lines — the fourth lane can never be clipped or lost.
/// - A light, artwork-aware wash behind the field so near-black "piano"
///   tiles always read with strong contrast (Magic Tiles-style), while the
///   colorful artwork keeps breathing through it.
/// - MASSIVE near-black glossy tap tiles (~96% of the lane width) with a
///   per-lane colored glow + top-edge strip so each column keeps a bright
///   identity color on top of the black-tile look.
/// - HOLD notes are long colored vertical tiles (their length IS the musical
///   duration) with a glowing ring at the head so they read instantly as the
///   reference's long glowing note.
/// - Judgment text is large, glowing and centered over the playfield like the
///   reference; misses still report where they happened.
///
/// Note positions stay pure math on (chart time − audio time) — never
/// animation completion. Touch handling lives in `LaneInputView` below.
struct GamePlayfieldView: View {
    @ObservedObject var engine: GameEngine

    /// When true (default) the canvas spans the full screen edge-to-edge.
    /// The "Fit Playfield" tool sets this to false: the canvas then fills
    /// exactly its (user-fitted) frame instead of expanding to safe-area
    /// edges, so lanes, dividers and the hit line stay inside the fitted
    /// rect — and the input layer shares that same rect.
    var expandToSafeArea: Bool = true

    private let laneCount = 4

    /// Lane identity palette. Not the tile fill (tiles are piano-black) but
    /// the glow/rim/active colors that make each column distinguishable and
    /// keep the game energetic over the light wash.
    private static let lanePalette: [(top: Color, bottom: Color)] = [
        (Color(red: 0.00, green: 0.78, blue: 1.0), Color(red: 0.05, green: 0.32, blue: 1.0)),   // cyan → blue
        (Color(red: 1.00, green: 0.30, blue: 0.85), Color(red: 0.78, green: 0.15, blue: 1.0)), // pink → purple
        (Color(red: 0.45, green: 0.95, blue: 0.30), Color(red: 0.05, green: 0.70, blue: 0.38)), // lime → green
        (Color(red: 1.00, green: 0.55, blue: 0.15), Color(red: 1.00, green: 0.22, blue: 0.12))  // orange → red
    ]

    /// Piano-key body gradient (near-black, glossy top, dark base).
    private static let tileTop = Color(red: 0.165, green: 0.175, blue: 0.22)
    private static let tileBottom = Color(red: 0.045, green: 0.05, blue: 0.08)

    var body: some View {
        Group {
            if expandToSafeArea {
                playfieldContent.ignoresSafeArea()
            } else {
                playfieldContent
            }
        }
        // The canvas is purely visual; the lane input views below carry the
        // interactive VoiceOver elements, so the rendering must never add a
        // second, confusing element on top of them.
        .accessibilityHidden(true)
    }

    private var playfieldContent: some View {
        GeometryReader { geo in
            // Display-synchronized timeline: SwiftUI re-culls this subtree at
            // the display's cadence (60/120 Hz) instead of the game Timer's
            // cadence, so tile motion advances exactly one display refresh at
            // a time with no beat/judder against the screen. The sampled time
            // is the latency-compensated HEARD position — tiles land on what
            // the player's ears tell them, not on the decoder's schedule.
            // Logic (misses, holds, scoring) stays on the engine's Timer tick;
            // only the pixels run here.
            TimelineView(.animation) { timeline in
                // Extrapolate the engine's logic-tick anchor at display
                // cadence: audio(heard) at anchor + wall time since anchor ×
                // playback rate. Paused/not-started sessions hold the anchor
                // (no extrapolation) so nothing drifts while paused.
                let now = timeline.date.timeIntervalSinceReferenceDate
                let t: Double = {
                    guard engine.state == .playing, engine.renderAnchorDate > 0 else {
                        return engine.renderAnchorAudio
                    }
                    return engine.renderAnchorAudio + (now - engine.renderAnchorDate) * engine.clockRate
                }()
                Canvas { context, canvasSize in
                    drawLanes(context, size: canvasSize)
                    #if DEBUG
                    if engine.debugOverlayVisible {
                        drawLaneBoundaries(context, size: canvasSize)
                    }
                    if engine.debugChartMode {
                        drawChartStructure(context, size: canvasSize, time: t)
                    }
                    #endif
                    drawNotes(context, size: canvasSize, time: t)
                    drawHitRegion(context, size: canvasSize, time: t)
                    // Missed TAP tiles draw AFTER the hit region/shelf so their
                    // red flash + collapse reads bright instead of being darkened
                    // underneath the seating-shelf overlay.
                    drawMissTiles(context, size: canvasSize, time: t)
                    drawLaneFlashes(context, size: canvasSize, time: t)
                    drawBursts(context, size: canvasSize, time: t)
                    drawFeedback(context, size: canvasSize, time: t)
                    drawMisses(context, size: canvasSize, time: t)
                    drawHoldPopups(context, size: canvasSize, time: t)
                }
            }
            // Canvas already renders through SwiftUI's GPU-backed drawing path.
            // An additional full-screen drawingGroup creates an off-screen
            // surface for every display refresh; on physical devices that can
            // produce flashes and compete with the background compositor.
            // Keep the Canvas direct so only the pixels that changed are drawn.
            .onAppear {
                #if DEBUG
                print(String(format: "[Playfield] canvas %.1f x %.1f pt → lane width %.1f pt (W/4)",
                             geo.size.width, geo.size.height, geo.size.width / 4))
                #endif
            }
        }
    }

    // MARK: - Layout metrics

    private var approachTime: Double { engine.approachTime }
    /// Shared with the engine's spatial-catch math — the touch layer and the
    /// renderer can never drift apart.
    private var hitLineY: CGFloat { PlayfieldGeometry.hitLineY }
    private var topY: CGFloat { PlayfieldGeometry.topY }
    private func laneWidth(_ size: CGSize) -> CGFloat { size.width / CGFloat(laneCount) }
    /// Tiles fill ~96% of their lane — piano-key width, small even gap.
    private func tileWidth(_ size: CGSize) -> CGFloat { laneWidth(size) * 0.96 }
    /// Tile height as a fraction of the playfield HEIGHT (matching the
    /// engine's spatial-catch geometry), floored so tiny containers stay
    /// tappable.
    private func tileHeight(_ size: CGSize) -> CGFloat { max(60, size.height * PlayfieldGeometry.tileHeightFraction) }

    private func laneTop(_ lane: Int) -> Color { Self.lanePalette[lane].top }
    private func laneBottom(_ lane: Int) -> Color { Self.lanePalette[lane].bottom }

    /// Judgment → display color (shared by popups, rings and miss states).
    private static func judgmentColor(_ judgment: Judgment) -> Color {
        switch judgment {
        case .perfect: return Color(red: 1.0, green: 0.78, blue: 0.15)
        case .great: return Color(red: 0.25, green: 0.95, blue: 0.50)
        case .good: return Color(red: 0.20, green: 0.85, blue: 1.0)
        case .miss: return Color(red: 1.0, green: 0.30, blue: 0.28)
        }
    }

    // MARK: - Columns

    private func drawLanes(_ context: GraphicsContext, size: CGSize) {
        // Whisper-light wash only — the bright blue→purple/pink reference
        // gradient is the field now; a faint white veil keeps pure-black
        // tiles perfectly readable without gray-washing the room.
        let wash = Gradient(colors: [
            .white.opacity(0.07),
            .white.opacity(0.11),
            .white.opacity(0.13),
            .white.opacity(0.09)
        ])
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(wash,
                                           startPoint: CGPoint(x: 0, y: 0),
                                           endPoint: CGPoint(x: 0, y: size.height)))

        // Thin crisp column dividers (reference look): no glow strips, just
        // clean white lines separating the four columns.
        let width = laneWidth(size)
        for boundary in 0...laneCount {
            let x = CGFloat(boundary) * width
            let isEdge = boundary == 0 || boundary == laneCount
            let coreWidth: CGFloat = 1.4
            let coreX = isEdge ? (boundary == 0 ? 0 : x - coreWidth) : x - coreWidth / 2
            context.fill(Path(CGRect(x: coreX, y: 0, width: coreWidth, height: size.height)),
                         with: .color(.white.opacity(isEdge ? 0.30 : 0.38)))
        }
    }

    // MARK: - Notes

    private func drawNotes(_ context: GraphicsContext, size: CGSize, time: Double) {
        let width = laneWidth(size)
        let noteWidth = tileWidth(size)
        let noteHeight = tileHeight(size)
        let hitY = size.height * hitLineY
        let top = size.height * topY
        let travel = max(1, hitY - top)

        for item in engine.visibleNotes(at: time) {
            let note = item.note
            // The absolute-time profile is the only movement equation used by
            // the renderer. It integrates a positive speed curve, so changing
            // section speed cannot reposition an existing tile backward.
            let progress = engine.visualProgress(noteTime: note.time, at: time)
            let closeness = min(1, max(0, 1 - progress))
            let x = CGFloat(note.lane) * width + (width - noteWidth) / 2

            if note.type == .hold {
                let tailProgress = engine.visualProgress(noteTime: note.time + note.duration, at: time)
                drawHold(context, note: note, judged: item.judged, time: time,
                         x: x, width: noteWidth, hitY: hitY, travel: travel,
                         headProgress: progress, tailProgress: tailProgress)
                continue
            }
            // Fast reject: unjudged taps only render near their window. A
            // judged tap bypasses this — its hit effect runs on its own fixed
            // 80–150 ms clock, independent of travel speed.
            guard item.judged != nil || (progress > -0.05 && progress < 1.02) else { continue }

            let bottomY = hitY - CGFloat(progress) * travel
            let rect = CGRect(x: x, y: bottomY - noteHeight, width: noteWidth, height: noteHeight)
            // Reference tiles have small, nearly-sharp corners.
            let corner = min(6, noteWidth * 0.06)
            let path = Path(roundedRect: rect, cornerRadius: corner)

            switch item.judged {
            case .miss:
                break   // drawn in the effects pass (above the hit shelf)
            case .some(let judgment):
                drawHitTile(context, lane: note.lane, judgment: judgment,
                            judgedAt: item.judgedAt, time: time, hitY: hitY,
                            rect: rect, corner: corner)
            case nil:
                drawTapBody(context, lane: note.lane, path: path, rect: rect,
                            corner: corner, closeness: closeness, strength: note.strength)
            }
        }
    }

    /// Missed TAP tiles: rendered in the effects pass so the ~140 ms red
    /// flash + collapse is never hidden under the seating-shelf overlay.
    private func drawMissTiles(_ context: GraphicsContext, size: CGSize, time: Double) {
        let width = laneWidth(size)
        let noteWidth = tileWidth(size)
        let noteHeight = tileHeight(size)
        let hitY = size.height * hitLineY
        let top = size.height * topY
        let travel = max(1, hitY - top)
        for item in engine.visibleNotes(at: time) {
            guard item.judged == .miss, item.note.type != .hold else { continue }
            let note = item.note
            let progress = engine.visualProgress(noteTime: note.time, at: time)
            let x = CGFloat(note.lane) * width + (width - noteWidth) / 2
            let bottomY = hitY - CGFloat(progress) * travel
            let rect = CGRect(x: x, y: bottomY - noteHeight, width: noteWidth, height: noteHeight)
            drawMissTile(context, lane: note.lane, judgedAt: item.judgedAt,
                         time: time, rect: rect, corner: min(6, noteWidth * 0.06))
        }
    }

    /// A missed tap: a fixed ~140 ms MISS state — strong red flash, then the
    /// tile collapses (shrink) while fading, then it is gone. A missed note
    /// is never hittable (the scheduler only matches unjudged notes), so this
    /// is purely the visible "you missed" communication.
    private func drawMissTile(_ context: GraphicsContext, lane: Int, judgedAt: Double?,
                              time: Double, rect: CGRect, corner: CGFloat) {
        let start = judgedAt ?? time
        let age = time - start
        // Effect over (or not started) → the tile is not drawn at all.
        guard MissTileTiming.progress(age: age) != nil else { return }

        let collapse = CGFloat(MissTileTiming.collapse(age: age))
        let fade = CGFloat(MissTileTiming.fade(age: age))
        let flash = CGFloat(MissTileTiming.flash(age: age))
        // Shrink toward the tile center; skip the degenerate last pixel.
        let dx = rect.width * collapse / 2
        let dy = rect.height * collapse / 2
        guard rect.width - 2 * dx > 1, rect.height - 2 * dy > 1 else { return }
        let body = Path(roundedRect: rect.insetBy(dx: dx, dy: dy),
                        cornerRadius: max(1, corner * (1 - collapse)))
        // Desaturated red body, fading out as it collapses.
        let gradient = Gradient(colors: [
            Color(red: 0.85, green: 0.10, blue: 0.08).opacity(0.95 * fade),
            Color(red: 0.45, green: 0.03, blue: 0.03).opacity(0.95 * fade)
        ])
        context.fill(body, with: .linearGradient(gradient,
                                                 startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                 endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        // Strong red flash right at the declaration.
        if flash > 0 {
            context.fill(body, with: .color(.red.opacity(0.8 * flash)))
        }
        context.stroke(body, with: .color(.white.opacity(0.35 * fade)), lineWidth: 1.2)
    }

    /// A judged tap: a fixed 80–150 ms HIT state, then removal.
    ///
    /// Phase 1 (0–100 ms): the tile visibly PRESSES — vertical compression
    /// growing to ~14% — while flashing full lane color with a white-hot
    /// core, and a white reference beam + ring shoots from the tile down to
    /// the hit line. Phase 2 (100–160 ms): a quick fade with a slight rise,
    /// then the tile is gone. Score/combo/haptics already fired synchronously
    /// at touch-down in the engine; this is purely visual.
    private func drawHitTile(_ context: GraphicsContext, lane: Int, judgment: Judgment,
                             judgedAt: Double?, time: Double, hitY: CGFloat,
                             rect: CGRect, corner: CGFloat) {
        let start = judgedAt ?? time
        let age = time - start
        // Effect over (or not started) → the tile is not drawn at all.
        guard HitTileTiming.progress(age: age) != nil else { return }

        let press: CGFloat = CGFloat(HitTileTiming.compression(age: age))
        let fade: CGFloat = CGFloat(HitTileTiming.fade(age: age))
        if age < HitTileTiming.pressDuration {
            // HIT: press in (vertical compression), full lane flash, white
            // core, expanding glow.
            let pressed = rect.insetBy(dx: 0, dy: rect.height * press / 2)
            // Expanding halo behind the tile.
            let pressFrac = CGFloat(age / HitTileTiming.pressDuration)
            let glowSpread = 6 + pressFrac * 12
            let halo = Path(roundedRect: rect.insetBy(dx: -glowSpread, dy: -glowSpread * 0.6),
                            cornerRadius: corner + 8)
            context.fill(halo, with: .color(laneTop(lane).opacity(0.38 * (1 - pressFrac))))
            // Full lane-color flash body.
            let flash = Path(roundedRect: pressed, cornerRadius: corner)
            let gradient = Gradient(colors: [laneTop(lane), laneBottom(lane)])
            context.fill(flash, with: .linearGradient(gradient,
                                                      startPoint: CGPoint(x: pressed.midX, y: pressed.minY),
                                                      endPoint: CGPoint(x: pressed.midX, y: pressed.maxY)))
            // White-hot core, strongest right at the tap.
            context.fill(flash, with: .color(.white.opacity(0.72 * (1 - pressFrac))))
            // Reference beam: white light + impact ring from the tile down
            // to the hit line — the signature reaction of the inspiration.
            let beamAlpha = (1 - pressFrac) * 0.8
            var beam = Path()
            beam.move(to: CGPoint(x: pressed.midX, y: pressed.maxY))
            beam.addLine(to: CGPoint(x: pressed.midX, y: hitY))
            context.stroke(beam, with: .color(.white.opacity(beamAlpha)),
                           style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            let ringR = 6 + pressFrac * 9
            var impact = Path()
            impact.addEllipse(in: CGRect(x: pressed.midX - ringR, y: hitY - ringR,
                                         width: ringR * 2, height: ringR * 2))
            context.stroke(impact, with: .color(.white.opacity(0.9 * (1 - pressFrac))), lineWidth: 2.4)
        } else {
            // Release: quick fade + slight rise, then gone.
            let rise = CGFloat(age - HitTileTiming.pressDuration) * 46
            let releasing = rect.offsetBy(dx: 0, dy: -rise)
            let body = Path(roundedRect: releasing, cornerRadius: corner)
            context.fill(body, with: .color(laneTop(lane).opacity(0.85 * fade)))
            context.stroke(body, with: .color(.white.opacity(0.45 * fade)), lineWidth: 1.5)
        }
    }

    /// Reference tile: solid black piano key with small, nearly-sharp
    /// corners and a whisper of depth. No halo, no rim, no cap — contrast
    /// comes from the bright gradient field behind it. Lane identity lives
    /// in the hit feedback (flash/beam), not in the resting tile.
    private func drawTapBody(_ context: GraphicsContext, lane: Int, path: Path, rect: CGRect,
                             corner: CGFloat, closeness: Double, strength: Double) {
        _ = (lane, closeness, strength)
        let bodyGradient = Gradient(colors: [
            Color(red: 0.095, green: 0.095, blue: 0.12),
            Color(red: 0.015, green: 0.015, blue: 0.028)
        ])
        context.fill(path, with: .linearGradient(bodyGradient,
                                                 startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                 endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        // Faint top sheen so the key separates from the black lanes below.
        let sheen = Path(roundedRect: CGRect(x: rect.minX + 5, y: rect.minY + 3,
                                             width: rect.width - 10, height: rect.height * 0.10),
                         cornerRadius: corner * 0.5)
        context.fill(sheen, with: .color(.white.opacity(0.05)))
    }

    /// A hold in the reference style: a long black tile whose length IS the
    /// duration, with a white center beam and a ring at the tail (the
    /// release point). Sustaining fills the consumed portion of the tile with
    /// lane color — the visible fill equals the fraction actually held
    /// (0…1 of the note's own span), so partial holds read honestly.
    ///
    /// All decorations (tail ring, boundary marker) are CLAMPED INSIDE the
    /// tile body: the old ring was stroked at `rect.maxY` with an unclamped
    /// radius, so it visibly poked below the tile onto the lane.
    private func drawHold(_ context: GraphicsContext, note: ChartNote, judged: Judgment?,
                          time: Double, x: CGFloat, width: CGFloat,
                          hitY: CGFloat, travel: CGFloat,
                          headProgress: Double, tailProgress: Double) {
        // The hold disappears exactly when its musical tail reaches the hit
        // line. There is no post-line hold animation: completion feedback is
        // handled by the engine's lane flash/popup, so the long tile cannot
        // continue moving or flash below the playfield after its endpoint.
        guard headProgress < 1.02, tailProgress >= 0 else { return }

        // Once the head reaches the catch line it is consumed there. Clamping
        // its projection prevents the body/fill from continuing below the line
        // while the tail is still travelling through a dynamic-speed region.
        let visibleHeadProgress = max(0, headProgress)
        let visibleTailProgress = max(0, tailProgress)
        if engine.holdCompleted(id: note.id) {
            return
        }

        let topY = hitY - CGFloat(visibleHeadProgress) * travel
        let bottomY = hitY - CGFloat(visibleTailProgress) * travel
        let rect = CGRect(x: x, y: min(topY, bottomY), width: width,
                          height: max(14, abs(bottomY - topY)))
        let corner = min(6, width * 0.06)
        let path = Path(roundedRect: rect, cornerRadius: corner)

        if judged == .miss {
            context.fill(path, with: .color(.red.opacity(0.5)))
            return
        }

        if engine.holdActive(id: note.id) {
            drawActiveHold(context, note: note, rect: rect, corner: corner,
                           hitY: hitY, travel: travel, time: time)
            return
        }

        // Released early: briefly show the honest fraction achieved before
        // the tile fades out of view.
        if let partial = engine.recordedHoldProgress(id: note.id), partial > 0, partial < 1 {
            let fillFraction = CGFloat(partial)
            let fillRect = CGRect(x: rect.minX,
                                  y: rect.maxY - rect.height * fillFraction,
                                  width: rect.width,
                                  height: rect.height * fillFraction)
            context.fill(path, with: .color(Color(red: 0.095, green: 0.095, blue: 0.12).opacity(0.5)))
            if fillRect.height >= 2 {
                context.fill(Path(roundedRect: fillRect, cornerRadius: corner),
                             with: .color(laneTop(note.lane).opacity(0.55)))
            }
            return
        }

        // Falling, unjudged: black tile + white center beam + tail ring
        // (the reference's long-note look).
        if headProgress > 1 { return }          // head not spawned yet
        let gradient = Gradient(colors: [
            Color(red: 0.095, green: 0.095, blue: 0.12),
            Color(red: 0.015, green: 0.015, blue: 0.028)
        ])
        context.fill(path, with: .linearGradient(gradient,
                                                 startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                 endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        // White beam down the center of the lane, inset from the body edges.
        var beam = Path()
        beam.move(to: CGPoint(x: rect.midX, y: rect.minY + 3))
        beam.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 3))
        context.stroke(beam, with: .color(.white.opacity(0.72)),
                       style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        // Ring at the tail (the release point) — clamped INSIDE the body.
        drawClampedTailRing(context, midX: rect.midX, tailY: rect.maxY,
                            width: width, bodyTop: rect.minY, bodyBottom: rect.maxY,
                            radius: width * 0.16)
        // Faint sheen so the long key separates from the black lanes.
        let sheen = Path(roundedRect: CGRect(x: rect.minX + 5, y: rect.minY + 3,
                                             width: rect.width - 10, height: max(6, rect.height * 0.08)),
                         cornerRadius: corner * 0.5)
        context.fill(sheen, with: .color(.white.opacity(0.05)))
    }

    /// Sustain visualization: the fraction of the hold genuinely consumed
    /// fills with lane color from the BOTTOM (the head) upward. The fill
    /// boundary — and the release ring riding it — both stay inside the
    /// tile body, so nothing bleeds onto the lane below.
    private func drawActiveHold(_ context: GraphicsContext, note: ChartNote,
                                rect: CGRect, corner: CGFloat,
                                hitY: CGFloat, travel: CGFloat, time: Double) {
        // The fill is projected from timestamps, not from a frame counter or
        // a constant pixels-per-second animation. This keeps it locked to the
        // same integrated DynamicSpeedProfile as the hold head and tail.
        // Fill follows the integrated spatial path through the same Dynamic
        // Speed profile as the head and tail. Scoring still uses the separate
        // authoritative musical-time fraction in the engine; this visual
        // fraction is what makes a slow → fast → slow hold look continuous
        // instead of advancing at a static speed.
        // The visual fill begins at the physical press, including a body press
        // made before the chart head reaches the bottom line. The scored hold
        // interval still begins at the chart head, so this changes only the
        // feedback animation—not note timing, release tolerance, or bonus math.
        let visualFraction = min(1, max(0, engine.holdVisualProgress(
            lane: note.lane, at: time) ?? 0))
        // Once the head has been caught it has passed the hit line and its
        // projected bottom is below the playable field. Anchoring the fill to
        // `rect.maxY` therefore hid the first part of the hold animation below
        // the line; the player saw no progress until the tail arrived. The
        // visible hold is anchored at the hit line, while its logical progress
        // still comes from the authoritative audio clock.
        let fillMaxY = min(rect.maxY, hitY)
        let fillMinY = max(rect.minY, fillMaxY - rect.height * CGFloat(visualFraction))
        let fillHeight = max(0, fillMaxY - fillMinY)
        // Unconsumed remainder above the fill keeps the black piano look.
        let bodyGradient = Gradient(colors: [
            Color(red: 0.095, green: 0.095, blue: 0.12),
            Color(red: 0.015, green: 0.015, blue: 0.028)
        ])
        context.fill(Path(roundedRect: rect, cornerRadius: corner),
                     with: .linearGradient(bodyGradient,
                                           startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                           endPoint: CGPoint(x: rect.midX, y: rect.maxY)))

        // The consumed fill: from the head (bottom) up to the boundary.
        let pulse = 0.8 + 0.2 * sin(time * 14)
        if fillHeight >= 2 {
            let fillRect = CGRect(x: rect.minX,
                                  y: fillMinY,
                                  width: rect.width,
                                  height: fillHeight)
            // Clip to the rounded body so corners never leak.
            var clipped = context
            clipped.clip(to: Path(roundedRect: rect, cornerRadius: corner))
            let gradient = Gradient(colors: [laneTop(note.lane).opacity(0.9 + 0.1 * pulse),
                                             laneBottom(note.lane).opacity(0.95 * pulse)])
            clipped.fill(Path(fillRect), with: .linearGradient(gradient,
                                                               startPoint: CGPoint(x: fillRect.midX, y: fillRect.minY),
                                                               endPoint: CGPoint(x: fillRect.midX, y: fillRect.maxY)))
            clipped.fill(Path(fillRect), with: .color(.white.opacity(0.10)))
            // Progress boundary marker riding the fill edge (inside the body).
            let markerY = fillRect.minY
            let marker = CGRect(x: rect.minX, y: markerY - 1.5, width: rect.width, height: 3)
            context.fill(Path(roundedRect: marker, cornerRadius: 1.5),
                         with: .color(.white.opacity(0.95)))
            // Release ring rides the boundary — clamped inside the tile.
            drawClampedTailRing(context, midX: rect.midX, tailY: markerY,
                                width: rect.width, bodyTop: rect.minY, bodyBottom: rect.maxY,
                                radius: rect.width * 0.16 * (1 + 0.15 * pulse))
        }
        // Crisp outline so the active hold reads as ONE object.
        context.stroke(Path(roundedRect: rect, cornerRadius: corner),
                       with: .color(.white.opacity(0.65)), lineWidth: 1.4)
    }

    /// White ring marker at a hold's tail, clamped entirely inside the tile
    /// body. `tailY` is the ideal ring center; the drawn circle is pushed up
    /// so it never extends past `bodyBottom` (the head end) or above
    /// `bodyTop` — the old unclamped ring visibly sat outside the tile.
    private func drawClampedTailRing(_ context: GraphicsContext, midX: CGFloat,
                                     tailY: CGFloat, width: CGFloat,
                                     bodyTop: CGFloat, bodyBottom: CGFloat,
                                     radius: CGFloat) {
        // Keep the entire ring inside the body. A stroke is centered on the
        // ellipse path, so leave the full radius of clearance—not the old
        // half-radius heuristic that visibly let the circle sit outside the
        // tile at the hit line.
        let bodyHeight = max(0, bodyBottom - bodyTop)
        let r = min(radius, width * 0.28, max(1, bodyHeight * 0.45))
        let maxCenter = bodyBottom - r
        let minCenter = bodyTop + r
        let cy = min(max(tailY, minCenter), maxCenter)
        guard bodyHeight >= 2 * r, maxCenter >= minCenter else { return }
        var ring = Path()
        ring.addEllipse(in: CGRect(x: midX - r, y: cy - r, width: r * 2, height: r * 2))
        context.stroke(ring, with: .color(.white.opacity(0.9)), lineWidth: 2.2)
    }

    // MARK: - Debug lane boundaries (DEBUG-only visual)

    /// Ground-truth lane geometry overlay, drawn FROM THE CANVAS SIZE ITSELF:
    /// full-height boundary lines at 0, W/4, W/2, 3W/4 and W, an L0…L3 label
    /// in each lane center, and the measured playfield/lane widths. If these
    /// lines don't span the display edge-to-edge with four equal cells, the
    /// canvas is being given the wrong width — everything above this layer
    /// (touch mapping, hit zone, tiles) uses the exact same numbers.
    #if DEBUG
    private func drawLaneBoundaries(_ context: GraphicsContext, size: CGSize) {
        let width = size.width / 4
        for boundary in 0...4 {
            let x = CGFloat(boundary) * width
            let isEdge = boundary == 0 || boundary == 4
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.white.opacity(isEdge ? 0.95 : 0.65)),
                           style: StrokeStyle(lineWidth: 3,
                                              dash: isEdge ? [] : [12, 8]))
        }
        for lane in 0..<4 {
            let cx = (CGFloat(lane) + 0.5) * width
            let label = Text("L\(lane)")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            context.draw(label, at: CGPoint(x: cx, y: size.height * 0.10), anchor: .center)
        }
        let info = Text("Playfield W: \(Int(size.width))  ·  Lane W: \(Int(width))  ·  lanes: \(laneCount) × \(Int(width * 4))")
            .font(.system(size: 15, weight: .bold).monospaced())
            .foregroundStyle(.white)
        context.draw(info, at: CGPoint(x: size.width / 2, y: size.height * 0.045), anchor: .center)
    }
    #endif

    // MARK: - Debug chart structure (DEBUG-only visual)

    /// Developer visualization: section boundaries (full-height colored
    /// lines), the beat grid (white ticks down the LEFT edge), onset/event
    /// energy (dots down the RIGHT edge), and each chart note's target
    /// position at the hit line (lane-colored ticks). Beats/events flow with
    /// the same audio-clock math as tiles, so it immediately shows whether
    /// the analyzer, generator or renderer is wrong.
    private func drawChartStructure(_ context: GraphicsContext, size: CGSize, time: Double) {
        let width = laneWidth(size)
        let hitY = size.height * hitLineY
        let top = size.height * topY
        let travel = max(1, hitY - top)

        func projectY(_ t: Double) -> CGFloat {
            hitY - CGFloat(engine.visualProgress(noteTime: t, at: time)) * travel
        }

        #if DEBUG
        // Section boundaries: vertical colored lines at each section start.
        for (i, section) in engine.debugSections.enumerated() {
            let color = Self.lanePalette[i % 4].top.opacity(0.55)
            let y = projectY(section.start)
            // Only draw boundaries that are on screen.
            guard y >= -4, y <= size.height + 4 else { continue }
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(color),
                           style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
        }

        // Beats: white ticks down the left edge (progress follows audio clock).
        for beat in engine.debugBeats {
            let y = projectY(beat.time)
            guard y >= -4, y <= size.height + 4 else { continue }
            let x0: CGFloat = 3
            let x1: CGFloat = beat.isStrong ? 26 : 16
            var tick = Path()
            tick.move(to: CGPoint(x: x0, y: y))
            tick.addLine(to: CGPoint(x: x1, y: y))
            context.stroke(tick, with: .color(.white.opacity(beat.isStrong ? 0.9 : 0.55)),
                           style: StrokeStyle(lineWidth: beat.isStrong ? 3 : 1.6, lineCap: .round))
        }

        // Events/onsets: dots down the right edge, sized by strength.
        for event in engine.debugEvents {
            let y = projectY(event.time)
            guard y >= -4, y <= size.height + 4 else { continue }
            let r: CGFloat = 3 + CGFloat(event.strength) * 4
            let cx = size.width - 12
            var dot = Path()
            dot.addEllipse(in: CGRect(x: cx - r, y: y - r, width: r * 2, height: r * 2))
            context.fill(dot, with: .color(.cyan.opacity(0.7)))
        }

        // Chart notes: lane-colored target ticks at the hit line, showing
        // exactly where each generated note is meant to be hit.
        for note in engine.debugChartNotes {
            let y = projectY(note.time)
            guard y >= -4, y <= size.height + 4 else { continue }
            let laneX = CGFloat(note.lane) * width + width / 2
            let c = Self.lanePalette[note.lane].top.opacity(0.95)
            if note.type == .hold {
                let ty = projectY(note.time + note.duration)
                var line = Path()
                line.move(to: CGPoint(x: laneX, y: min(y, ty)))
                line.addLine(to: CGPoint(x: laneX, y: max(y, ty)))
                context.stroke(line, with: .color(c), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            var tick = Path()
            tick.move(to: CGPoint(x: laneX - 7, y: y))
            tick.addLine(to: CGPoint(x: laneX + 7, y: y))
            context.stroke(tick, with: .color(c), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        #endif
    }

    // MARK: - Hit region

    /// A clean catch zone: soft shelf at the bottom, a single crisp full-width
    /// hit line with a colored glow. No per-lane clutter.
    private func drawHitRegion(_ context: GraphicsContext, size: CGSize, time: Double) {
        let y = size.height * hitLineY
        _ = time
        // Gentle seating shelf under the line (kept light — the reference
        // field stays bright).
        let shelf = Gradient(colors: [.black.opacity(0.16), .black.opacity(0.05)])
        let shelfRect = CGRect(x: 0, y: y - 6, width: size.width, height: size.height - (y - 6))
        context.fill(Path(shelfRect), with: .linearGradient(shelf,
                                                            startPoint: CGPoint(x: 0, y: y - 6),
                                                            endPoint: CGPoint(x: 0, y: size.height)))

        // Crisp full-width catch line with a slim cyan glow.
        var glow = Path()
        glow.move(to: CGPoint(x: 0, y: y + 3))
        glow.addLine(to: CGPoint(x: size.width, y: y + 3))
        context.stroke(glow, with: .color(.cyan.opacity(0.14)), lineWidth: 8)
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(line, with: .color(.white.opacity(0.85)), lineWidth: 2)
        context.stroke(line, with: .color(.cyan.opacity(0.45)), lineWidth: 4)
    }

    // MARK: - Effects

    private func drawLaneFlashes(_ context: GraphicsContext, size: CGSize, time: Double) {
        let width = laneWidth(size)
        for flash in engine.laneFlashes {
            let age = time - flash.time
            guard age >= 0, age < 0.24 else { continue }
            let alpha = (1 - age / 0.24) * 0.30 * flash.intensity
            let rect = CGRect(x: CGFloat(flash.lane) * width, y: 0, width: width, height: size.height)
            context.fill(Path(rect), with: .color(laneTop(flash.lane).opacity(alpha)))
        }
    }

    /// Expanding judgment ring + core flash at the hit point (per lane).
    private func drawBursts(_ context: GraphicsContext, size: CGSize, time: Double) {
        let width = laneWidth(size)
        let hitY = size.height * hitLineY
        for item in engine.feedback {
            let age = time - item.time
            guard age >= 0, age < 0.42 else { continue }
            guard item.judgment != .miss else { continue }
            let cx = CGFloat(item.lane) * width + width / 2
            let color = Self.judgmentColor(item.judgment)
            // Expanding ring.
            let radius = 16 + CGFloat(age) * 130
            let ringAlpha = (1 - age / 0.42) * 0.55
            var ring = Path()
            ring.addEllipse(in: CGRect(x: cx - radius, y: hitY - radius, width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(color.opacity(ringAlpha)), lineWidth: 3.5)
            // Core flash that fades fast.
            let core = 30 * (1 - age / 0.16)
            if core > 0 {
                var flash = Path()
                flash.addEllipse(in: CGRect(x: cx - core, y: hitY - core, width: core * 2, height: core * 2))
                context.fill(flash, with: .color(color.opacity(0.35 * (1 - age / 0.16))))
            }
        }
    }

    /// Non-miss judgments: ONE large glowing centered text (like the
    /// reference), deduped per simultaneous chord hit. Sits right under the
    /// score box near the top, drifting up as it fades.
    private func drawFeedback(_ context: GraphicsContext, size: CGSize, time: Double) {
        // Group simultaneous hits (same ~50 ms bucket); keep the best judgment.
        let buckets = Dictionary(grouping: engine.feedback, by: { Int(($0.time * 20).rounded()) })
        for key in buckets.keys.sorted() {
            guard let group = buckets[key] else { continue }
            let best = group.max { Self.rank($0.judgment) < Self.rank($1.judgment) }!
            guard best.judgment != .miss else { continue }
            let age = time - best.time
            guard age >= 0, age < 0.75 else { continue }
            let color = Self.judgmentColor(best.judgment)
            let label = best.judgment.displayName.uppercased()
            let baseSize: CGFloat = best.judgment == .perfect ? 46
                : best.judgment == .great ? 36 : 29
            let opacity = age < 0.6 ? 1.0 : max(0, 1.0 - (age - 0.6) / 0.15)
            let scale: CGFloat = 1 + max(0, 0.55 - CGFloat(age) * 4.2)

            // Reference placement: centered right under the score box, near
            // the top of the field, drifting up slightly as it fades.
            let cx = size.width / 2
            let cy = size.height * 0.155 - CGFloat(age) * 30

            // Sparkles around PERFECT/GREAT popups.
            if best.judgment != .good {
                let sparkleAlpha = (1 - age / 0.55) * 0.9
                for i in 0..<6 {
                    let angle = Double(i) / 6 * .pi * 2 + 0.5 * sin(age * 8 + Double(i))
                    let dist = 30 + CGFloat(age) * 110 + CGFloat(i % 3) * 12
                    let sx = cx + cos(angle) * dist
                    let sy = cy - sin(angle) * dist * 0.55
                    let len: CGFloat = 4 + CGFloat(i % 2) * 2
                    var cross = Path()
                    cross.move(to: CGPoint(x: sx - len, y: sy))
                    cross.addLine(to: CGPoint(x: sx + len, y: sy))
                    cross.move(to: CGPoint(x: sx, y: sy - len))
                    cross.addLine(to: CGPoint(x: sx, y: sy + len))
                    context.stroke(cross, with: .color(.white.opacity(sparkleAlpha)),
                                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }

            let text = Text(label)
                .font(.system(size: baseSize, weight: .black, design: .rounded))
                .foregroundStyle(color.opacity(opacity))
            let outline = Text(label)
                .font(.system(size: baseSize, weight: .black, design: .rounded))
                .foregroundStyle(.black.opacity(0.30 * opacity))

            var layer = context
            layer.translateBy(x: cx, y: cy)
            layer.scaleBy(x: scale, y: scale)
            layer.translateBy(x: -cx, y: -cy)
            for offset in [(2.2, 3.0), (-2.2, 3.0), (0, 4.2), (2.2, 1.0), (-2.2, 1.0)] {
                layer.draw(outline, at: CGPoint(x: cx + offset.0, y: cy + offset.1), anchor: .center)
            }
            layer.draw(text, at: CGPoint(x: cx, y: cy), anchor: .center)
            // Soft colored bloom behind the label.
            if best.judgment == .perfect || best.judgment == .great {
                let bloom = Text(label)
                    .font(.system(size: baseSize, weight: .black, design: .rounded))
                    .foregroundStyle(color.opacity(0.22 * opacity))
                layer.draw(bloom, at: CGPoint(x: cx + 2.5, y: cy + 2.5), anchor: .center)
            }
        }
    }

    /// Miss popups stay where the miss happened (per lane) so the player
    /// knows exactly which column was missed.
    private func drawMisses(_ context: GraphicsContext, size: CGSize, time: Double) {
        let width = laneWidth(size)
        let hitY = size.height * hitLineY
        for item in engine.feedback {
            guard item.judgment == .miss else { continue }
            let age = time - item.time
            guard age >= 0, age < 0.55 else { continue }
            let x = CGFloat(item.lane) * width + width / 2
            let y = hitY - 96 - CGFloat(age) * 90
            let color = Self.judgmentColor(.miss)
            let label = "MISS"
            let opacity = age < 0.42 ? 1.0 : max(0, 1.0 - (age - 0.42) / 0.13)
            let scale: CGFloat = 1 + max(0, 0.35 - CGFloat(age) * 3.0)
            let text = Text(label)
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundStyle(color.opacity(opacity))
            let outline = Text(label)
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundStyle(.black.opacity(0.4 * opacity))
            var layer = context
            layer.translateBy(x: x, y: y)
            layer.scaleBy(x: scale, y: scale)
            layer.translateBy(x: -x, y: -y)
            layer.draw(outline, at: CGPoint(x: x + 1.6, y: y + 2.2), anchor: .center)
            layer.draw(text, at: CGPoint(x: x, y: y), anchor: .center)
        }
    }

    private static func rank(_ judgment: Judgment) -> Int {
        switch judgment {
        case .perfect: return 3
        case .great: return 2
        case .good: return 1
        case .miss: return 0
        }
    }

    /// "+500 HOLD" bonus popups when a hold is sustained to its tail.
    private func drawHoldPopups(_ context: GraphicsContext, size: CGSize, time: Double) {
        let width = laneWidth(size)
        let hitY = size.height * hitLineY
        for popup in engine.holdPopups {
            let age = time - popup.time
            guard age >= 0, age < 0.75 else { continue }
            let x = CGFloat(popup.lane) * width + width / 2
            let y = hitY - 96 - CGFloat(age) * 130
            let opacity = age < 0.6 ? 1.0 : 1.0 - (age - 0.6) / 0.15
            let label = "+\(popup.points) HOLD"
            let color = Color(red: 0.75, green: 1.0, blue: 0.45)
            let text = Text(label)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(color.opacity(opacity))
            let outline = Text(label)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.black.opacity(0.55 * opacity))
            var layer = context
            layer.translateBy(x: x, y: y)
            layer.scaleBy(x: 1 + max(0, 0.3 - CGFloat(age) * 2.5), y: 1 + max(0, 0.3 - CGFloat(age) * 2.5))
            layer.translateBy(x: -x, y: -y)
            layer.draw(outline, at: CGPoint(x: x + 1.5, y: y + 2), anchor: .center)
            layer.draw(text, at: CGPoint(x: x, y: y), anchor: .center)
        }
    }
}

/// Transparent whole-lane touch target. Any touch in the lane is eligible — no
/// pixel-perfect aiming. Reports the normalized touch position immediately on
/// touch-DOWN (not on tap-up), so judgment never waits for a gesture to end;
/// touch-UP is reported so holds can complete or miss.
struct LaneInputView: View {
    let lane: Int
    let onTouchDown: (CGPoint) -> Void   // normalized (0…1) within the lane
    var onTouchUp: (() -> Void)? = nil
    @State private var touched = false
    /// Uptime of the last touch event. Guards against a lost touch-UP: if the
    /// system swallows the gesture's end (interruption, cancellation), the
    /// lane would otherwise stay "touched" forever and silently refuse input.
    /// A new touch arriving long after the last event is treated as a fresh
    /// gesture even if the previous end was never delivered.
    @State private var lastTouchUptime: Double = 0

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onAppear {
                    #if DEBUG
                    print(String(format: "[Input] lane %d width=%.1fpt (expected container/4)",
                                 lane, geo.size.width))
                    #endif
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            let now = ProcessInfo.processInfo.systemUptime
                            if touched, now - lastTouchUptime > 0.35 {
                                touched = false   // previous end was swallowed
                            }
                            guard !touched, geo.size.width > 0, geo.size.height > 0 else { return }
                            touched = true
                            lastTouchUptime = now
                            let fraction = CGPoint(x: min(1, max(0, value.location.x / geo.size.width)),
                                                   y: min(1, max(0, value.location.y / geo.size.height)))
                            onTouchDown(fraction)
                        }
                        .onEnded { _ in
                            touched = false
                            onTouchUp?()
                        }
                )
        }
        .accessibilityLabel(laneLabel)
        .accessibilityHint("Touch anywhere in this column to hit its notes.")
        .accessibilityAddTraits(.isButton)
        .onDisappear { touched = false }
    }

    /// Non-color lane identity: position-based name so the game stays
    /// understandable without relying on the lane colors.
    private var laneLabel: String {
        switch lane {
        case 0: return "Lane 1, leftmost column"
        case 1: return "Lane 2, second column from the left"
        case 2: return "Lane 3, second column from the right"
        default: return "Lane 4, rightmost column"
        }
    }
}
