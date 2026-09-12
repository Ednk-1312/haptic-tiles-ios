import Foundation

/// Timing judgment. All windows are configurable (see Settings).
/// Calibration is applied here, never to chart timestamps.
struct InputJudge {
    struct Config: Sendable {
        var perfectWindow: Double    // seconds (±)
        var greatWindow: Double
        var goodWindow: Double
        var missWindow: Double       // beyond this a note is a miss
        var calibrationOffset: Double // seconds; added to tap times

        /// Forgiving defaults (see spec §Timing windows). Configurable in Settings.
        static let standard = Config(perfectWindow: 0.07,
                                     greatWindow: 0.13,
                                     goodWindow: 0.20,
                                     missWindow: 0.20,
                                     calibrationOffset: 0)

        /// A tap up to this far beyond `goodWindow` still counts as GOOD.
        /// It prevents visually-correct edge taps from turning into phantom
        /// misses: the note was clearly meant to be hit, so reward it.
        static let edgeGrace: Double = 0.04
    }

    let config: Config

    /// delta = tapTime + calibration − noteTime (positive → tap is late).
    /// Negative calibration compensates for audio output latency.
    func classify(tapTime: Double, noteTime: Double) -> Judgment {
        let delta = tapTime + config.calibrationOffset - noteTime
        let absDelta = abs(delta)
        if absDelta <= config.perfectWindow { return .perfect }
        if absDelta <= config.greatWindow { return .great }
        if absDelta <= config.goodWindow { return .good }
        return .miss
    }

    /// Judgment used by live input: identical to `classify`, except a tap that
    /// lands just outside the GOOD window (within `edgeGrace`) is counted as a
    /// GOOD hit rather than a MISS. Pure timeouts (no tap at all) still miss.
    func classifyForgiving(tapTime: Double, noteTime: Double) -> Judgment {
        let delta = tapTime + config.calibrationOffset - noteTime
        if abs(delta) <= config.goodWindow { return classify(tapTime: tapTime, noteTime: noteTime) }
        if abs(delta) <= config.goodWindow + Self.Config.edgeGrace { return .good }
        return .miss
    }
}