import XCTest
@testable import Music_Haptics

/// Deterministic practice-mode tests. The live engine uses the SAME formulas
/// (PracticeClock + NoteScheduler windows + AutoplaySimulation) with
/// AVAudioPlayer's device clock; here everything runs on a scripted clock
/// with no audio, so every result is reproducible.
final class PracticeModeTests: XCTestCase {

    // MARK: - Speed scaling (the clock math AudioPlayer uses)

    func testSpeedScalesContentTime() {
        // 2 real seconds at 0.5× → 1 content second.
        XCTAssertEqual(PracticeClock.contentTime(anchorContent: 0, anchorDevice: 0, nowDevice: 2, rate: 0.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(PracticeClock.contentTime(anchorContent: 0, anchorDevice: 0, nowDevice: 2, rate: 0.75), 1.5, accuracy: 1e-9)
        XCTAssertEqual(PracticeClock.contentTime(anchorContent: 0, anchorDevice: 0, nowDevice: 2, rate: 1.0), 2.0, accuracy: 1e-9)
    }

    func testRateChangeKeepsClockContinuous() {
        // 0.5× for 4 real s → content 2.0; re-anchor there, then 1.0× for 1 real s → 3.0.
        let t1 = PracticeClock.contentTime(anchorContent: 0, anchorDevice: 0, nowDevice: 4, rate: 0.5)
        XCTAssertEqual(t1, 2.0, accuracy: 1e-9)
        let t2 = PracticeClock.contentTime(anchorContent: t1, anchorDevice: 4, nowDevice: 5, rate: 1.0)
        XCTAssertEqual(t2, 3.0, accuracy: 1e-9)
    }

    func testPauseFreezesAndResumeContinuesFromCorrectTimeline() {
        // Play 2 real s at 0.5× (content 1.0) → pause for 10 real s (content
        // must stay 1.0 — the device clock runs on) → resume re-anchors →
        // 2 more real s at 0.5× → content 2.0. This is exactly the
        // anchor/seek sequence AudioPlayer performs on pause/resume.
        let beforePause = PracticeClock.contentTime(anchorContent: 0, anchorDevice: 0, nowDevice: 2, rate: 0.5)
        XCTAssertEqual(beforePause, 1.0, accuracy: 1e-9)
        // While paused the player reports player.currentTime (content 1.0).
        let pausedContent = 1.0
        // Resume re-anchors at (1.0, device 12).
        let afterResume = PracticeClock.contentTime(anchorContent: pausedContent, anchorDevice: 12, nowDevice: 14, rate: 0.5)
        XCTAssertEqual(afterResume, 2.0, accuracy: 1e-9)
    }

    func testWallDurationAtReducedSpeed() {
        XCTAssertEqual(PracticeClock.wallDuration(contentSeconds: 6, rate: 0.5), 12.0, accuracy: 1e-9)
        XCTAssertEqual(PracticeClock.wallDuration(contentSeconds: 6, rate: 0.75), 8.0, accuracy: 1e-9)
        XCTAssertEqual(PracticeClock.wallDuration(contentSeconds: 6, rate: 1.0), 6.0, accuracy: 1e-9)
    }

    // MARK: - Loop decision

    func testLoopDecisionAtSectionEnd() {
        XCTAssertTrue(PracticeClock.shouldRestartLoop(contentTime: 19.98, sectionEnd: 20, loop: true))
        XCTAssertFalse(PracticeClock.shouldRestartLoop(contentTime: 19.9, sectionEnd: 20, loop: true))
        // Already past the end (e.g. a frame hiccup) → still restarts.
        XCTAssertTrue(PracticeClock.shouldRestartLoop(contentTime: 25, sectionEnd: 20, loop: true))
        XCTAssertFalse(PracticeClock.shouldRestartLoop(contentTime: 25, sectionEnd: 20, loop: false))
    }

    // MARK: - Section window (NoteScheduler)

    @MainActor
    func testSchedulerWindowExcludesOutsideNotes() {
        let chart = makeChart(notes: [(1, 0), (2, 1), (3, 2), (4, 3), (5, 0)])
        let scheduler = NoteScheduler(chart: chart, timeWindow: 2...4)

        // Notes outside the window are inactive.
        XCTAssertFalse(scheduler.isActive(0))
        XCTAssertTrue(scheduler.isActive(1))
        XCTAssertTrue(scheduler.isActive(3))
        XCTAssertFalse(scheduler.isActive(4))

        // Rendering only returns in-window notes.
        let rendered = scheduler.notes(in: 0...6)
        XCTAssertEqual(rendered.map { $0.note.time }, [2, 3, 4])

        // Taps can never match out-of-window notes (5.0 lies outside 2...4).
        XCTAssertNil(scheduler.nearest(in: 0, to: 1.0, window: 0.5))
        XCTAssertNil(scheduler.nearest(in: 0, to: 5.0, window: 0.5))
        // …but the note at 2 IS hittable.
        XCTAssertEqual(scheduler.nearest(in: 1, to: 2.0, window: 0.5)?.note.time, 2)
        XCTAssertEqual(scheduler.nextUnjudged(after: 1.5)?.note.time, 2)
        XCTAssertNil(scheduler.nextUnjudged(after: 4.5))

        // Out-of-window notes never miss: only in-window notes 2, 3, 4 expire;
        // the note at 5 (outside the section) must not leak into the misses.
        XCTAssertEqual(scheduler.pendingMisses(before: 2.41, window: 0.4).map { scheduler.sortedNotes[$0].time }, [2])
        XCTAssertEqual(scheduler.pendingMisses(before: 6, window: 0.4).map { scheduler.sortedNotes[$0].time }, [3, 4])
    }

    @MainActor
    func testHoldsAndChordsWorkInsideWindow() {
        // Hold: head at 2.0 (lane 1, duration 1.0). Chord: lanes 0+2 at 4.0.
        var notes: [ChartNote] = []
        notes.append(ChartNote(id: 0, time: 2.0, lane: 1, duration: 1.0, type: .hold, strength: 0.8))
        notes.append(ChartNote(id: 1, time: 4.0, lane: 0, duration: 0, type: .tap, strength: 0.7))
        notes.append(ChartNote(id: 2, time: 4.0, lane: 2, duration: 0, type: .tap, strength: 0.7))
        var chart = makeChart(notes: [])
        chart.notes = notes

        let scheduler = NoteScheduler(chart: chart, timeWindow: 1.5...5.0)
        // Hold head is hittable; sustain state lives in the engine, the
        // scheduler just marks the head.
        let holdHead = scheduler.nearest(in: 1, to: 2.02, window: 0.3)
        XCTAssertEqual(holdHead?.note.type, .hold)
        scheduler.mark(holdHead!.index, judgment: .perfect)
        // Both chord voices are independently hittable at the same timestamp.
        let voiceA = scheduler.nearest(in: 0, to: 4.0, window: 0.3)
        let voiceB = scheduler.nearest(in: 2, to: 4.0, window: 0.3)
        XCTAssertEqual(voiceA?.note.time, 4.0)
        XCTAssertEqual(voiceB?.note.time, 4.0)
        XCTAssertNotEqual(voiceA?.index, voiceB?.index)
    }

    // MARK: - Section simulation (whole-chart practice runs)

    @MainActor
    func testSectionSimulationIsDeterministicAndRestartsCleanly() {
        let chart = makeChart(notes: [(1, 0), (2, 1), (3, 2), (4, 3), (5, 0), (6, 1)])
        let config = AutoplaySimulation.Config(timeWindow: 2...5)
        let run1 = AutoplaySimulation.run(chart: chart, config: config)
        let run2 = AutoplaySimulation.run(chart: chart, config: config)
        // Same window → identical result every time (loop reps / restarts are
        // byte-identical too: fresh state each run).
        XCTAssertEqual(run1.score, run2.score)
        XCTAssertEqual(run1.perfectCount, run2.perfectCount)
        XCTAssertEqual(run1.missCount, run2.missCount)
        // Only in-window notes were played (2, 3, 4, 5 — the window is inclusive).
        XCTAssertEqual(run1.perfectCount, 4)
        XCTAssertEqual(run1.missCount, 0)
    }

    @MainActor
    func testHoldCompletesInsidePracticeSection() {
        var notes: [ChartNote] = []
        notes.append(ChartNote(id: 0, time: 2.0, lane: 0, duration: 1.0, type: .hold, strength: 0.8))
        notes.append(ChartNote(id: 1, time: 5.0, lane: 2, duration: 0, type: .tap, strength: 0.6))
        var chart = makeChart(notes: [])
        chart.notes = notes
        let result = AutoplaySimulation.run(chart: chart, config: AutoplaySimulation.Config(timeWindow: 1.5...5.5))
        XCTAssertEqual(result.perfectCount, 2)
        XCTAssertEqual(result.holdsCompleted, 1)
        XCTAssertEqual(result.missCount, 0)
    }

    @MainActor
    func testChordIsHitInPracticeSection() {
        var notes: [ChartNote] = []
        notes.append(ChartNote(id: 0, time: 3.0, lane: 0, duration: 0, type: .tap, strength: 0.7))
        notes.append(ChartNote(id: 1, time: 3.0, lane: 3, duration: 0, type: .tap, strength: 0.7))
        var chart = makeChart(notes: [])
        chart.notes = notes
        let result = AutoplaySimulation.run(chart: chart, config: AutoplaySimulation.Config(timeWindow: 2.0...4.0))
        XCTAssertEqual(result.perfectCount, 2)
        XCTAssertEqual(result.missCount, 0)
    }

    @MainActor
    func testEarlyHoldReleaseMissesInsideSection() {
        var notes: [ChartNote] = []
        notes.append(ChartNote(id: 0, time: 2.0, lane: 1, duration: 1.0, type: .hold, strength: 0.8))
        var chart = makeChart(notes: [])
        chart.notes = notes
        let result = AutoplaySimulation.run(chart: chart,
                                            config: AutoplaySimulation.Config(holdReleaseOffset: -0.3,
                                                                               timeWindow: 1.0...4.0))
        // Early release forfeits the hold (combo break) but keeps the head
        // judgment — matching the engine's hold semantics exactly.
        XCTAssertEqual(result.holdsMissed, 1)
        XCTAssertEqual(result.missCount, 0)
        // The head tap still counted: combo reached 1 before the break.
        XCTAssertEqual(result.maxCombo, 1)
    }

    // MARK: - Practice stats

    func testPracticeStatsAccuracyAndTiming() {
        var stats = PracticeStats()
        stats.record(judgment: .perfect, deltaMs: 1.0)
        stats.record(judgment: .great, deltaMs: -20.0)
        stats.record(judgment: .good, deltaMs: 45.0)
        stats.record(judgment: .miss, deltaMs: 120.0)
        XCTAssertEqual(stats.hitCount, 4)
        XCTAssertEqual(stats.meanAbsDeltaMs, 46.5, accuracy: 1e-9)
        XCTAssertEqual(stats.accuracy, (1 + 0.75 + 0.5) / 4, accuracy: 1e-9)
        XCTAssertEqual(stats.perfectCount, 1)
        XCTAssertEqual(stats.missCount, 1)
    }

    // MARK: - Fixtures

    private func makeChart(notes: [(time: Double, lane: Int)]) -> Chart {
        Chart(songID: UUID(), difficulty: .medium, chartVersion: 4, seed: 0xABCD,
              notes: notes.enumerated().map { i, n in
                  ChartNote(id: i, time: n.time, lane: n.lane, duration: 0, type: .tap, strength: 0.5)
              },
              generatedAt: Date(timeIntervalSince1970: 0), nps: 1, duration: 10,
              difficultyScore: 5, validationWarnings: [], generationDuration: 0.01)
    }
}