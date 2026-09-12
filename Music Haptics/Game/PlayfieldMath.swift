import CoreGraphics
import Foundation

/// Pure touch→lane mapping and note-movement math, kept free of UI state so it
/// is unit-testable and shared by the input layer and the renderer.
enum InputGeometry {
    static let laneCount = 4

    /// Maps a touch X inside the playfield to a lane 0…3. The whole lane width
    /// is the hit target: any X within a lane belongs to that lane.
    static func lane(forX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        let lane = Int((x / width) * CGFloat(laneCount))
        return min(laneCount - 1, max(0, lane))
    }

    /// X of a lane's center.
    static func centerX(ofLane lane: Int, width: CGFloat) -> CGFloat {
        guard laneCount > 0 else { return 0 }
        let laneWidth = width / CGFloat(laneCount)
        return (CGFloat(lane) + 0.5) * laneWidth
    }

    /// Normalized progress of a note toward the hit line.
    /// `1` = spawned at top, `0` = exactly on the hit line.
    static func progress(noteTime: Double, currentAudioTime: Double, leadTime: Double) -> Double {
        guard leadTime > 0 else { return 0 }
        return (noteTime - currentAudioTime) / leadTime
    }
}

/// The fixed hit-effect clock for successfully judged tiles: an ~80–150 ms
/// HIT state (vertical compression + full lane flash + white core + expanding
/// halo), then removal. Kept as pure math so the renderer and its tests share
/// the exact same curve — the effect duration never depends on note travel
/// speed.
enum HitTileTiming {
    /// Press phase: compression grows to maxCompression over this window.
    static let pressDuration: Double = 0.10
    /// Total effect: the tile is removed at this age.
    static let totalDuration: Double = 0.16
    /// Peak vertical compression (fraction of tile height).
    static let maxCompression: Double = 0.14

    /// 0 = just hit, 1 = effect over; nil when the tile is gone (age < 0 or
    /// age >= totalDuration).
    static func progress(age: Double) -> Double? {
        guard age >= 0, age < totalDuration else { return nil }
        return age / totalDuration
    }

    /// Vertical compression factor (0…maxCompression). Grows through the
    /// press phase, then holds at the peak until removal.
    static func compression(age: Double) -> Double {
        guard age >= 0, age < pressDuration else { return age < 0 ? 0 : maxCompression }
        return (age / pressDuration) * maxCompression
    }

    /// Release-phase fade (1 → 0). 1 throughout the press phase, 0 at/after
    /// removal.
    static func fade(age: Double) -> Double {
        guard age >= 0, age < totalDuration else { return 0 }
        guard age < pressDuration else {
            return 1 - (age - pressDuration) / (totalDuration - pressDuration)
        }
        return 1
    }
}

/// The fixed miss-effect clock: a missed tap visibly collapses (shrink +
/// red flash + fade) over ~140 ms, then disappears — the player always SEES
/// the miss. Pure math shared by the renderer and its tests; the duration is
/// independent of note travel speed.
enum MissTileTiming {
    /// Total visible miss effect; the tile is removed at this age.
    static let duration: Double = 0.14
    /// Strong red flash over this leading window.
    static let flashDuration: Double = 0.05

    /// 0 = miss just declared, 1 = effect over; nil when the tile is gone.
    static func progress(age: Double) -> Double? {
        guard age >= 0, age < duration else { return nil }
        return age / duration
    }

    /// Collapse factor 0 (full size) → 1 (gone), linear over the effect.
    static func collapse(age: Double) -> Double {
        guard age >= 0 else { return 0 }
        guard age < duration else { return 1 }
        return age / duration
    }

    /// Overall fade 1 → 0, linear over the effect.
    static func fade(age: Double) -> Double {
        guard age >= 0, age < duration else { return 0 }
        return 1 - age / duration
    }

    /// Red flash intensity: 1 → 0 over the leading flash window.
    static func flash(age: Double) -> Double {
        guard age >= 0 else { return 0 }
        return max(0, 1 - age / flashDuration)
    }
}

/// Normalized playfield geometry shared by the renderer, the input layer and
/// the engine, so what you SEE and what gets HIT always agree. All values are
/// fractions of the full-screen playfield container.
enum PlayfieldGeometry {
    /// Y of the catch line (renderer draws it; input measures against it).
    static let hitLineY: Double = 0.875
    /// Y where notes spawn (travel spans topY → hitLineY).
    static let topY: Double = 0.03
    /// Tile height as a fraction of the playfield height (the renderer floors
    /// this at 60 pt for tiny containers).
    static let tileHeightFraction: Double = 0.115
    /// A touch within this many tile-heights of a note's visible tile is
    /// matched to that note spatially, then judged by timing.
    static let spatialCatchDistance: Double = 0.75
}

/// Spatial tap matching: where on the lane the finger landed, expressed as a
/// distance to a note's CURRENT on-screen tile (1.0 = exactly one tile-height
/// away). Pure math so the engine and tests share the exact same numbers.
enum SpatialCatch {
    /// Sentinel touch point meaning "no spatial intent" (autoplay,
    /// accessibility activation, synthetic taps). Takes the pure timing path.
    static let unspecifiedTouch = CGPoint(x: 0.5, y: 0.5)

    /// Normalized distance from a touch (at audio time `touchTime`, screen
    /// fraction `touchY`, where 1 = the hit line) to a note's VISIBLE TILE at
    /// the moment of the touch. Independent of lane — callers match lane
    /// first. Pass `holdTailTime` for hold notes so the whole visible tile
    /// (head → tail) counts as the touch target, not just the head.
    static func distance(noteTime: Double, touchTime: Double,
                         touchY: Double, leadTime: Double, hitLineY: Double,
                         topY: Double, tileHeightFraction: Double,
                         holdTailTime: Double? = nil) -> Double {
        let travel = max(0.0001, hitLineY - topY)
        // Screen fractions of the tile's bottom (head) and top (tail) at the
        // touch instant — the same projection the renderer uses.
        let headY = hitLineY - ((noteTime - touchTime) / leadTime) * travel
        let tailY = holdTailTime.map { hitLineY - ((min($0, noteTime + leadTime) - touchTime) / leadTime) * travel }
        // For taps: the tile is one tile-height tall; measure to its center.
        // For holds: measure to the NEAREST EDGE of the whole visible span,
        // so pressing anywhere on the long body registers (Magic Tiles 3
        // behavior), while a touch just above the tail still catches.
        if let tailY {
            let nearest = min(abs(touchY - headY), abs(touchY - tailY))
            let inside = (touchY <= headY && touchY >= tailY) || (touchY >= headY && touchY <= tailY)
            return inside ? 0 : nearest / tileHeightFraction
        } else {
            let noteCenterY = headY - tileHeightFraction / 2
            return abs(touchY - noteCenterY) / tileHeightFraction
        }
    }
}

/// BPM-aware note travel time, modeled on Magic Tiles 3: faster music shows
/// fewer BEATS on screen at once, so notes visually travel quicker and tiles
/// stay synced to what you hear. The user's note-speed setting sets the
/// spacing at 120 BPM; a 60-BPM ballad shows about twice as many beats on
/// screen (slower tiles), a 180-BPM banger fewer (faster tiles) — always
/// clamped so nothing becomes unreadable. Clamps scale WITH tempo so extreme
/// speeds never squash the whole range into one value.
enum NoteMovement {
    /// Anchor for the user's note-speed base (a 120 BPM song uses the base
    /// value as its travel time verbatim).
    static let anchorBPM = 120.0
    /// Readable floor/ceiling at the anchor; they scale with tempo above/below
    /// it (see `scaledClamps`), so a 200 BPM song can still travel under 1 s.
    static let minimumLeadTime = 0.75
    static let maximumLeadTime = 2.4
    /// How hard tempo scales the travel time. 0.8 means a 2× tempo change
    /// changes travel time by 2^0.8 ≈ 1.74× — a deliberate feel, not chaos.
    static let tempoExponent = 0.8

    /// Tempo-scaled readable bounds. Scales the anchor clamps by the same
    /// relative tempo so the playable range travels with the song instead of
    /// being crushed into a single clamped value at extreme tempos.
    static func scaledClamps(bpm: Double) -> (min: Double, max: Double) {
        let relative = bpm / anchorBPM
        return (minimumLeadTime / relative, maximumLeadTime / relative)
    }

    /// The lead time for a song at `bpm`. `nil`/implausible BPM falls back to
    /// the plain base value (clamped) — the song keeps a constant, readable
    /// travel speed instead of becoming unplayable.
    static func leadTime(bpm: Double?, base: Double) -> Double {
        guard let bpm, bpm > 20, bpm < 300 else {
            return min(max(base, minimumLeadTime), maximumLeadTime)
        }
        // Anchor at 120 BPM: 180 BPM songs travel ~1.7× faster than the base,
        // 60 BPM songs about half as fast — the Magic Tiles 3 feel.
        let relative = bpm / anchorBPM
        let scaled = base * pow(relative, -tempoExponent)
        let clamps = scaledClamps(bpm: bpm)
        return min(max(scaled, clamps.min), clamps.max)
    }

    // MARK: - Dynamic (per-moment) speed

    /// Subtlety of the per-moment speed modulation: at most ±12% around the
    /// song's base speed. Big enough to FEEL the music breathing (rubato,
    /// half-time switches, accelerandos), small enough that tile travel never
    /// becomes hard to read. The player's Note Speed setting always dominates.
    static let dynamicExcessFraction = 0.12
    /// How far ahead of `time` the lookup window reaches, as a fraction of the
    /// beat interval. 2 beats of context sees the groove, not individual hits.
    static let localWindowBeats = 2.0
    /// Below this beat interval the curve treats every moment as the same
    /// (300 BPM ≈ 200 ms — faster local variation is untrackable noise).
    static let localFloorBeatInterval = 0.2

    /// Lead time around audio time `t`: locally-detected tempo modulates the
    /// song's base speed, smoothed over a 2-beat window and limited to ±12%.
    /// Faster local tempo → shorter lead (tiles arrive sooner); slower local
    /// tempo → longer lead. Needs ≥ 4 beats in the window; otherwise the
    /// global constant speed is returned (no local knowledge = no fake
    /// dynamics).
    ///
    /// `globalBeatInterval` is the song's global beat length from the tempo
    /// analysis, so local tempo compares apples to apples.
    ///
    /// Used IDENTICALLY by the renderer's tile projection and the engine's
    /// spatial touch catch, so what you see is always what you hit.
    static func dynamicLeadTime(at time: Double, beats: [Beat],
                                globalBeatInterval: Double, baseLead: Double) -> Double {
        guard beats.count >= 4, globalBeatInterval.isFinite, globalBeatInterval > 0.01,
              baseLead.isFinite, baseLead > 0 else { return baseLead }
        var lo = 0, hi = beats.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        let startIdx = max(0, lo - 3)
        let reach = globalBeatInterval * localWindowBeats
        var endIdx = lo
        while endIdx < beats.count, beats[endIdx].time - time <= reach { endIdx += 1 }
        guard endIdx - startIdx >= 4 else { return baseLead }

        var intervals: [Double] = []
        intervals.reserveCapacity(endIdx - startIdx - 1)
        for i in (startIdx + 1)..<endIdx {
            let dt = beats[i].time - beats[i - 1].time
            if dt >= localFloorBeatInterval { intervals.append(dt) }
        }
        guard !intervals.isEmpty else { return baseLead }
        intervals.sort()
        let median = intervals.count % 2 == 1
            ? intervals[intervals.count / 2]
            : (intervals[intervals.count / 2 - 1] + intervals[intervals.count / 2]) / 2
        guard median.isFinite, median > 0 else { return baseLead }

        // Local tempo relative to global (BPM ratio = interval ratio inverted).
        // >1 = locally faster → shorter lead, mirroring leadTime(bpm:).
        let relativeTempo = globalBeatInterval / median
        let factor = pow(relativeTempo, -tempoExponent)
        let excess = min(dynamicExcessFraction, max(-dynamicExcessFraction, factor - 1))
        return baseLead * (1 + excess)
    }
}