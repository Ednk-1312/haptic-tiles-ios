import Foundation

/// Configuration for a practice session. Practice NEVER modifies the chart —
/// it wraps an existing chart (and its shared analysis) with a separate,
/// player-adjustable timeline and focus options.
struct PracticeConfig: Sendable, Equatable {
    /// Playback rate: 0.50×, 0.75×, 1.00×. Chart timestamps are untouched; the
    /// authoritative audio clock advances at this rate, so the whole game —
    /// audio, falling notes, judgments, haptics — slows down consistently.
    var speed: Double = 1.0
    /// Restrict play to one detected song section (nil = whole song).
    var section: PracticeSection?
    /// When true, reaching the section end restarts it automatically with a
    /// fully reset note/judgment/haptic state.
    var loopSection = false
    /// HUD options — practice can hide score/combo and show timing instead.
    var showScore = true
    var showCombo = true
    var showTiming = false

    /// Supported speeds. Add values here to extend the picker later; the
    /// engine clamps to AVAudioPlayer's supported range (0.5…2.0).
    static let supportedSpeeds: [Double] = [0.5, 0.75, 1.0]
}

/// A user-selectable song section, derived from detected analysis sections.
struct PracticeSection: Identifiable, Sendable, Equatable {
    var id: Int
    var label: String
    var start: Double
    var end: Double
    var energy: Double
}

/// Running practice statistics (accuracy + timing). Practice sessions are
/// never saved as official records; this is live feedback only.
struct PracticeStats: Sendable, Equatable {
    var hitCount = 0
    var perfectCount = 0
    var greatCount = 0
    var goodCount = 0
    var missCount = 0
    var absDeltaMsSum = 0.0

    var judgedCount: Int { hitCount }
    var meanAbsDeltaMs: Double { hitCount > 0 ? absDeltaMsSum / Double(hitCount) : 0 }

    /// 0…1 weighted accuracy over judged notes (same weighting as scoring).
    var accuracy: Double {
        guard hitCount > 0 else { return 0 }
        let weighted = Double(perfectCount) + 0.75 * Double(greatCount) + 0.5 * Double(goodCount)
        return weighted / Double(hitCount)
    }

    mutating func record(judgment: Judgment, deltaMs: Double) {
        hitCount += 1
        switch judgment {
        case .perfect: perfectCount += 1
        case .great: greatCount += 1
        case .good: goodCount += 1
        case .miss: missCount += 1
        }
        absDeltaMsSum += abs(deltaMs)
    }
}

/// Pure practice-timeline math. The live engine uses the SAME formulas with
/// `AVAudioPlayer`'s device clock; tests exercise them with a scripted clock
/// and no audio at all.
enum PracticeClock {
    /// Content time at `nowDevice` on the device clock, given an anchor.
    /// This is exactly what AudioPlayer.currentTime computes while playing.
    static func contentTime(anchorContent: Double, anchorDevice: Double,
                            nowDevice: Double, rate: Double) -> Double {
        anchorContent + max(0, nowDevice - anchorDevice) * rate
    }

    /// Wall-clock seconds needed to play `contentSeconds` at `rate`.
    static func wallDuration(contentSeconds: Double, rate: Double) -> Double {
        guard rate > 0 else { return contentSeconds }
        return contentSeconds / rate
    }

    /// Whether a looping section must restart at this content time (the loop
    /// fires just before the end so the tail of the last note is audible).
    static func shouldRestartLoop(contentTime: Double, sectionEnd: Double, loop: Bool) -> Bool {
        loop && contentTime >= sectionEnd - 0.05
    }
}