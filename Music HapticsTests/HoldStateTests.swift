import XCTest
@testable import Music_Haptics

/// Explicit hold lifecycle + chord-behavior tests. HoldTracker is a pure
/// value type and the chord/haptic decisions are pure predicates, so every
/// state and transition is deterministically testable.
final class HoldStateTests: XCTestCase {

    // MARK: - Hold states

    @MainActor
    func testHoldStateLifecycle() {
        var tracker = HoldTracker()
        XCTAssertEqual(tracker.state(for: 7), .notStarted, "default state before the head is touched")

        tracker.start(lane: 0, index: 2, noteID: 7, startTime: 1.0, endTime: 3.0)
        XCTAssertEqual(tracker.state(for: 7), .active)
        XCTAssertTrue(tracker.isActive(lane: 0))
        XCTAssertEqual(tracker.state(for: 99), .notStarted, "unrelated notes stay notStarted")

        _ = tracker.release(lane: 0, at: 3.05)   // at/after the tail → completed
        XCTAssertEqual(tracker.state(for: 7), .completed)
        XCTAssertFalse(tracker.isActive(lane: 0))
    }

    @MainActor
    func testEarlyReleaseIsDistinctFromMiss() {
        var tracker = HoldTracker()
        tracker.start(lane: 1, index: 3, noteID: 8, startTime: 1.0, endTime: 3.0)
        let result = tracker.release(lane: 1, at: 1.8)!
        XCTAssertFalse(result.completed)
        XCTAssertEqual(tracker.state(for: 8), .releasedEarly)

        // A head that was never touched is a plain miss — a different state.
        tracker.markMissed(noteID: 9)
        XCTAssertEqual(tracker.state(for: 9), .missed)
    }

    @MainActor
    func testReleaseGraceAtTailCompletes() {
        var tracker = HoldTracker()
        tracker.start(lane: 2, index: 0, noteID: 1, startTime: 1.0, endTime: 3.0)
        // Releasing 40ms before the tail still completes (default 60ms grace).
        let result = tracker.release(lane: 2, at: 2.96)!
        XCTAssertTrue(result.completed)
        XCTAssertEqual(tracker.state(for: 1), .completed)
    }

    @MainActor
    func testTickCompletion() {
        var tracker = HoldTracker()
        tracker.start(lane: 3, index: 5, noteID: 10, startTime: 1.0, endTime: 3.0)
        let hold = tracker.complete(lane: 3)
        XCTAssertEqual(hold?.noteID, 10)
        XCTAssertEqual(tracker.state(for: 10), .completed)
        // Completing an empty lane is a safe no-op.
        XCTAssertNil(tracker.complete(lane: 0))
    }

    @MainActor
    func testProgressIsMonotonicAndClamped() {
        var tracker = HoldTracker()
        tracker.start(lane: 0, index: 0, noteID: 1, startTime: 1.0, endTime: 3.0)
        XCTAssertEqual(tracker.progress(lane: 0, at: 1.0)!, 0, accuracy: 0.0001)
        XCTAssertEqual(tracker.progress(lane: 0, at: 2.0)!, 0.5, accuracy: 0.0001)
        XCTAssertEqual(tracker.progress(lane: 0, at: 3.0)!, 1, accuracy: 0.0001)
        XCTAssertEqual(tracker.progress(lane: 0, at: 5.0)!, 1, accuracy: 0.0001, "clamped past the tail")
        XCTAssertEqual(tracker.progress(lane: 0, at: 0.5)!, 0, accuracy: 0.0001, "clamped before the head")
        XCTAssertNil(tracker.progress(lane: 1, at: 2.0), "no progress for lanes without an active hold")
    }

    @MainActor
    func testCancelAllClearsEveryHoldState() {
        var tracker = HoldTracker()
        tracker.start(lane: 0, index: 0, noteID: 1, startTime: 1.0, endTime: 3.0)
        tracker.start(lane: 1, index: 1, noteID: 2, startTime: 1.0, endTime: 4.0)
        tracker.markMissed(noteID: 3)
        tracker.cancelAll()
        XCTAssertTrue(tracker.active.isEmpty)
        XCTAssertEqual(tracker.state(for: 1), .notStarted, "no stale state after pause/restart/song change")
        XCTAssertEqual(tracker.state(for: 2), .notStarted)
        XCTAssertEqual(tracker.state(for: 3), .notStarted)
    }

    @MainActor
    func testOneActiveHoldPerLane() {
        var tracker = HoldTracker()
        tracker.start(lane: 0, index: 0, noteID: 1, startTime: 1.0, endTime: 3.0)
        tracker.start(lane: 0, index: 2, noteID: 2, startTime: 2.0, endTime: 4.0)
        XCTAssertEqual(tracker.active.count, 1, "a later head in the same lane replaces the earlier hold")
        XCTAssertEqual(tracker.active[0]?.noteID, 2)
    }

    @MainActor
    func testInvalidHoldIsRejected() {
        var tracker = HoldTracker()
        XCTAssertNil(tracker.start(lane: 0, index: 0, noteID: 1, startTime: 3.0, endTime: 3.0))
        XCTAssertNil(tracker.start(lane: 0, index: 0, noteID: 1, startTime: 4.0, endTime: 3.0))
        XCTAssertTrue(tracker.active.isEmpty)
    }

    // MARK: - Chord behavior

    @MainActor
    func testSchedulerNeverDoubleJudgesChordVoices() {
        // Two chord voices (same time, different lanes): each lane's tap must
        // resolve to its OWN note — no stealing, no double judgment.
        let notes = [
            ChartNote(id: 0, time: 2.0, lane: 0, duration: 0, type: .tap, strength: 1),
            ChartNote(id: 1, time: 2.0, lane: 2, duration: 0, type: .tap, strength: 1),
        ]
        let chart = Chart(songID: UUID(), difficulty: .medium, chartVersion: 3, seed: 1,
                          notes: notes, generatedAt: Date(), nps: 1, duration: 10,
                          difficultyScore: 4, validationWarnings: [], generationDuration: 0)
        let scheduler = NoteScheduler(chart: chart)

        let lane0 = scheduler.nearest(in: 0, to: 2.0, window: 0.2)!
        let lane2 = scheduler.nearest(in: 2, to: 2.0, window: 0.2)!
        XCTAssertEqual(lane0.note.id, 0)
        XCTAssertEqual(lane2.note.id, 1)

        scheduler.mark(lane0.index, judgment: .perfect)
        XCTAssertEqual(scheduler.judgment(for: lane0.index), .perfect)
        XCTAssertNil(scheduler.judgment(for: lane2.index), "the other voice is untouched")

        // Judged notes are no longer eligible — a second tap finds nothing.
        XCTAssertNil(scheduler.nearest(in: 0, to: 2.0, window: 0.2))
        XCTAssertNotNil(scheduler.nearest(in: 2, to: 2.0, window: 0.2))
    }

    @MainActor
    func testChordComboCountsEachVoiceOnce() {
        var score = ScoreManager()
        score.apply(.perfect)   // voice 1
        score.apply(.perfect)   // voice 2
        score.apply(.miss)
        XCTAssertEqual(score.comboCount, 0)
        XCTAssertEqual(score.counts[.perfect], 2, "both voices count, neither is lost")
        XCTAssertEqual(score.counts[.miss], 1)
    }

    // MARK: - Configurable hold scoring

    @MainActor
    func testHoldBonusIsConfigurable() {
        var score = ScoreManager()
        score.apply(.perfect)
        let before = score.score
        score.completeHold(bonus: 250)
        XCTAssertEqual(score.score - before, 250, "the configured bonus is used")

        // The default (500) still works for existing callers.
        var score2 = ScoreManager()
        score2.apply(.perfect)
        let before2 = score2.score
        score2.completeHold()
        XCTAssertEqual(score2.score - before2, 500)
    }

    @MainActor
    func testHoldBonusNeverNegative() {
        var score = ScoreManager()
        score.completeHold(bonus: -100)
        XCTAssertEqual(score.score, 0, "a negative configured bonus adds nothing")
    }

    // MARK: - Chord haptic decision

    @MainActor
    func testChordVoiceDetection() {
        let notes = [
            ChartNote(id: 0, time: 2.0, lane: 0, duration: 0, type: .tap, strength: 1),
            ChartNote(id: 1, time: 2.05, lane: 1, duration: 0, type: .tap, strength: 1),
            ChartNote(id: 2, time: 4.0, lane: 2, duration: 0, type: .tap, strength: 1),
        ]
        // The predicate used by the engine (via scheduler.sortedNotes).
        func isChord(_ note: ChartNote) -> Bool {
            notes.contains { $0.id != note.id && abs($0.time - note.time) < 0.1 }
        }
        XCTAssertTrue(isChord(notes[0]))
        XCTAssertTrue(isChord(notes[1]))
        XCTAssertFalse(isChord(notes[2]), "a solo note is not a chord voice")
    }
}