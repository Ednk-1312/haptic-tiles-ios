import Foundation

/// Interactive player calibration: a short metronome exercise where the user
/// taps along with visible (and haptic) cues, and the timing error between
/// taps and cues estimates a recommended timing offset.
///
/// This is NOT a scientific latency measurement — rendering, audio and input
/// paths each add their own latency. It measures the player's PERCEIVED sync
/// error and suggests a compensation.
///
/// Sign convention (kept explicit everywhere):
///   measurement = tapTime − cueTime  →  positive = tap LATE
///   recommended offset = −median(measurements)
///   (a late tap needs a negative offset so the game's delta shrinks —
///   matching the Settings wording: \"hits register late → move lower\").
struct CalibrationSession: Sendable {
    struct Config: Sendable {
        var countInBeats = 4          // steady cues before measuring
        var tapBeats = 12             // measured beats
        var interval = 0.667          // seconds per beat (90 BPM default)
        /// How close a tap must be to its nearest cue to count (half a beat).
        var acceptanceWindow = 0.5
        /// Reject a second tap landing on an already-consumed cue.
        var doubleTapWindow = 0.5
        /// Minimum valid measurements before an estimate is offered.
        var minimumMeasurements = 4
    }

    private(set) var config: Config
    /// Anchor (monotonic clock, e.g. system uptime) of the count-in start.
    private(set) var anchor: Double?
    /// Raw tap timestamps (monotonic clock).
    private(set) var taps: [Double] = []
    /// Valid measurements: tap − cue, seconds (positive = late).
    private(set) var measurements: [Double] = []
    /// Taps rejected (no nearby cue, or a double-tap on a consumed cue).
    private(set) var rejectedTaps = 0
    /// Cues already matched by a tap (index → matched).
    private var matchedCues: Set<Int> = []

    init(config: Config = Config()) {
        self.config = config
    }

    var isRunning: Bool { anchor != nil }

    /// All cue timestamps (count-in + measured), relative to `anchor`.
    func cueTimes(anchor: Double) -> [Double] {
        let total = config.countInBeats + config.tapBeats
        return (0..<total).map { anchor + Double($0) * config.interval }
    }

    /// Cue times for the MEASURED beats only (the count-in is warm-up).
    func measuredCueTimes(anchor: Double) -> [Double] {
        let cues = cueTimes(anchor: anchor)
        return Array(cues.suffix(config.tapBeats))
    }

    /// Begins the exercise at the given monotonic anchor.
    mutating func start(at anchor: Double) {
        self.anchor = anchor
        taps = []
        measurements = []
        rejectedTaps = 0
        matchedCues = []
    }

    /// Records a tap against the nearest unconsumed measured cue. Returns the
    /// measurement (tap − cue) when the tap was accepted.
    @discardableResult
    mutating func record(tapAt time: Double) -> Double? {
        guard let anchor else { return nil }
        let cues = measuredCueTimes(anchor: anchor)
        guard !cues.isEmpty else { return nil }

        // Nearest unconsumed cue.
        var bestIndex: Int?
        var bestDistance = Double.infinity
        for (i, cue) in cues.enumerated() where !matchedCues.contains(i) {
            let d = abs(time - cue)
            if d < bestDistance {
                bestDistance = d
                bestIndex = i
            }
        }
        guard let bestIndex else {
            rejectedTaps += 1
            return nil
        }
        // Double-tap guard: a second tap landing shortly AFTER the previous
        // tap (same cue fired twice in a row) is almost certainly a misfire.
        // Taps that arrive BEFORE the previous tap are simply out-of-order
        // (earlier cue) and must not be rejected.
        if let last = taps.last, time - last >= 0, time - last < config.doubleTapWindow {
            rejectedTaps += 1
            return nil
        }
        // Acceptance window: the tap must be plausibly aimed at this cue.
        guard bestDistance <= config.acceptanceWindow else {
            rejectedTaps += 1
            return nil
        }
        taps.append(time)
        matchedCues.insert(bestIndex)
        let measurement = time - cues[bestIndex]
        measurements.append(measurement)
        return measurement
    }

    /// Recommended calibration offset in ms (negated median, rounded to 5 ms),
    /// clamped to the settings range. nil until enough valid measurements.
    var recommendedOffsetMs: Double? {
        guard measurements.count >= config.minimumMeasurements else { return nil }
        let median = Self.median(measurements)
        let offset = (-median * 1000).rounded(toNearest: 5)
        return min(100, max(-100, offset))
    }

    /// Average |tap − cue| over valid measurements (how tight the taps were).
    var meanAbsoluteErrorMs: Double {
        guard !measurements.isEmpty else { return 0 }
        return measurements.map { abs($0) * 1000 }.reduce(0, +) / Double(measurements.count)
    }

    // MARK: - Pure estimation (deterministic, testable)

    /// Median of the measurements (robust to outlier taps).
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Turns a raw median error (seconds) into a recommended offset (ms):
    /// negated (late taps → negative offset) and rounded to 5 ms steps.
    static func recommendedOffset(fromMedianError seconds: Double) -> Double {
        let offset = (-seconds * 1000).rounded(toNearest: 5)
        return min(100, max(-100, offset))
    }
}

extension Double {
    fileprivate func rounded(toNearest step: Double) -> Double {
        (self / step).rounded() * step
    }
}