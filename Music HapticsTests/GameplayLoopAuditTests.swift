import Foundation
import XCTest
@testable import Music_Haptics

/// Proof that gameplay owns exactly ONE live loop per session. Rapid
/// Play → Restart → Restart → Exit → Play must never stack timers, audio
/// clocks, autoplay cursors or haptic schedulers, and every restart must
/// cancel the previous session before the next one starts.
///
/// The engine runs on an injected stub clock (no real audio hardware), so
/// these tests are fast and deterministic on any host; the production path
/// injects the real AVAudioPlayer-backed clock by default.
final class GameplayLoopAuditTests: XCTestCase {

    @MainActor
    func testRapidPlayRestartRestartExitPlayKeepsOneLoop() throws {
        let engine = Self.makeEngine()

        // Play.
        engine.start()
        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.debugActiveTimerCount, 1, "exactly one gameplay loop after start")
        let genAfterPlay = engine.debugLoopGeneration

        // Restart #1 — the previous session must be cancelled first.
        engine.restart()
        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.debugActiveTimerCount, 1, "restart must not stack a second loop")
        XCTAssertGreaterThan(engine.debugLoopGeneration, genAfterPlay,
                             "restart must start a NEW loop identity, not reuse the old timer")
        XCTAssertEqual(engine.currentTime, 0, accuracy: 0.001, "restart rewinds the audio clock")
        XCTAssertEqual(engine.scoreValue, 0, "restart resets score")
        XCTAssertEqual(engine.comboCount, 0, "restart resets combo")

        // Restart #2 — still exactly one loop.
        engine.restart()
        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.debugActiveTimerCount, 1)
        XCTAssertEqual(engine.scoreValue, 0)

        // Exit — the loop must die with the session.
        engine.cleanup()
        XCTAssertEqual(engine.debugActiveTimerCount, 0, "cleanup must kill the loop")
        XCTAssertEqual(engine.state, .ready, "a cleaned engine is never 'playing'")

        // Play again — a fresh single loop.
        engine.start()
        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.debugActiveTimerCount, 1)
        engine.cleanup()
        XCTAssertEqual(engine.debugActiveTimerCount, 0)
    }

    @MainActor
    func testDoubleStartNeverStacksLoops() throws {
        let engine = Self.makeEngine()

        engine.start()
        engine.start()   // double start while playing must restart, not stack
        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.debugActiveTimerCount, 1)
        engine.start()   // and again
        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.debugActiveTimerCount, 1)
        engine.cleanup()
    }

    @MainActor
    func testPauseResumeReusesTheSameLoop() throws {
        let engine = Self.makeEngine()

        engine.start()
        let gen = engine.debugLoopGeneration
        XCTAssertEqual(engine.debugActiveTimerCount, 1)

        engine.pause()
        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(engine.debugActiveTimerCount, 1, "pause keeps the (inert) loop, never spawns a new one")
        engine.pause()   // double pause = no-op
        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(engine.debugLoopGeneration, gen, "pause must not create a new loop identity")

        engine.resume()
        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.debugActiveTimerCount, 1)
        XCTAssertEqual(engine.debugLoopGeneration, gen, "resume must reuse the existing loop")
        engine.cleanup()
    }

    @MainActor
    func testRestartWhilePausedResetsCleanly() throws {
        let engine = Self.makeEngine()

        engine.start()
        engine.pause()
        engine.restart()   // restart from pause
        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.debugActiveTimerCount, 1)
        XCTAssertEqual(engine.currentTime, 0, accuracy: 0.001)
        engine.cleanup()
    }

    /// A judged note can never be judged twice: score/combo/haptics/feedback
    /// all fire exactly once, and the judgment time is recorded for the hit
    /// effect (the 80–150 ms HIT state needs it to run from the exact tap
    /// instant).
    @MainActor
    func testDuplicateTapJudgesExactlyOnce() throws {
        let player = MutableStubAudioPlayer()
        let engine = GameEngine(audioURL: URL(fileURLWithPath: "/tmp/loop-audit-stub.wav"),
                                songTitle: "Loop Audit", chart: Self.makeChart(),
                                analysis: nil, settings: SettingsStore(), practice: nil,
                                player: player)
        engine.start()

        // Jump the clock to the first note (t = 1.0, lane 0).
        player.now = 1.0
        engine.handleTap(lane: 0)
        XCTAssertEqual(engine.counts[.perfect] ?? 0, 1)
        XCTAssertEqual(engine.comboCount, 1)
        XCTAssertEqual(engine.feedback.count, 1)
        let scoreAfterFirst = engine.scoreValue

        // Same lane, same moment, twice more — the note is already judged,
        // so nothing may change.
        engine.handleTap(lane: 0)
        engine.handleTap(lane: 0)
        XCTAssertEqual(engine.counts[.perfect] ?? 0, 1, "duplicate taps must not re-judge")
        XCTAssertEqual(engine.comboCount, 1)
        XCTAssertEqual(engine.feedback.count, 1)
        XCTAssertEqual(engine.scoreValue, scoreAfterFirst)

        // Judgment time recorded on the audio clock for the hit effect.
        let visible = engine.visibleNotes(at: 1.0)
        let hit = visible.first { $0.note.id == 0 }
        XCTAssertNotNil(hit, "judged note must still be visible for its hit effect")
        XCTAssertEqual(hit?.judgedAt ?? -1, 1.0, accuracy: 0.001)

        engine.cleanup()
    }

    /// A three-note chord tapped simultaneously: every voice is judged
    /// exactly once, score/combo count every voice, each voice gets its own
    /// feedback entry (its own visual burst), and re-taps change nothing.
    @MainActor
    func testChordSimultaneousTapsJudgeEachVoiceExactlyOnce() throws {
        let player = MutableStubAudioPlayer()
        let engine = GameEngine(audioURL: URL(fileURLWithPath: "/tmp/loop-audit-stub.wav"),
                                songTitle: "Chord Audit", chart: Self.makeChordChart(),
                                analysis: nil, settings: SettingsStore(), practice: nil,
                                player: player)
        engine.start()
        player.now = 1.0   // the chord

        engine.handleTap(lane: 0)
        engine.handleTap(lane: 1)
        engine.handleTap(lane: 2)

        // Every voice judged exactly once, no stealing, no double-counting.
        XCTAssertEqual(engine.counts[.perfect] ?? 0, 3)
        XCTAssertEqual(engine.comboCount, 3)
        XCTAssertEqual(engine.scoreValue, 3000, "3 × 1000 at multiplier 1")
        // Each voice produced its OWN feedback entry (per-tile burst).
        XCTAssertEqual(engine.feedback.count, 3)
        XCTAssertEqual(Set(engine.feedback.map(\.lane)), [0, 1, 2])

        // Per-note state is independent: distinct IDs, all judged perfect.
        let visible = engine.visibleNotes(at: 1.0)
        for id in [0, 1, 2] {
            let note = visible.first { $0.note.id == id }
            XCTAssertNotNil(note, "chord note \(id) missing")
            XCTAssertEqual(note?.judged, .perfect, "chord voice \(id) not judged")
        }
        // The next note (t = 2.0) is untouched by the chord taps.
        let next = visible.first { $0.note.id == 3 }
        XCTAssertEqual(next?.judged, nil)

        // Re-tapping the chord lanes changes nothing (idempotent).
        engine.handleTap(lane: 0)
        engine.handleTap(lane: 1)
        engine.handleTap(lane: 2)
        XCTAssertEqual(engine.counts[.perfect] ?? 0, 3)
        XCTAssertEqual(engine.comboCount, 3)
        XCTAssertEqual(engine.feedback.count, 3)
        XCTAssertEqual(engine.scoreValue, 3000)

        engine.cleanup()
    }

    /// A partial chord tap (one voice) must NOT consume the other voices:
    /// they stay unjudged and remain individually hittable afterwards.
    @MainActor
    func testPartialChordTapLeavesOtherVoicesUnjudged() throws {
        let player = MutableStubAudioPlayer()
        let engine = GameEngine(audioURL: URL(fileURLWithPath: "/tmp/loop-audit-stub.wav"),
                                songTitle: "Chord Audit", chart: Self.makeChordChart(),
                                analysis: nil, settings: SettingsStore(), practice: nil,
                                player: player)
        engine.start()
        player.now = 1.0

        // Only lane 1 is tapped — lanes 0 and 2 must stay untouched.
        engine.handleTap(lane: 1)
        XCTAssertEqual(engine.counts[.perfect] ?? 0, 1)
        XCTAssertEqual(engine.comboCount, 1)
        let after = engine.visibleNotes(at: 1.0)
        XCTAssertEqual(after.first { $0.note.id == 0 }?.judged, nil, "un-tapped voice was consumed")
        XCTAssertEqual(after.first { $0.note.id == 1 }?.judged, .perfect)
        XCTAssertEqual(after.first { $0.note.id == 2 }?.judged, nil, "un-tapped voice was consumed")

        // The remaining voices are still hittable — individually.
        engine.handleTap(lane: 0)
        engine.handleTap(lane: 2)
        XCTAssertEqual(engine.counts[.perfect] ?? 0, 3)
        XCTAssertEqual(engine.comboCount, 3)
        XCTAssertEqual(engine.feedback.count, 3)

        engine.cleanup()
    }

    // MARK: - Fixtures

    @MainActor
    private static func makeEngine() -> GameEngine {
        GameEngine(audioURL: URL(fileURLWithPath: "/tmp/loop-audit-stub.wav"),
                   songTitle: "Loop Audit", chart: Self.makeChart(),
                   analysis: nil, settings: SettingsStore(), practice: nil,
                   player: StubAudioPlayer())
    }

    /// Three-note chord at t = 1.0 (lanes 0/1/2) plus a solo note at t = 2.0.
    private static func makeChordChart() -> Chart {
        var chart = Chart(songID: UUID(), difficulty: .medium, chartVersion: ChartStorage.chartVersion,
                          seed: 1, notes: [], generatedAt: Date(timeIntervalSince1970: 0),
                          nps: 0, duration: 8, difficultyScore: 5,
                          validationWarnings: [], generationDuration: 0)
        chart.notes = [ChartNote(id: 0, time: 1.0, lane: 0, duration: 0, type: .tap, strength: 1),
                       ChartNote(id: 1, time: 1.0, lane: 1, duration: 0, type: .tap, strength: 1),
                       ChartNote(id: 2, time: 1.0, lane: 2, duration: 0, type: .tap, strength: 1),
                       ChartNote(id: 3, time: 2.0, lane: 0, duration: 0, type: .tap, strength: 1)]
        return chart
    }

    private static func makeChart() -> Chart {
        var chart = Chart(songID: UUID(), difficulty: .medium, chartVersion: ChartStorage.chartVersion,
                          seed: 1, notes: [], generatedAt: Date(timeIntervalSince1970: 0),
                          nps: 0, duration: 8, difficultyScore: 5,
                          validationWarnings: [], generationDuration: 0)
        chart.notes = [ChartNote(id: 0, time: 1.0, lane: 0, duration: 0, type: .tap, strength: 0.5),
                       ChartNote(id: 1, time: 2.0, lane: 2, duration: 0, type: .tap, strength: 0.5)]
        return chart
    }
}

/// Instant fake clock: no AVAudioPlayer, no audio hardware. Play/pause/resume/
/// seek just flip a flag and move a number, exactly like the real clock's
/// observable behavior, so the engine's loop/state logic is fully exercised.
/// Stub with an externally settable clock, for judging taps at exact times.
@MainActor
private final class MutableStubAudioPlayer: AudioPlayer {
    var now: Double = 0

    override var currentTime: Double { now }
    override var duration: Double { 30 }
    override var volume: Float {
        get { 1 }
        set {}
    }

    override func load(url: URL) throws { now = 0 }
    override func play(from time: Double = 0) { now = time }
    override func pause() {}
    override func resume() {}
    override func seek(to time: Double) { now = time }
    override func stop() { now = 0 }
    override func setRate(_ rate: Double) {}
}

@MainActor
private final class StubAudioPlayer: AudioPlayer {
    private var time: Double = 0
    private var playing = false

    override var currentTime: Double { time }
    override var duration: Double { 30 }
    override var volume: Float {
        get { 1 }
        set {}
    }

    override func load(url: URL) throws {
        time = 0
        playing = false
    }

    override func play(from time: Double = 0) {
        self.time = time
        playing = true
    }

    override func pause() { playing = false }

    override func resume() { playing = true }

    override func seek(to time: Double) { self.time = time }

    override func stop() {
        time = 0
        playing = false
    }

    override func setRate(_ rate: Double) {}
}