import XCTest
@testable import Music_Haptics

/// Hit-targeting behaviour that decides whether a tap registers: the whole
/// lane is the target, nearby notes win within the window, judged notes are
/// never re-hit, and other-lane notes are never stolen.
@MainActor
final class InputSchedulingTests: XCTestCase {

    private func chart(_ notes: [ChartNote]) -> Chart {
        Chart(songID: UUID(), difficulty: .medium, chartVersion: 1, seed: 1,
              notes: notes, generatedAt: Date(), nps: 0, duration: 10,
              difficultyScore: 5, validationWarnings: [], generationDuration: 0)
    }

    private func note(_ id: Int, time: Double, lane: Int) -> ChartNote {
        ChartNote(id: id, time: time, lane: lane, duration: 0, type: .tap, strength: 1)
    }

    func testTapAnywhereInLaneTimeWindowFindsNearestNote() {
        let scheduler = NoteScheduler(chart: chart([note(0, time: 5.0, lane: 1)]))
        // Early, center, and late taps within ±0.2 s all resolve to the note.
        XCTAssertEqual(scheduler.nearest(in: 1, to: 4.85, window: 0.2)?.index, 0)
        XCTAssertEqual(scheduler.nearest(in: 1, to: 5.0, window: 0.2)?.index, 0)
        XCTAssertEqual(scheduler.nearest(in: 1, to: 5.18, window: 0.2)?.index, 0)
        // Beyond the window: no hit.
        XCTAssertNil(scheduler.nearest(in: 1, to: 4.5, window: 0.2))
    }

    func testJudgedNotesAreNeverRehit() {
        let scheduler = NoteScheduler(chart: chart([note(0, time: 5.0, lane: 2),
                                                    note(1, time: 5.16, lane: 2)]))
        XCTAssertEqual(scheduler.nearest(in: 2, to: 5.02, window: 0.2)?.index, 0)
        scheduler.mark(0, judgment: .great)
        // A second tap near the judged note must move to the next unjudged one.
        XCTAssertEqual(scheduler.nearest(in: 2, to: 5.05, window: 0.2)?.index, 1)
    }

    /// A MISSED note can never be judged as a hit afterwards — even by a tap
    /// aimed exactly at its time, in its own lane, with a generous window.
    func testMissedNoteCanNeverBeJudgedAsHit() {
        let scheduler = NoteScheduler(chart: chart([note(0, time: 5.0, lane: 1)]))
        // The note passes unjudged; the game declares the miss.
        let misses = scheduler.pendingMisses(before: 5.2, window: 0.15)
        XCTAssertEqual(misses, [0])
        scheduler.mark(0, judgment: .miss, at: 5.2)
        XCTAssertEqual(scheduler.judgment(for: 0), .miss)
        XCTAssertEqual(scheduler.judgmentTime(for: 0) ?? -1, 5.2, accuracy: 0.0001)
        // Any later tap (even a huge window) can never resolve to the missed
        // note — it is invisible to the hit path.
        XCTAssertNil(scheduler.nearest(in: 1, to: 5.0, window: 2.0))
        XCTAssertNil(scheduler.nearest(in: 1, to: 5.2, window: 2.0))
        // The miss is never re-declared: pendingMisses advances past it.
        XCTAssertEqual(scheduler.pendingMisses(before: 9.0, window: 0.15), [])
        // (mark is deliberately last-write-wins — hold early-release rewrites
        // the head's state to .miss for the red visual while the score keeps
        // the original head judgment — so a re-mark at 9.0 would carry 9.0.)
        scheduler.mark(0, judgment: .miss, at: 9.0)
        XCTAssertEqual(scheduler.judgment(for: 0), .miss)
        XCTAssertEqual(scheduler.judgmentTime(for: 0) ?? -1, 9.0, accuracy: 0.0001)
        XCTAssertNil(scheduler.nearest(in: 1, to: 5.0, window: 2.0),
                     "even after a re-mark the note stays unhittable")
    }

    func testNearestNoteWinsInsideWindow() {
        // Two notes 0.25 s apart in the same lane: taps in between pick the
        // closest one, never both, and a repeat tap never double-judges.
        let scheduler = NoteScheduler(chart: chart([note(0, time: 4.0, lane: 0),
                                                    note(1, time: 4.25, lane: 0)]))
        let early = scheduler.nearest(in: 0, to: 4.02, window: 0.2)
        XCTAssertEqual(early?.index, 0)
        let late = scheduler.nearest(in: 0, to: 4.23, window: 0.2)
        XCTAssertEqual(late?.index, 1)
    }

    func testTapsNeverStealFromOtherLanes() {
        let scheduler = NoteScheduler(chart: chart([note(0, time: 5.0, lane: 3)]))
        // Tapping lane 2 near the same time must NOT hit the lane-3 note.
        XCTAssertNil(scheduler.nearest(in: 2, to: 5.0, window: 0.2))
        XCTAssertEqual(scheduler.nearest(in: 3, to: 5.0, window: 0.2)?.index, 0)
    }

    /// Chord voices have fully independent judgment state: judging one voice
    /// never touches its chord partner, and each keeps its own stable index
    /// and ID throughout.
    func testChordVoicesHaveIndependentJudgmentState() {
        let scheduler = NoteScheduler(chart: chart([note(10, time: 5.0, lane: 1),
                                                    note(11, time: 5.0, lane: 2),
                                                    note(12, time: 5.0, lane: 3)]))
        // Both queries resolve to their OWN voice (no cross-lane stealing).
        let a = scheduler.nearest(in: 1, to: 5.0, window: 0.2)
        let b = scheduler.nearest(in: 2, to: 5.0, window: 0.2)
        XCTAssertEqual(a?.index, 0)
        XCTAssertEqual(b?.index, 1)
        XCTAssertEqual(a?.note.id, 10)
        XCTAssertEqual(b?.note.id, 11)

        // Judge voice A: voice B stays unjudged with its state intact.
        scheduler.mark(a!.index, judgment: .perfect, at: 5.0)
        XCTAssertEqual(scheduler.judgment(for: 0), .perfect)
        XCTAssertEqual(scheduler.judgment(for: 1), nil)
        XCTAssertEqual(scheduler.judgmentTime(for: 0) ?? -1, 5.0, accuracy: 0.0001)
        XCTAssertEqual(scheduler.judgmentTime(for: 1), nil)

        // Voice B is still hittable and resolves to its own note.
        let again = scheduler.nearest(in: 2, to: 5.01, window: 0.2)
        XCTAssertEqual(again?.index, 1)
        XCTAssertEqual(again?.note.id, 11)
        XCTAssertEqual(again?.note.lane, 2)

        // Judging voice B does not disturb voice A.
        scheduler.mark(again!.index, judgment: .great, at: 5.01)
        XCTAssertEqual(scheduler.judgment(for: 0), .perfect)
        XCTAssertEqual(scheduler.judgment(for: 1), .great)
        XCTAssertEqual(scheduler.judgment(for: 2), nil)
    }

    func testForgivingWindowStillRespectsBoundaries() {
        let scheduler = NoteScheduler(chart: chart([note(0, time: 10.0, lane: 1),
                                                    note(1, time: 11.0, lane: 1)]))
        // A tap 0.35 s before the next note (outside the ~0.24 s window) hits nothing.
        XCTAssertNil(scheduler.nearest(in: 1, to: 10.32, window: 0.24))
    }
}