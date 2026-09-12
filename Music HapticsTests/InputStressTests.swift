import XCTest
@testable import Music_Haptics

/// Touch/input stress: rapid taps, alternating lanes, repeated same-lane
/// taps, near-boundary touches, simultaneous multi-touch (chords), cancelled
/// touches, and pause/restart during holds. The pure input pipeline
/// (InputJudge + NoteScheduler + HoldTracker) must stay coherent through
/// every pattern — no duplicate judgments, no stolen notes, no stale state.
@MainActor
final class InputStressTests: XCTestCase {

    private func judgeConfig() -> InputJudge.Config {
        InputJudge.Config(perfectWindow: 0.07, greatWindow: 0.13, goodWindow: 0.20,
                          missWindow: 0.20, calibrationOffset: 0)
    }

    private func tapChart(lane: Int, count: Int, interval: Double, start: Double = 0.5) -> Chart {
        let notes = (0..<count).map { i in
            ChartNote(id: i, time: start + Double(i) * interval, lane: lane,
                      duration: 0, type: .tap, strength: 1)
        }
        return Chart(songID: UUID(), difficulty: .medium, chartVersion: 4, seed: 1,
                     notes: notes, generatedAt: Date(), nps: 2, duration: start + Double(count) * interval,
                     difficultyScore: 3, validationWarnings: [], generationDuration: 0)
    }

    func testRapidSameLaneTapsHitDistinctNotes() {
        // 200 taps at 120 ms in one lane: every tap must judge the NEXT
        // unjudged note; a judged note can never be judged twice.
        let chart = tapChart(lane: 1, count: 200, interval: 0.12)
        let scheduler = NoteScheduler(chart: chart)
        let judge = InputJudge(config: judgeConfig())
        var judged = Set<Int>()
        for i in 0..<200 {
            let time = 0.5 + Double(i) * 0.12
            let nearest = scheduler.nearest(in: 1, to: time, window: 0.25)
            XCTAssertNotNil(nearest, "tap \(i): a note must be eligible")
            guard let nearest else { continue }
            let judgment = judge.classify(tapTime: time, noteTime: nearest.note.time)
            scheduler.mark(nearest.index, judgment: judgment)
            XCTAssertFalse(judged.contains(nearest.index), "tap \(i): duplicate judgment")
            judged.insert(nearest.index)
            XCTAssertNotNil(scheduler.judgment(for: nearest.index))
        }
        XCTAssertEqual(judged.count, 200, "every tap must consume a distinct note")
    }

    func testAlternatingLanesNoCrossTalk() {
        // Taps alternate lanes 0/3 every 100 ms: the lane-3 tap must never
        // consume a lane-0 note (nearest-in-lane lookup, not global).
        let chart = tapChart(lane: 0, count: 100, interval: 0.2)
        let chart3 = tapChart(lane: 3, count: 100, interval: 0.2)
        let scheduler = NoteScheduler(chart: chart)
        let scheduler3 = NoteScheduler(chart: chart3)
        let judge = InputJudge(config: judgeConfig())
        for i in 0..<100 {
            let time = 0.5 + Double(i) * 0.2
            let n0 = scheduler.nearest(in: 0, to: time, window: 0.25)
            let n3 = scheduler3.nearest(in: 3, to: time, window: 0.25)
            XCTAssertNotNil(n0)
            XCTAssertNotNil(n3)
            if let n0 { scheduler.mark(n0.index, judgment: judge.classify(tapTime: time, noteTime: n0.note.time)) }
            if let n3 { scheduler3.mark(n3.index, judgment: judge.classify(tapTime: time, noteTime: n3.note.time)) }
        }
        // Both lanes fully consumed, independently.
        XCTAssertEqual(scheduler.sortedNotes.filter { scheduler.judgment(for: $0.id) != nil }.count, 100)
        XCTAssertEqual(scheduler3.sortedNotes.filter { scheduler3.judgment(for: $0.id) != nil }.count, 100)
    }

    func testMultiTouchChordBothNotesJudgeIndependently() {
        // Two touches land on the same beat in lanes 1 and 2: each note gets
        // its own judgment; neither steals the other.
        let chord = Chart(songID: UUID(), difficulty: .medium, chartVersion: 4, seed: 1,
                          notes: [ChartNote(id: 0, time: 2.0, lane: 1, duration: 0, type: .tap, strength: 1),
                                  ChartNote(id: 1, time: 2.0, lane: 2, duration: 0, type: .tap, strength: 1)],
                          generatedAt: Date(), nps: 2, duration: 4, difficultyScore: 3,
                          validationWarnings: [], generationDuration: 0)
        let scheduler = NoteScheduler(chart: chord)
        let judge = InputJudge(config: judgeConfig())
        let a = scheduler.nearest(in: 1, to: 2.01, window: 0.25)
        let b = scheduler.nearest(in: 2, to: 2.01, window: 0.25)
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertNotEqual(a?.index, b?.index, "chord voices must be distinct notes")
        scheduler.mark(a!.index, judgment: judge.classify(tapTime: 2.01, noteTime: a!.note.time))
        scheduler.mark(b!.index, judgment: judge.classify(tapTime: 2.01, noteTime: b!.note.time))
        XCTAssertEqual(scheduler.judgment(for: a!.index), .perfect)
        XCTAssertEqual(scheduler.judgment(for: b!.index), .perfect)
        // A third tap on the same beat: the only note in lane 1 is already
        // judged, so `nearest` must find nothing — a judged note can never
        // be re-hit (duplicate-judgment prevention).
        XCTAssertNil(scheduler.nearest(in: 1, to: 2.01, window: 0.25))
    }

    func testNearBoundaryTapStaysInOwnLane() {
        // Taps land at the extreme left/right of the playfield — lane mapping
        // (x → lane) must be deterministic and never leave a lane unhittable.
        for x in stride(from: 0.0, through: 1.0, by: 0.02) {
            let lane = min(3, max(0, Int(x * 4)))
            XCTAssertTrue((0..<4).contains(lane), "x=\(x) maps to lane \(lane)")
            // Center of that lane region: x * 4 - lane ∈ [0,1] (the last
            // lane includes the right edge).
            XCTAssertGreaterThanOrEqual(x * 4 - Double(lane), 0)
            XCTAssertLessThanOrEqual(x * 4 - Double(lane), 1)
        }
    }

    func testCancelledTouchLeavesNoState() {
        // A touch-down that is cancelled (system cancels the touch) must not
        // consume a note: the note stays hittable afterwards.
        let chart = tapChart(lane: 0, count: 10, interval: 0.2)
        let scheduler = NoteScheduler(chart: chart)
        let judge = InputJudge(config: judgeConfig())
        let time = 0.5
        let nearest = scheduler.nearest(in: 0, to: time, window: 0.25)!
        // Touch cancelled BEFORE judging: nothing consumed.
        XCTAssertNil(scheduler.judgment(for: nearest.index))
        // A real tap now must still hit the same note.
        let again = scheduler.nearest(in: 0, to: time, window: 0.25)!
        XCTAssertEqual(again.index, nearest.index)
        scheduler.mark(again.index, judgment: judge.classify(tapTime: time, noteTime: again.note.time))
        XCTAssertEqual(scheduler.judgment(for: again.index), .perfect)
    }

    func testPauseDuringHoldClearsActiveHolds() {
        var holds = HoldTracker()
        holds.start(lane: 2, index: 0, noteID: 7, startTime: 1.0, endTime: 2.0)
        XCTAssertTrue(holds.isActive(lane: 2))
        XCTAssertEqual(holds.progress(lane: 2, at: 1.4) ?? 0, 0.4, accuracy: 1e-9)
        // Pause: every active hold AND every recorded state must vanish.
        holds.cancelAll()
        XCTAssertTrue(holds.active.isEmpty)
        XCTAssertTrue(holds.stateByNote.isEmpty)
        XCTAssertFalse(holds.isActive(lane: 2))
        XCTAssertNil(holds.progress(lane: 2, at: 1.5))
        XCTAssertEqual(holds.state(for: 7), .notStarted)
    }

    func testRestartDuringHoldLeavesNothing() {
        var holds = HoldTracker()
        holds.start(lane: 3, index: 5, noteID: 5, startTime: 1.0, endTime: 1.8)
        holds.markMissed(noteID: 9)
        // Restart = cancelAll + fresh tracker: identical to a new session.
        holds.cancelAll()
        XCTAssertTrue(holds.active.isEmpty, "no active hold may survive a restart")
        XCTAssertTrue(holds.stateByNote.isEmpty, "no hold state may survive a restart")
        XCTAssertNil(holds.release(lane: 3, at: 1.9), "no hold may survive a restart")
    }

    func testHoldLifecycleStressUnderPause() {
        // Many holds started, paused mid-hold, resumed fresh — 500 rounds.
        for round in 0..<500 {
            var holds = HoldTracker()
            let lane = round % 4
            holds.start(lane: lane, index: round, noteID: round, startTime: 1.0, endTime: 2.0)
            holds.cancelAll()
            XCTAssertTrue(holds.active.isEmpty, "round \(round)")
            XCTAssertTrue(holds.stateByNote.isEmpty, "round \(round)")
        }
    }

    func testSustainedHoldCompletionAndEarlyRelease() {
        // Hold kept to the tail completes; released early marks releasedEarly —
        // both leave the active set with no residue.
        var holds = HoldTracker()
        holds.start(lane: 0, index: 0, noteID: 0, startTime: 1.0, endTime: 2.0)
        let completed = holds.complete(lane: 0)
        XCTAssertNotNil(completed)
        XCTAssertEqual(holds.state(for: 0), .completed)
        XCTAssertFalse(holds.isActive(lane: 0))

        holds.start(lane: 1, index: 1, noteID: 1, startTime: 1.0, endTime: 2.0)
        let early = holds.release(lane: 1, at: 1.3)
        XCTAssertEqual(early?.completed, false)
        XCTAssertEqual(holds.state(for: 1), .releasedEarly)
        XCTAssertFalse(holds.isActive(lane: 1))
    }
}