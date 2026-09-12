import XCTest
@testable import Music_Haptics

/// Deterministic tests for the per-run analytics calculations, using
/// synthetic replay events (no audio, no device).
final class RunAnalyticsTests: XCTestCase {

    private func event(_ kind: ReplayEventKind = .note, id: Int, time: Double,
                       judgment: Judgment?, delta: Double, score: Int = 0,
                       combo: Int = 0, lane: Int = 0) -> ReplayEvent {
        ReplayEvent(kind: kind, noteID: id, lane: lane, time: time,
                    judgment: judgment, timingErrorMs: delta, score: score, combo: combo)
    }

    // MARK: - Accuracy

    func testAccuracyMatchesGameFormula() {
        // 4 perfect, 2 great, 2 good, 2 miss → (4 + 1.5 + 1) / 10 = 0.65
        var events: [ReplayEvent] = []
        for i in 0..<4 { events.append(event(id: i, time: Double(i), judgment: .perfect, delta: 0)) }
        for i in 4..<6 { events.append(event(id: i, time: Double(i), judgment: .great, delta: 20)) }
        for i in 6..<8 { events.append(event(id: i, time: Double(i), judgment: .good, delta: -40)) }
        for i in 8..<10 { events.append(event(id: i, time: Double(i), judgment: .miss, delta: 0)) }
        let analytics = RunAnalyticsCalculator.compute(events: events, duration: 10)
        XCTAssertEqual(analytics.judgedCount, 10)
        XCTAssertEqual(analytics.perfectCount, 4)
        XCTAssertEqual(analytics.greatCount, 2)
        XCTAssertEqual(analytics.goodCount, 2)
        XCTAssertEqual(analytics.missCount, 2)
        XCTAssertEqual(analytics.accuracy, 0.65, accuracy: 0.0001)
    }

    func testHoldLifecycleDoesNotDoubleCount() {
        // A hold: head perfect + completed. Only the head counts as judged.
        let events = [
            event(.holdStart, id: 1, time: 1.0, judgment: .perfect, delta: -5),
            event(.holdComplete, id: 1, time: 2.0, judgment: nil, delta: 0),
        ]
        let analytics = RunAnalyticsCalculator.compute(events: events, duration: 3)
        XCTAssertEqual(analytics.judgedCount, 1)
        XCTAssertEqual(analytics.perfectCount, 1)
        XCTAssertEqual(analytics.accuracy, 1.0, accuracy: 0.0001)
    }

    func testEarlyReleasedHoldIsMissButNotDoubleCounted() {
        let events = [
            event(.holdStart, id: 1, time: 1.0, judgment: .great, delta: 10),
            event(.holdRelease, id: 1, time: 1.5, judgment: .miss, delta: -500),
        ]
        let analytics = RunAnalyticsCalculator.compute(events: events, duration: 3)
        XCTAssertEqual(analytics.judgedCount, 1)
        XCTAssertEqual(analytics.greatCount, 1)
        XCTAssertEqual(analytics.missCount, 0, "release must not add an extra miss")
    }

    func testHoldHeadMissCountsAsMiss() {
        let events = [event(.holdMiss, id: 1, time: 1.0, judgment: .miss, delta: 0)]
        let analytics = RunAnalyticsCalculator.compute(events: events, duration: 3)
        XCTAssertEqual(analytics.missCount, 1)
        XCTAssertEqual(analytics.accuracy, 0, accuracy: 0.0001)
    }

    // MARK: - Timing

    func testMeanAbsoluteAndSignedErrors() {
        // Errors: -30, +10, -20, +40 → mean |err| = 25, mean = 0
        let events = [
            event(id: 1, time: 1, judgment: .good, delta: -30),
            event(id: 2, time: 2, judgment: .perfect, delta: 10),
            event(id: 3, time: 3, judgment: .great, delta: -20),
            event(id: 4, time: 4, judgment: .good, delta: 40),
        ]
        let analytics = RunAnalyticsCalculator.compute(events: events, duration: 5)
        XCTAssertEqual(analytics.meanAbsErrorMs, 25, accuracy: 0.0001)
        XCTAssertEqual(analytics.meanErrorMs, 0, accuracy: 0.0001)
    }

    func testEarlyLateAccurateClassification() {
        // Threshold 15 ms: -16 early, +20 late, -10 accurate, +5 accurate.
        let events = [
            event(id: 1, time: 1, judgment: .great, delta: -16),
            event(id: 2, time: 2, judgment: .great, delta: 20),
            event(id: 3, time: 3, judgment: .perfect, delta: -10),
            event(id: 4, time: 4, judgment: .perfect, delta: 5),
        ]
        let analytics = RunAnalyticsCalculator.compute(events: events, duration: 5)
        XCTAssertEqual(analytics.earlyCount, 1)
        XCTAssertEqual(analytics.lateCount, 1)
        XCTAssertEqual(analytics.accurateCount, 2)
        XCTAssertEqual(analytics.earlyLateBalance, 0)
    }

    func testLateLeaningRunHasNegativeBalance() {
        let events = [
            event(id: 1, time: 1, judgment: .great, delta: 30),
            event(id: 2, time: 2, judgment: .good, delta: 25),
            event(id: 3, time: 3, judgment: .perfect, delta: 5),
        ]
        let analytics = RunAnalyticsCalculator.compute(events: events, duration: 4)
        XCTAssertEqual(analytics.earlyLateBalance, -2)
    }

    // MARK: - Progression

    func testScoreAndComboProgression() {
        let events = [
            event(id: 1, time: 1, judgment: .perfect, delta: 0, score: 1000, combo: 1),
            event(id: 2, time: 2, judgment: .great, delta: 0, score: 1750, combo: 2),
            event(id: 3, time: 3, judgment: .miss, delta: 0, score: 1750, combo: 0),
            event(id: 4, time: 4, judgment: .perfect, delta: 0, score: 2750, combo: 1),
        ]
        let analytics = RunAnalyticsCalculator.compute(events: events, duration: 5)
        XCTAssertEqual(analytics.scoreProgression.map(\.value), [1000, 1750, 1750, 2750])
        XCTAssertEqual(analytics.comboProgression.map(\.value), [1, 2, 0, 1])
        XCTAssertEqual(analytics.maxCombo, 2)
        XCTAssertEqual(analytics.scoreProgression.map(\.time), [1, 2, 3, 4])
    }

    // MARK: - Timeline buckets

    func testTimelineBucketsDistributeAcrossDuration() {
        let events = (0..<24).map { i in
            event(id: i, time: Double(i), judgment: .perfect, delta: i % 2 == 0 ? -20 : 20)
        }
        let analytics = RunAnalyticsCalculator.compute(events: events, duration: 24)
        XCTAssertEqual(analytics.timeline.count, 24)
        // Each bucket has exactly one note at its start.
        let withNotes = analytics.timeline.filter { $0.count > 0 }
        XCTAssertEqual(withNotes.count, 24)
        // Even buckets: mean error -20 (early) → red; odd: +20 (late) → blue.
        XCTAssertEqual(analytics.timeline[0].meanErrorMs, -20, accuracy: 0.0001)
        XCTAssertEqual(analytics.timeline[1].meanErrorMs, 20, accuracy: 0.0001)
    }

    func testTimelineBucketsAggregateMultipleNotes() {
        // Buckets are [start, end): time 1.0 and 1.5 land in bucket 1.
        let events = [
            event(id: 1, time: 1, judgment: .great, delta: -10),
            event(id: 2, time: 1.5, judgment: .perfect, delta: 10),
            event(id: 3, time: 2.5, judgment: .good, delta: -30),
        ]
        let analytics = RunAnalyticsCalculator.compute(events: events, duration: 4)
        XCTAssertEqual(analytics.timeline.count, 4) // duration 4 → 4 buckets
        XCTAssertEqual(analytics.timeline[0].count, 0)
        XCTAssertEqual(analytics.timeline[1].count, 2)
        XCTAssertEqual(analytics.timeline[1].meanErrorMs, 0, accuracy: 0.0001)
        XCTAssertEqual(analytics.timeline[1].accurateCount, 2)
        XCTAssertEqual(analytics.timeline[2].count, 1)
        XCTAssertEqual(analytics.timeline[2].meanErrorMs, -30, accuracy: 0.0001)
    }

    func testEmptyTimelineForZeroDuration() {
        let analytics = RunAnalyticsCalculator.compute(events: [], duration: 0)
        XCTAssertTrue(analytics.timeline.isEmpty)
        XCTAssertEqual(analytics.judgedCount, 0)
        XCTAssertEqual(analytics.accuracy, 0)
    }

    // MARK: - Sections

    private func sections() -> [SongSection] {
        [
            SongSection(index: 0, start: 0, end: 4, label: .intro, energy: 0.3),
            SongSection(index: 1, start: 4, end: 10, label: .verse, energy: 0.6),
            SongSection(index: 2, start: 10, end: 16, label: .chorus, energy: 0.9),
        ]
    }

    func testSectionBreakdown() {
        // Verse (4–10): 3 perfects → 100%. Chorus (10–16): 2 greats + 2 misses → 37.5%.
        let events = [
            event(id: 1, time: 5, judgment: .perfect, delta: -5),
            event(id: 2, time: 6, judgment: .perfect, delta: 5),
            event(id: 3, time: 7, judgment: .perfect, delta: 0),
            event(id: 4, time: 11, judgment: .great, delta: 20),
            event(id: 5, time: 12, judgment: .great, delta: -25),
            event(id: 6, time: 13, judgment: .miss, delta: 0),
            event(id: 7, time: 14, judgment: .miss, delta: 0),
        ]
        let analytics = RunAnalyticsCalculator.compute(events: events, sections: sections(), duration: 16)
        XCTAssertEqual(analytics.sections.count, 3)
        let verse = analytics.sections[1]
        XCTAssertEqual(verse.label, "Verse")
        XCTAssertEqual(verse.judgedCount, 3)
        XCTAssertEqual(verse.accuracy, 1.0, accuracy: 0.0001)
        XCTAssertEqual(verse.meanAbsErrorMs, 10.0 / 3.0, accuracy: 0.0001)
        let chorus = analytics.sections[2]
        XCTAssertEqual(chorus.label, "Chorus")
        XCTAssertEqual(chorus.judgedCount, 4)
        XCTAssertEqual(chorus.accuracy, 0.375, accuracy: 0.0001)
        XCTAssertEqual(chorus.earlyCount, 1)
        XCTAssertEqual(chorus.lateCount, 1)
        XCTAssertEqual(chorus.accurateCount, 2, "the two misses carry delta 0 → accurate")
    }

    func testEventsOutsideSectionsBecomeOther() {
        let events = [
            event(id: 1, time: 1, judgment: .perfect, delta: 0),   // intro (in section)
            event(id: 2, time: 3, judgment: .perfect, delta: 0),   // intro
            event(id: 3, time: 20, judgment: .miss, delta: 0),     // after last section
        ]
        let analytics = RunAnalyticsCalculator.compute(events: events, sections: sections(), duration: 21)
        XCTAssertEqual(analytics.sections.count, 4)
        let other = analytics.sections.last!
        XCTAssertEqual(other.label, "Other")
        XCTAssertEqual(other.judgedCount, 1)
        XCTAssertEqual(other.accuracy, 0, accuracy: 0.0001)
    }

    // MARK: - Determinism

    func testDeterministicForIdenticalInput() {
        var events: [ReplayEvent] = []
        for i in 0..<40 {
            events.append(event(id: i, time: Double(i) * 0.5, judgment: i % 5 == 0 ? .miss : .great,
                                delta: Double((i % 7) - 3) * 8))
        }
        let sections = sections()
        let a = RunAnalyticsCalculator.compute(events: events, sections: sections, duration: 20)
        let b = RunAnalyticsCalculator.compute(events: events, sections: sections, duration: 20)
        XCTAssertEqual(a, b)
    }
}