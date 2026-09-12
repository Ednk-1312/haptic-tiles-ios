import Foundation

/// Per-run analytics computed from the compact replay events. Pure and
/// deterministic: identical events always produce identical analytics, so the
/// same synthetic input is used by the UI and the tests.
///
/// Accuracy matches the game's own weighted formula (Perfect 1.0, Great 0.75,
/// Good 0.5, Miss 0) over the judged notes. A judged note is any event that
/// went through the score pipeline: `.note`, `.holdStart` and `.holdMiss`.
/// `.holdRelease` (the head already counted) and `.holdComplete` (a bonus, no
/// judgment) are excluded — exactly mirroring `ScoreManager.counts`.
struct RunAnalytics: Equatable, Sendable {
    // MARK: - Overall

    var judgedCount = 0
    var perfectCount = 0
    var greatCount = 0
    var goodCount = 0
    var missCount = 0
    /// 0…1 weighted accuracy (game formula).
    var accuracy = 0.0
    /// Mean |timing error| over judged notes (ms).
    var meanAbsErrorMs = 0.0
    /// Signed mean timing error (ms). Positive = taps tended late.
    var meanErrorMs = 0.0
    /// |error| ≤ 15 ms is "accurate"; beyond that, sign decides early/late.
    var accurateCount = 0
    var earlyCount = 0
    var lateCount = 0
    /// Early count − late count (negative = late-leaning run).
    var earlyLateBalance = 0
    var maxCombo = 0

    // MARK: - Progression (time, value) series, deterministically sampled

    struct Point: Equatable, Sendable {
        var time: Double
        var value: Int
    }

    /// Score after each event (holds included — bonus lands here too).
    var scoreProgression: [Point] = []
    /// Combo after each event (misses drop it to 0).
    var comboProgression: [Point] = []

    // MARK: - Timeline buckets (early / late / accurate strip)

    struct TimelineBucket: Equatable, Sendable {
        var start: Double
        var end: Double
        var count = 0
        /// Signed mean error (ms) of the judged notes in this bucket.
        var meanErrorMs = 0.0
        var accurateCount = 0
        var earlyCount = 0
        var lateCount = 0
    }

    var timeline: [TimelineBucket] = []
    /// 24 buckets across the run (fewer when the song is very short).
    static let defaultBucketCount = 24

    // MARK: - Per-section breakdown

    struct SectionStats: Equatable, Sendable {
        var index: Int
        var label: String
        var start: Double
        var end: Double
        var judgedCount = 0
        var accuracy = 0.0
        var meanAbsErrorMs = 0.0
        var earlyCount = 0
        var lateCount = 0
        var accurateCount = 0
    }

    var sections: [SectionStats] = []
}

/// Everything the analytics screen needs for one run: the recorded events,
/// the detected sections (optional), and display identity.
struct RunAnalyticsInput {
    let events: [ReplayEvent]
    let sections: [SongSection]
    let title: String
    let difficulty: DifficultyLevel
    let duration: Double

    func compute() -> RunAnalytics {
        RunAnalyticsCalculator.compute(events: events, sections: sections, duration: duration)
    }
}

/// Pure computation — the single source of truth for the analytics screen.
enum RunAnalyticsCalculator {

    /// Timing error considered "accurate" (|ms| ≤ threshold).
    static let accurateThresholdMs = 15.0
    /// Bucket count for the timeline strip.
    static let bucketCount = RunAnalytics.defaultBucketCount

    /// Computes analytics from a run's events and (optionally) the detected
    /// song sections. `duration` drives the timeline; falls back to the last
    /// event time when 0.
    static func compute(events: [ReplayEvent], sections: [SongSection] = [],
                        duration: Double = 0) -> RunAnalytics {
        // Judged notes = events that went through the score pipeline.
        let judged = events.filter { $0.kind != .holdComplete && $0.kind != .holdRelease }

        var analytics = RunAnalytics()
        analytics.judgedCount = judged.count
        analytics.perfectCount = judged.count { $0.judgment == .perfect }
        analytics.greatCount = judged.count { $0.judgment == .great }
        analytics.goodCount = judged.count { $0.judgment == .good }
        analytics.missCount = judged.count { $0.judgment == .miss }
        analytics.accuracy = accuracy(judgments: judged.compactMap(\.judgment))

        // Timing (judged notes only; hold releases carry their own deltas but
        // are excluded to mirror the score pipeline).
        let errors = judged.map { $0.timingErrorMs }
        if !errors.isEmpty {
            analytics.meanAbsErrorMs = errors.map { abs($0) }.reduce(0, +) / Double(errors.count)
            analytics.meanErrorMs = errors.reduce(0, +) / Double(errors.count)
        }
        analytics.accurateCount = errors.count { abs($0) <= Self.accurateThresholdMs }
        analytics.earlyCount = errors.count { $0 < -Self.accurateThresholdMs }
        analytics.lateCount = errors.count { $0 > Self.accurateThresholdMs }
        analytics.earlyLateBalance = analytics.earlyCount - analytics.lateCount

        // Progression (all events — holds land here too).
        analytics.scoreProgression = events.map { RunAnalytics.Point(time: $0.time, value: $0.score) }
        analytics.comboProgression = events.map { RunAnalytics.Point(time: $0.time, value: $0.combo) }
        analytics.maxCombo = events.map(\.combo).max() ?? 0

        // Timeline buckets.
        let span = duration > 0 ? duration : (events.map(\.time).max() ?? 0)
        if span > 0 {
            let bucketCount = max(1, min(Self.bucketCount, Int(span.rounded(.up))))
            analytics.timeline = (0..<bucketCount).map { i in
                let start = span * Double(i) / Double(bucketCount)
                let end = span * Double(i + 1) / Double(bucketCount)
                let inBucket = judged.filter { $0.time >= start && $0.time < end }
                var bucket = RunAnalytics.TimelineBucket(start: start, end: end, count: inBucket.count)
                let errs = inBucket.map { $0.timingErrorMs }
                if !errs.isEmpty {
                    bucket.meanErrorMs = errs.reduce(0, +) / Double(errs.count)
                }
                bucket.accurateCount = errs.count { abs($0) <= Self.accurateThresholdMs }
                bucket.earlyCount = errs.count { $0 < -Self.accurateThresholdMs }
                bucket.lateCount = errs.count { $0 > Self.accurateThresholdMs }
                return bucket
            }
        }

        // Per-section breakdown. Events outside every section are tallied in
        // an "Other" pseudo-section only when non-empty (detected sections
        // usually cover the song, but never assume it).
        let ordered = sections.sorted { $0.start < $1.start }
        for section in ordered {
            let inSection = judged.filter { $0.time >= section.start && $0.time < section.end }
            var stats = RunAnalytics.SectionStats(index: section.index,
                                     label: section.label.displayName,
                                     start: section.start, end: section.end,
                                     judgedCount: inSection.count)
            stats.accuracy = accuracy(judgments: inSection.compactMap(\.judgment))
            let errs = inSection.map { $0.timingErrorMs }
            if !errs.isEmpty {
                stats.meanAbsErrorMs = errs.map { abs($0) }.reduce(0, +) / Double(errs.count)
            }
            stats.accurateCount = errs.count { abs($0) <= Self.accurateThresholdMs }
            stats.earlyCount = errs.count { $0 < -Self.accurateThresholdMs }
            stats.lateCount = errs.count { $0 > Self.accurateThresholdMs }
            analytics.sections.append(stats)
        }
        let outside = judged.filter { event in
            !ordered.contains { $0.start <= event.time && event.time < $0.end }
        }
        if !outside.isEmpty {
            var stats = RunAnalytics.SectionStats(index: -1, label: "Other", start: 0, end: 0,
                                     judgedCount: outside.count)
            stats.accuracy = accuracy(judgments: outside.compactMap(\.judgment))
            let errs = outside.map { $0.timingErrorMs }
            if !errs.isEmpty {
                stats.meanAbsErrorMs = errs.map { abs($0) }.reduce(0, +) / Double(errs.count)
            }
            stats.accurateCount = errs.count { abs($0) <= Self.accurateThresholdMs }
            stats.earlyCount = errs.count { $0 < -Self.accurateThresholdMs }
            stats.lateCount = errs.count { $0 > Self.accurateThresholdMs }
            analytics.sections.append(stats)
        }

        return analytics
    }

    /// Game formula: Perfect 1.0, Great 0.75, Good 0.5, Miss 0.
    static func accuracy(judgments: [Judgment]) -> Double {
        let total = Double(judgments.count)
        guard total > 0 else { return 0 }
        let weighted = judgments.reduce(0.0) { acc, j in
            switch j {
            case .perfect: return acc + 1.0
            case .great: return acc + 0.75
            case .good: return acc + 0.5
            case .miss: return acc
            }
        }
        return weighted / total
    }
}

private extension Array {
    func count(_ predicate: (Element) -> Bool) -> Int {
        reduce(0) { $0 + (predicate($1) ? 1 : 0) }
    }
}