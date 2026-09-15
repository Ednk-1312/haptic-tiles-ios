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
        guard leadTime.isFinite, leadTime > 0 else { return .infinity }
        let headProgress = (noteTime - touchTime) / leadTime
        let tailProgress = holdTailTime.map { ($0 - touchTime) / leadTime }
        return distance(headProgress: headProgress, tailProgress: tailProgress,
                        touchY: touchY, hitLineY: hitLineY, topY: topY,
                        tileHeightFraction: tileHeightFraction)
    }

    /// Distance overload for the absolute-time visual speed curve. The engine
    /// supplies already-integrated progress values, so input uses the exact
    /// same monotonic projection as the renderer even when visual speed is
    /// changing through a section.
    static func distance(headProgress: Double, tailProgress: Double?,
                         touchY: Double, hitLineY: Double,
                         topY: Double, tileHeightFraction: Double) -> Double {
        guard headProgress.isFinite, touchY.isFinite,
              tileHeightFraction.isFinite, tileHeightFraction > 0 else { return .infinity }
        let travel = max(0.0001, hitLineY - topY)
        let headY = hitLineY - headProgress * travel
        if let tailProgress, tailProgress.isFinite {
            let tailY = hitLineY - tailProgress * travel
            let nearest = min(abs(touchY - headY), abs(touchY - tailY))
            let inside = (touchY <= headY && touchY >= tailY)
                || (touchY >= headY && touchY <= tailY)
            return inside ? 0 : nearest / tileHeightFraction
        }
        let noteCenterY = headY - tileHeightFraction / 2
        return abs(touchY - noteCenterY) / tileHeightFraction
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

/// User-selectable amount of section-aware visual speed variation.
/// The setting changes presentation only; the chart/audio timeline and scoring
/// remain unchanged.
enum DynamicSpeedIntensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case subtle
    case standard
    case expressive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .subtle: return "Subtle"
        case .standard: return "Standard"
        case .expressive: return "Expressive"
        }
    }

    var description: String {
        switch self {
        case .subtle: return "Small changes that keep the field calm"
        case .standard: return "Musical changes that follow sections and intensity"
        case .expressive: return "A stronger contrast between relaxed and intense sections"
        }
    }

    /// Maximum section-derived variation around the difficulty's stable speed.
    /// These are intentionally bounded; the song never controls scoring timing.
    var variation: Double {
        switch self {
        case .subtle: return 0.06
        case .standard: return 0.12
        case .expressive: return 0.18
        }
    }
}

/// Deterministic, pre-game chart analysis used by every device. It converts
/// note density, chord density, and optional section energy/labels into a
/// smoothed normalized intensity curve. No audio or network work is done
/// here, and the result is sampled—not regenerated—during gameplay.
enum StandardMathIntensityAnalyzer {
    struct Point: Sendable, Equatable {
        let time: Double
        let intensity: Double
    }

    /// Produces broad section-sized samples rather than reacting to individual
    /// notes. This keeps isolated chart noise from creating visible speed
    /// oscillation while still following real intro/build/drop/breakdown
    /// structure when the chart contains it.
    static func make(chart: Chart, analysis: AudioAnalysis?, duration: Double) -> [Point] {
        let safeDuration = max(1, duration.isFinite ? duration : chart.duration)
        let bucketCount = min(24, max(4, Int((safeDuration / 4.0).rounded())))
        let bucketLength = safeDuration / Double(bucketCount)
        var noteCounts = Array(repeating: 0, count: bucketCount)

        // One linear pass handles taps and chords equally. A chord contributes
        // its simultaneous voices to density, which is a meaningful visual
        // intensity signal without changing chart timing or scoring.
        for note in chart.notes where note.time.isFinite && note.time >= 0 && note.time <= safeDuration {
            let bucket = min(bucketCount - 1, max(0, Int(note.time / bucketLength)))
            noteCounts[bucket] += 1
        }

        let densities = noteCounts.map { Double($0) / max(bucketLength, 0.001) }
        let meanDensity = densities.reduce(0, +) / Double(bucketCount)
        let sortedDensities = densities.sorted()
        let medianDensity = sortedDensities[bucketCount / 2]
        let densityReference = max(0.25, (meanDensity + medianDensity) * 0.5)

        let hasUsefulDensity = chart.notes.count >= 8 && meanDensity >= 0.25
        var raw = Array(repeating: 0.0, count: bucketCount)
        for bucket in 0..<bucketCount {
            let densitySignal = hasUsefulDensity
                ? clamp(densities[bucket] / densityReference - 1, -1, 1)
                : 0
            let midpoint = (Double(bucket) + 0.5) * bucketLength
            let section = analysis?.sections.first {
                $0.start.isFinite && $0.end.isFinite
                    && midpoint >= $0.start && midpoint < $0.end
            }
            let energySignal = section.map { clamp($0.energy * 2 - 1, -1, 1) } ?? 0
            let labelSignal = section.map(labelSignal(for:)) ?? 0
            // Density is primary because it is directly observable in the
            // playable chart. Energy/labels add musical context when present.
            raw[bucket] = clamp(densitySignal * 0.58
                                + energySignal * 0.27
                                + labelSignal * 0.15, -1, 1)
        }

        // Two-pass three-sample smoothing gives gradual acceleration and
        // deceleration while preserving a genuine dense chorus or quiet bridge.
        let once = smooth(raw)
        let twice = smooth(once)
        return twice.enumerated().map { index, value in
            Point(time: Double(index) * bucketLength,
                  intensity: clamp(value, -1, 1))
        }
    }

    private static func smooth(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return values }
        return values.indices.map { index in
            let previous = values[max(0, index - 1)]
            let current = values[index]
            let next = values[min(values.count - 1, index + 1)]
            return previous * 0.25 + current * 0.5 + next * 0.25
        }
    }

    private static func labelSignal(for section: SongSection) -> Double {
        switch section.label {
        case .intro: return -0.55
        case .verse: return -0.12
        case .chorus: return 0.62
        case .bridge: return 0.02
        case .breakdown: return -0.50
        case .outro: return -0.38
        case .generic: return 0
        }
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value.isFinite ? value : 0))
    }
}

/// Absolute-time visual speed profile for one gameplay session.
///
/// The old renderer divided `(noteTime - currentTime)` by a newly sampled
/// lead-time on every frame. When the local lead changed, an already-visible
/// tile could jump because its denominator changed even though the audio clock
/// only moved forward. This profile fixes that at the model boundary:
///
/// - speed targets are prepared once before gameplay;
/// - targets are linearly interpolated between absolute song times;
/// - note position is the integral of that positive speed curve from the
///   note's deterministic spawn time to the current audio time;
/// - the same projection is used by rendering and spatial touch matching.
///
/// A frame-rate change can therefore change sampling cadence, but it cannot
/// change the song timeline or make a note move backward.
struct DynamicSpeedProfile: Sendable, Equatable {
    struct Point: Sendable, Equatable {
        let time: Double
        let multiplier: Double
    }

    enum Source: String, Sendable, Equatable {
        case deterministicChartAndSections
        case deterministicFallback
        case enhancedOnDeviceAI
    }

    /// Structured, bounded output from either the deterministic analyzer or
    /// Apple's optional pre-game on-device analysis. Values are normalized
    /// signals, not per-frame commands; the real-time engine only consumes
    /// the prepared profile below.
    struct SpeedCurvePoint: Codable, Sendable, Equatable {
        let time: Double
        let intensity: Double

        init(time: Double, intensity: Double) {
            self.time = time
            self.intensity = intensity
        }
    }

    let duration: Double
    let points: [Point]
    let source: Source
    let enabled: Bool
    let intensity: DynamicSpeedIntensity
    let difficultyMultiplier: Double
    private let cumulativeDistances: [Double]
    private let minimumMultiplier: Double

    init(duration: Double, points: [Point], source: Source, enabled: Bool,
         intensity: DynamicSpeedIntensity, difficultyMultiplier: Double) {
        self.duration = duration
        self.points = points
        self.source = source
        self.enabled = enabled
        self.intensity = intensity
        self.difficultyMultiplier = difficultyMultiplier
        var distances = Array(repeating: 0.0, count: points.count)
        if points.count > 1 {
            for index in 1..<points.count {
                let previous = points[index - 1]
                let current = points[index]
                let width = max(0, current.time - previous.time)
                distances[index] = distances[index - 1]
                    + (previous.multiplier + current.multiplier) * 0.5 * width
            }
        }
        self.cumulativeDistances = distances
        self.minimumMultiplier = points.map(\.multiplier).min()
            ?? max(difficultyMultiplier, 0.01)
    }

    /// Builds a profile before the session begins. No work from this method is
    /// required by the per-frame renderer.
    static func make(analysis: AudioAnalysis?, chart: Chart,
                     enabled: Bool,
                     intensity: DynamicSpeedIntensity,
                     reduceMotion: Bool = false,
                     enhancedPoints: [SpeedCurvePoint]? = nil) -> DynamicSpeedProfile {
        let duration = max(1, max(analysis?.duration ?? chart.duration, chart.lastNoteTime + 1))
        let effectiveIntensity = intensity
        // Reduce Motion keeps the chart/audio timeline and scoring identical,
        // but removes section-driven visual speed variation for a calm,
        // predictable presentation.
        let variation = enabled && !reduceMotion
            ? effectiveIntensity.variation * chart.difficulty.dynamicSpeedResponse
            : 0
        let base = chart.difficulty.visualSpeedMultiplier

        // Dynamic Speed OFF (and Reduce Motion) intentionally bypasses all
        // chart analysis. The same absolute-time projection remains active,
        // but the profile is constant and no dynamic work is needed.
        if variation == 0 {
            return DynamicSpeedProfile(duration: duration,
                                       points: [Point(time: 0, multiplier: base),
                                                Point(time: duration, multiplier: base)],
                                       source: .deterministicFallback,
                                       enabled: enabled,
                                       intensity: effectiveIntensity,
                                       difficultyMultiplier: base)
        }

        var targets: [(time: Double, signal: Double)] = []
        var profileSource: Source = .deterministicFallback
        if let enhancedPoints {
            // Foundation Models output is advisory structure only. Validate,
            // sort, clamp, and deduplicate before it can affect presentation.
            let valid = enhancedPoints.filter {
                $0.time.isFinite && $0.intensity.isFinite
                    && $0.time >= 0 && $0.time <= duration
            }.sorted { $0.time < $1.time }
            if valid.count <= 24 {
                for point in valid {
                    let time = max(0, min(duration, point.time))
                    let signal = clamp(point.intensity, -1, 1)
                    if let last = targets.last, abs(last.time - time) < 0.0001 {
                        targets[targets.count - 1] = (time, signal)
                    } else {
                        targets.append((time, signal))
                    }
                }
            }
            if targets.count >= 2 {
                profileSource = .enhancedOnDeviceAI
            } else {
                targets.removeAll(keepingCapacity: true)
            }
        }

        if targets.isEmpty {
            // The Standard Math Engine is the universal path. It uses chart
            // density/chords plus section energy/labels and two-pass smoothing
            // to produce broad musical changes rather than a linear ramp.
            targets = StandardMathIntensityAnalyzer.make(chart: chart,
                                                          analysis: analysis,
                                                          duration: duration)
                .map { ($0.time, $0.intensity) }
            profileSource = analysis?.sections.isEmpty == false
                ? .deterministicChartAndSections
                : .deterministicFallback
        }

        var points: [Point] = []
        let allowedRange = chart.difficulty.dynamicSpeedRange
        for target in targets.sorted(by: { $0.time < $1.time }) {
            let multiplier = clamp(base * (1 + target.signal * variation),
                                   allowedRange.lowerBound, allowedRange.upperBound)
            if let last = points.last, abs(last.time - target.time) < 0.0001 {
                points[points.count - 1] = Point(time: target.time, multiplier: multiplier)
            } else {
                points.append(Point(time: target.time, multiplier: multiplier))
            }
        }
        if points.isEmpty || points[0].time > 0 {
            let first = points.first?.multiplier ?? base
            points.insert(Point(time: 0, multiplier: first), at: 0)
        }
        if points.last?.time ?? 0 < duration {
            points.append(Point(time: duration, multiplier: points.last?.multiplier ?? base))
        }

        return DynamicSpeedProfile(duration: duration, points: points,
                                   source: profileSource,
                                   enabled: enabled, intensity: effectiveIntensity,
                                   difficultyMultiplier: base)
    }

    /// Stable speed multiplier at an absolute song time.
    func multiplier(at time: Double) -> Double {
        guard let first = points.first else { return difficultyMultiplier }
        guard points.count > 1 else { return first.multiplier }
        if time <= first.time { return first.multiplier }
        guard let last = points.last else { return first.multiplier }
        if time >= last.time { return last.multiplier }
        var low = 0
        var high = points.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if points[middle].time <= time { low = middle } else { high = middle }
        }
        let a = points[low]
        let b = points[high]
        let fraction = (time - a.time) / max(b.time - a.time, 0.0001)
        return a.multiplier + (b.multiplier - a.multiplier) * fraction
    }

    /// Effective lead at a time, retained as a compatibility/readability API.
    /// Projection itself uses `progress(noteTime:currentTime:baseLead:)` below.
    func leadTime(at time: Double, baseLead: Double) -> Double {
        baseLead / max(multiplier(at: time), 0.01)
    }

    /// Absolute-time note projection. 1 = spawn point, 0 = hit line, negative
    /// = passed the hit line. This is monotonic as `currentTime` increases.
    func progress(noteTime: Double, currentTime: Double, baseLead: Double) -> Double {
        guard noteTime.isFinite, currentTime.isFinite, baseLead.isFinite, baseLead > 0 else {
            return 0
        }
        let travelTime = baseLead / max(multiplier(at: noteTime), 0.01)
        let spawnTime = noteTime - travelTime
        let totalDistance = integral(from: spawnTime, to: noteTime)
        guard totalDistance > 0, totalDistance.isFinite else { return 0 }
        return integral(from: currentTime, to: noteTime) / totalDistance
    }

    /// Spatial progress of a timestamp inside a hold interval. Unlike a
    /// standalone note projection, this uses one shared integrated distance
    /// across the complete hold, so speed changes inside the hold change the
    /// fill position continuously without changing the hold's musical timing.
    /// 0 = hold head time, 1 = hold tail time.
    func relativeProgress(from startTime: Double, to endTime: Double,
                          at currentTime: Double) -> Double {
        guard startTime.isFinite, endTime.isFinite, currentTime.isFinite,
              endTime > startTime else { return 0 }
        let totalDistance = integral(from: startTime, to: endTime)
        guard totalDistance.isFinite, totalDistance > 0 else { return 0 }
        let clampedTime = min(endTime, max(startTime, currentTime))
        return min(1, max(0, integral(from: startTime, to: clampedTime) / totalDistance))
    }

    /// Largest possible visual lead for range queries in the renderer.
    func maximumLeadTime(baseLead: Double) -> Double {
        baseLead / max(minimumMultiplier, 0.01)
    }

    // MARK: - Piecewise-linear integration

    /// Integrates the positive speed curve in O(log n) using the precomputed
    /// prefix areas. The old implementation walked every profile segment for
    /// every visible tile on every frame, which made a dense chart needlessly
    /// compete with the display refresh.
    private func integral(from start: Double, to end: Double) -> Double {
        guard start.isFinite, end.isFinite, start != end else { return 0 }
        return area(to: end) - area(to: start)
    }

    /// Signed area from the first profile point to `time`.
    private func area(to time: Double) -> Double {
        guard let first = points.first else { return 0 }
        if time <= first.time {
            return (time - first.time) * first.multiplier
        }
        guard let last = points.last else { return 0 }
        if time >= last.time {
            return (cumulativeDistances.last ?? 0)
                + (time - last.time) * last.multiplier
        }

        var low = 0
        var high = points.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if points[middle].time <= time { low = middle } else { high = middle }
        }
        let a = points[low]
        let b = points[high]
        let width = max(b.time - a.time, 0.0001)
        let fraction = (time - a.time) / width
        let speedAtTime = a.multiplier + (b.multiplier - a.multiplier) * fraction
        return (cumulativeDistances[low] + (a.multiplier + speedAtTime) * 0.5 * (time - a.time))
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value.isFinite ? value : 0))
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        Self.clamp(value, lower, upper)
    }
}
