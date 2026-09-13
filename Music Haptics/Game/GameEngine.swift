import Combine
import CoreGraphics
import Foundation

/// Orchestrates a playthrough: audio clock, note scheduling, judging, scoring,
/// haptics, and state transitions. Owned by GameView (MainActor by default).
@MainActor
final class GameEngine: ObservableObject {
    // Workaround for swiftlang/swift#87316 (see StatsManager).
    deinit {}
    // Inputs
    private let audioURL: URL
    private let songTitle: String
    private let chart: Chart
    private let analysis: AudioAnalysis?
    private let settings: SettingsStore
    private let practice: PracticeConfig?

    // Subsystems
    private let player: AudioPlayer
    private let haptics = HapticEngine()
    private var scheduler: NoteScheduler?
    private var judge: InputJudge?
    private var score = ScoreManager()
    private var hapticScheduler: HapticScheduler?
    /// Active haptic profile (from settings), cached per run.
    private var hapticProfile: HapticProfile {
        HapticProfileStore.profile(for: settings.hapticProfile)
    }
    /// Effective reduced-haptics flag: the setting, plus automatic reduction
    /// when the system's Reduce Motion accessibility preference is on. The
    /// view sets this before the run starts.
    private var effectiveReducedHaptics: Bool

    /// Accessibility hook: force softer/quieter haptics (no miss feedback)
    /// when the user's system accessibility preferences ask for reduced
    /// sensory effects. Safe to call before or during a run.
    func setReducedHaptics(_ reduced: Bool) {
        effectiveReducedHaptics = reduced
    }

    /// Called (main actor) when a VoiceOver-worthy gameplay event happens:
    /// misses, hold completions, combo milestones, pause. The view installs a
    /// handler that posts UIAccessibility announcements, throttled — the
    /// engine only reports events; it never touches UIKit itself.
    var announcementHandler: ((String) -> Void)?
    /// Highest combo milestone already announced (reset per run).
    private var lastAnnouncedComboMilestone = 0

    /// Combo numbers worth announcing: 10, 25, then every 50.
    private func isComboMilestone(_ combo: Int) -> Bool {
        combo == 10 || combo == 25 || combo % 50 == 0
    }
    private var timer: Timer?
    /// Monotonic gameplay-loop identity. Every `start()` (and every `cleanup()`)
    /// bumps it; the timer closure only ticks while its captured generation
    /// still matches, so a stale loop can never drive — or overlap — a newer
    /// session. This is the guarantee that exactly one gameplay loop exists.
    private var loopGeneration = 0
    private var endTime: Double = 0
    private var resulted = false

    // UI-observable state
    @Published private(set) var state: GameplayState = .ready
    /// Audio-clock position. Deliberately NOT @Published: publishing it at
    /// tick cadence invalidated the entire view tree 60×/s (the HUD and
    /// background diffed every frame even when nothing visible changed) —
    /// a primary stutter source. The renderer reads the extrapolated clock
    /// via TimelineView; the HUD reads the coarse `displayProgress`.
    private(set) var currentTime: Double = 0
    /// Coarse song-position fraction (0…1) for the HUD progress bar.
    /// Updated only when it moves ≥0.25% (~4 updates per 5-minute song) so
    /// HUD updates never drive view-tree invalidation at frame cadence.
    @Published private(set) var displayProgress: Double = 0
    @Published private(set) var scoreValue = 0
    @Published private(set) var comboCount = 0
    @Published private(set) var maxCombo = 0
    @Published private(set) var counts: [Judgment: Int] = [:]
    @Published private(set) var feedback: [JudgmentFeedback] = []
    @Published private(set) var laneFlashes: [LaneFlash] = []
    @Published private(set) var holdPopups: [HoldPopup] = []
    @Published private(set) var result: GameplayResult?
    @Published var lastError: String?

    // MARK: - Practice mode

    /// Live practice feedback (accuracy + mean |timing error|). Practice
    /// sessions never produce official records.
    @Published private(set) var practiceStats = PracticeStats()
    /// Detected song sections offered by the practice bar (empty = none).
    private(set) var practiceSections: [PracticeSection] = []
    /// Currently focused section (nil = whole song).
    @Published private(set) var practiceSection: PracticeSection?
    @Published private(set) var practiceSpeed = 1.0
    @Published private(set) var practiceLoopEnabled = false
    @Published private(set) var practiceShowTiming = false

    var isPractice: Bool { practice != nil }
    var practiceShowScore: Bool { practice?.showScore ?? true }
    var practiceShowCombo: Bool { practice?.showCombo ?? true }

    // MARK: - Hold-note state

    /// Explicit hold lifecycle (notStarted/active/completed/missed/releasedEarly)
    /// plus active-hold progress. `cancelAll` runs on every state transition
    /// (pause, restart, song change, practice jump), so no stale hold survives.
    private var holds = HoldTracker()
    /// Lanes the player's fingers are physically down on.
    private var touchesDown = Set<Int>()
    /// Last time a note haptic fired (chord voices don't stack feedback).
    private var lastNoteHapticAt: Double = -1

    /// Developer autoplay (simulator/validation): notes are hit automatically
    /// at their exact timestamps through the SAME tap→judgment pipeline as real
    /// touches, on the REAL audio clock. Never fakes time; production timing is
    /// untouched. The UI toggle is Debug-only.
    @Published private(set) var isAutoplay = false
    private var autoplayCursor = 0

    /// Compact replay recording (all builds). Every judgment moment appends
    /// one event; practice and developer-autoplay runs are excluded when the
    /// caller saves a replay.
    private(set) var replayEvents: [ReplayEvent] = []

    /// Live audio-clock position; the view reads this every frame.
    var audioTime: Double { player.currentTime }
    /// Rendering and judgment projection anchor: the audio time the player
    /// is actually HEARING right now. `player.currentTime` is the scheduled
    /// decoder position; sound physically leaves the speaker
    /// `outputLatency` later. Tiles must land on what the ear hears, so
    /// visual projection (and nothing else) leads by that amount.
    var renderTime: Double { player.currentTime - player.outputLatency }
    /// Playback rate (practice speed) — the render clock extrapolates at
    /// this multiplier between logic ticks.
    var clockRate: Double { player.rate }

    // MARK: - Render clock anchor

    /// Anchor mapping wall-clock → audio-clock for the renderer, refreshed
    /// by every logic tick (~16 ms). Between ticks the view extrapolates:
    /// `t = anchorAudio + (now − anchorDate) × rate`. Timer fire jitter (±4
    /// ms on a heavily loaded main thread) therefore smooths out instead of
    /// appearing as tile judder — tiles advance continuously with the
    /// display refresh while the game RULES stay on the deterministic
    /// engine tick. Seek/practice-jump/pause all re-anchor on their next
    /// tick; the view additionally freezes to the anchor when not playing.
    private(set) var renderAnchorDate: Double = 0
    /// Audio (heard) time captured at `renderAnchorDate`.
    private(set) var renderAnchorAudio: Double = 0
    var duration: Double { player.duration > 0 ? player.duration : chart.duration }
    /// Note travel time: the user's note-speed base, scaled by the song's BPM
    /// (faster music falls quicker) and clamped to stay readable.
    var approachTime: Double {
        NoteMovement.leadTime(bpm: analysis?.tempoBPM, base: settings.noteApproachTime)
    }

    /// Lead time in effect at audio time `t`: the song's global lead modulated
    /// by the LOCAL tempo around `t` (smoothed, ±12%). This is the single
    /// source of truth for tile speed — the renderer's projection, the spawn
    /// window and the spatial touch catch all read it, so tiles, hit detection
    /// and what the player sees always agree. Subtle by design: the user's
    /// Note Speed setting dominates; the music adds the breathing.
    func dynamicLead(at time: Double) -> Double {
        // The renderer evaluates this once per frame per tile. The median
        // window scan is cheap but not free — cache by frame step so a single
        // frame reuses one computation instead of recomputing per note.
        if let cached = leadCache, abs(time - leadCacheTime) < 0.02 { return cached }
        let lead = computeDynamicLead(at: time)
        leadCache = lead
        leadCacheTime = time
        return lead
    }

    private var leadCache: Double?
    private var leadCacheTime: Double = -1

    private func computeDynamicLead(at time: Double) -> Double {
        guard let beats = analysis?.beats, !beats.isEmpty else { return approachTime }
        let globalBeatInterval: Double
        if let bpm = analysis?.tempoBPM, bpm > 20, bpm < 300 {
            globalBeatInterval = 60 / bpm
        } else if beats.count >= 2 {
            globalBeatInterval = medianBeatInterval(in: beats)
        } else {
            return approachTime
        }
        return NoteMovement.dynamicLeadTime(at: time, beats: beats,
                                            globalBeatInterval: globalBeatInterval,
                                            baseLead: approachTime)
    }

    /// Median of consecutive beat intervals — robust to one dropped/extra beat.
    private func medianBeatInterval(in beats: [Beat]) -> Double {
        guard beats.count >= 2 else { return 0.5 }
        var intervals = zip(beats.dropFirst(), beats).map { $0.0.time - $0.1.time }
            .filter { $0 >= NoteMovement.localFloorBeatInterval }
        guard !intervals.isEmpty else { return 0.5 }
        intervals.sort()
        return intervals.count % 2 == 1
            ? intervals[intervals.count / 2]
            : (intervals[intervals.count / 2 - 1] + intervals[intervals.count / 2]) / 2
    }
    var multiplier: Int { score.multiplier }

    /// 0…1 subtle background pulse that fires when the audio clock crosses a
    /// detected beat. Purely decorative; gameplay never depends on it.
    private(set) var beatPulse: Double = 0

    // MARK: - Timing diagnostics (Debug builds)

    #if DEBUG
    /// One frame of render telemetry: audio-clock time, next-note countdown and
    /// main-loop frame cadence measured with a monotonic uptime clock (never
    /// used as the gameplay clock — only to show render jitter).
    struct DebugTick: Sendable {
        let audioTime: Double
        let chartDuration: Double
        let frameIntervalMs: Double
        let avgFrameMs: Double
        let maxFrameMs: Double
        let nextNoteInMs: Double?   // ms until the next unjudged note's time
    }

    /// One judged note: note timestamp vs the actual tap time on the audio
    /// clock, including calibration. `deltaMs` is the measured timing error.
    struct DebugHit: Identifiable, Sendable {
        let id = UUID()
        let judgment: Judgment
        let noteTime: Double
        let tapTime: Double
        let deltaMs: Double   // (tapTime + calibration − noteTime) in ms
    }

    /// One raw touch: lane, normalized position, audio-clock time, and the
    /// note it judged (nil = no eligible note in the window).
    struct DebugTouch: Sendable {
        let lane: Int
        let x: Double
        let y: Double
        let audioTime: Double
        let noteID: Int?
        let judged: Judgment?
        let deltaMs: Double?
    }

    @Published private(set) var debugTick: DebugTick?
    @Published private(set) var debugHits: [DebugHit] = []
    @Published private(set) var debugOverlayVisible = false
    @Published private(set) var debugChartMode = false
    @Published private(set) var debugAnchorLog: [String] = []
    @Published private(set) var debugLastTouch: DebugTouch?

    private var frameStats = RollingStats()
    private var hitDeltaStats = RollingStats()
    private var lastTickUptime: Double = 0
    private var lastFrameMs: Double = 0

    /// Unique identity for THIS playthrough. Every async/observable path
    /// belongs to one session; stale work (old audio callbacks, leftover
    /// autoplay loops, pending haptic schedules) is invalidated with it.
    let sessionID = UUID()

    /// Exactly one gameplay loop may be live at a time: 1 while the current
    /// session's timer is valid, 0 after cleanup/finish. Exposed for the
    /// loop-audit tests and the diagnostics overlay.
    var debugActiveTimerCount: Int { (timer?.isValid ?? false) ? 1 : 0 }

    /// Testing hook: runs exactly one logic tick on demand (the live timer
    /// is unpredictable in tests). Same guard as the real loop.
    func tickForTesting() {
        tick()
    }
    /// Bumped on every start/cleanup; a tick only runs for the current value.
    var debugLoopGeneration: Int { loopGeneration }

    func toggleDebugOverlay() {
        debugOverlayVisible.toggle()
    }

    /// Cycles the DEBUG overlays: off → timing → chart structure → off.
    /// The chart-structure mode draws beats, onsets, section boundaries and
    /// the chart's own notes on the playfield so it's immediately clear
    /// whether the analyzer, the generator or the renderer is at fault.
    func cycleDebugOverlay() {
        if debugOverlayVisible {
            debugOverlayVisible = false
            debugChartMode = true
        } else if debugChartMode {
            debugChartMode = false
        } else {
            debugOverlayVisible = true
        }
    }

    /// Analysis data surfaced for the DEBUG chart-structure overlay.
    var debugBeats: [Beat] { analysis?.beats ?? [] }
    var debugEvents: [MusicalEvent] { analysis?.events ?? [] }
    var debugSections: [SongSection] { analysis?.sections ?? [] }
    var debugChartNotes: [ChartNote] { chart.notes }

    var debugCalibrationOffsetMs: Double { settings.calibrationOffsetMs }
    var debugMeanAbsDeltaMs: Double { hitDeltaStats.mean }
    var debugHitCount: Int { hitDeltaStats.count }

    private func resetDebugTelemetry() {
        frameStats.reset()
        hitDeltaStats.reset()
        lastTickUptime = 0
        lastFrameMs = 0
        debugTick = nil
        debugHits = []
        debugAnchorLog = []
    }

    /// Records an anchor event (start/pause/resume/restart) with the audio
    /// clock position so a clock discontinuity can be spotted in the console.
    private func logAnchor(_ event: String, audioTime: Double) {
        let entry = "\(event)@\(String(format: "%.3f", audioTime))s"
        print("[Timing] \(entry)")
        debugAnchorLog.append(entry)
        if debugAnchorLog.count > 8 { debugAnchorLog.removeFirst(debugAnchorLog.count - 8) }
    }

    private func recordDebugHit(judgment: Judgment, noteTime: Double, tapTime: Double) {
        // The SAME latency compensation the judgment used — the telemetry
        // must reflect what the grader saw, or the overlay lies.
        let adjusted = isAutoplay ? tapTime : tapTime - player.outputLatency + settings.calibrationOffsetMs / 1000
        let deltaMs = (adjusted - noteTime) * 1000
        hitDeltaStats.add(abs(deltaMs))
        let hit = DebugHit(judgment: judgment, noteTime: noteTime, tapTime: adjusted, deltaMs: deltaMs)
        debugHits.append(hit)
        if debugHits.count > 40 { debugHits.removeFirst(debugHits.count - 40) }
        print(String(format: "[Timing] %@ note=%.3fs tap=%.3fs Δ%+.1fms (out-lat %.0fms calib %+.0fms)",
                     judgment.displayName, noteTime, adjusted, deltaMs,
                     player.outputLatency * 1000, settings.calibrationOffsetMs))
    }

    private func recordDebugTick(audioTime t: Double) {
        let uptime = ProcessInfo.processInfo.systemUptime
        if lastTickUptime > 0 {
            lastFrameMs = (uptime - lastTickUptime) * 1000
            frameStats.add(lastFrameMs)
        }
        lastTickUptime = uptime
        let nextNoteInMs: Double? = scheduler?.nextUnjudged(after: t).map { ($0.note.time - t) * 1000 }
        debugTick = DebugTick(audioTime: t,
                              chartDuration: duration,
                              frameIntervalMs: lastFrameMs,
                              avgFrameMs: frameStats.mean,
                              maxFrameMs: frameStats.max,
                              nextNoteInMs: nextNoteInMs)
    }
    #endif

    /// Generation tier of this session's chart (1…4; nil = pre-tier charts).
    var chartFallbackTier: Int? { chart.fallbackTier }
    /// Notes currently on screen (rendering-load bound for the overlay).
    var activeNoteCount: Int {
        guard let scheduler else { return 0 }
        let t = player.currentTime
        return scheduler.notes(in: (t - 2.6)...(t + dynamicLead(at: t) + 0.4)).count
    }

    /// `player` is injectable so tests can drive the engine with a fast stub
    /// clock instead of real audio hardware (deterministic, host-independent);
    /// nil (production) uses the real AVAudioPlayer-backed clock.
    init(audioURL: URL, songTitle: String, chart: Chart, analysis: AudioAnalysis?,
         settings: SettingsStore, practice: PracticeConfig? = nil,
         player: AudioPlayer? = nil) {
        self.audioURL = audioURL
        self.songTitle = songTitle
        self.chart = chart
        self.analysis = analysis
        self.settings = settings
        self.practice = practice
        self.player = player ?? AudioPlayer()
        self.effectiveReducedHaptics = settings.reducedHaptics
    }

    // MARK: - Lifecycle

    func start() {
        lastAnnouncedComboMilestone = 0
        // Restart safety FIRST: kill any live loop from a previous session
        // before doing anything else — a stale timer can never tick (or
        // overlap) the new session.
        timer?.invalidate()
        timer = nil
        // Re-entrancy safety: starting over an active session (double-start)
        // tears the old one down first so exactly one playback session exists;
        // a finished run also restarts cleanly.
        if state == .playing || state == .paused || state == .finished {
            cleanup()
        }
        // New loop identity: ticks only run for THIS generation.
        loopGeneration += 1
        let generation = loopGeneration
        lastError = nil
        resulted = false
        replayEvents = []
        state = .ready
        do {
            try player.load(url: audioURL)
        } catch {
            lastError = "Couldn't load audio for playback."
            state = .finished
            return
        }

        let timing = InputJudge.Config(
            perfectWindow: settings.perfectWindowMs / 1000,
            greatWindow: settings.greatWindowMs / 1000,
            goodWindow: settings.goodWindowMs / 1000,
            missWindow: settings.goodWindowMs / 1000,
            calibrationOffset: settings.calibrationOffsetMs / 1000
        )
        judge = InputJudge(config: timing)

        // Practice setup: rate, section window, loop target, stats, sections.
        if let practice {
            player.setRate(practice.speed)
            practiceSpeed = practice.speed
            practiceLoopEnabled = practice.loopSection
            practiceSection = practice.section
            practiceShowTiming = practice.showTiming
            practiceStats = PracticeStats()
            practiceSections = analysis?.sections.map {
                PracticeSection(id: $0.index, label: $0.label.displayName,
                                start: $0.start, end: $0.end, energy: $0.energy)
            } ?? []
        }
        let window: ClosedRange<Double>? = practice?.section.map { $0.start...$0.end }
        scheduler = NoteScheduler(chart: chart, timeWindow: window)
        score = ScoreManager()
        feedback = []
        laneFlashes = []
        holdPopups = []
        counts = [:]
        result = nil
        currentTime = 0
        beatPulse = 0
        beatIndex = 0
        autoplayCursor = 0   // autoplay mode survives restarts; the cursor rewinds
        holds.cancelAll()
        touchesDown = []

        player.volume = Float(settings.volume)
        haptics.cooldownMs = hapticProfile.minIntervalMs
        haptics.prepare()
        if settings.rhythmHapticsEnabled, let analysis {
            hapticScheduler = HapticScheduler(haptics: haptics,
                                              profile: hapticProfile,
                                              beats: analysis.beats,
                                              accents: analysis.events,
                                              sections: analysis.sections,
                                              strengthScale: settings.hapticStrength)
        } else {
            hapticScheduler = nil
        }

        if let practice, let section = practice.section {
            // Section practice: finish at the section end — or keep looping.
            endTime = practice.loopSection
                ? max(chart.lastNoteTime + 2.0, section.end + 2.0)
                : section.end - 0.05
        } else {
            endTime = min(duration - 0.4, chart.lastNoteTime + 2.0)
        }

        player.play(from: 0)
        state = .playing
        // Output latency is measurable once the session/route is live; the
        // session activation from load() may still be in flight, so sample
        // now and again shortly after — the EMA converges within ~3 reads.
        player.measureOutputLatency()
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run { [weak self] in self?.player.measureOutputLatency() }
        }
        #if DEBUG
        resetDebugTelemetry()
        logAnchor("start", audioTime: player.currentTime)
        #endif
        timer?.invalidate()
        // Runs on the main run loop (scheduled from MainActor context), so the
        // closure IS main-actor-isolated — calling tick() directly avoids
        // allocating a Task per frame (~60 allocations/s of gameplay). The
        // generation guard makes stale loops inert even if invalidation ever
        // raced a newer session.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self, generation] _ in
            MainActor.assumeIsolated {
                guard let self, self.loopGeneration == generation else { return }
                self.tick()
            }
        }
    }

    func pause() {
        guard state == .playing else { return }
        player.pause()
        hapticScheduler?.stop()
        // Held notes are released by pausing (the finger is gone). The head tap
        // keeps its judgment — only the hold bonus is forfeited, no combo break.
        holds.cancelAll()
        touchesDown.removeAll()
        state = .paused
        announcementHandler?("Paused")
        #if DEBUG
        logAnchor("pause", audioTime: player.currentTime)
        #endif
    }

    func resume() {
        guard state == .paused else { return }
        player.resume()
        hapticScheduler?.reset()
        state = .playing
        #if DEBUG
        logAnchor("resume", audioTime: player.currentTime)
        #endif
    }

    func restart() {
        cleanup()
        start()
        #if DEBUG
        logAnchor("restart", audioTime: player.currentTime)
        #endif
    }

    func cleanup() {
        // Kill the loop BEFORE tearing subsystems down, and bump the
        // generation so even an already-queued tick can never act after
        // teardown (belt-and-suspenders over invalidation).
        timer?.invalidate()
        timer = nil
        loopGeneration += 1
        player.stop()
        haptics.stopAll()
        hapticScheduler = nil
        holds.cancelAll()
        touchesDown.removeAll()
        // A cleaned engine is never "playing"; leave it in the neutral ready
        // state so a later start() is uniform and no stale .playing/.finished
        // state can confuse observers of a disposed session.
        state = .ready
        resulted = false
        result = nil
    }

    // MARK: - Practice controls

    /// Jumps the audio to a section start and fully resets practice state
    /// (notes, score/combo, judgments, haptic schedule, holds, touches) so
    /// nothing from the previous section leaks. Score resets because practice
    /// sessions are never official records. Works while playing or paused.
    func practiceJump(to section: PracticeSection) {
        guard isPractice, state != .finished else { return }
        practiceSection = section
        #if DEBUG
        practiceLoopCount += 1
        logAnchor("practiceJump→\(section.label)@\(String(format: "%.3f", section.start))s",
                  audioTime: player.currentTime)
        #endif
        player.seek(to: section.start)
        rebuildPracticeState()
    }

    /// Restarts the current section (or the whole song when none is focused).
    func practiceRestartSection() {
        guard isPractice else { return }
        if let section = practiceSection {
            practiceJump(to: section)
        } else {
            restart()
        }
    }

    /// Drops the section focus: back to the whole song from its start.
    func practiceSelectWholeSong() {
        guard isPractice, state != .finished else { return }
        practiceSection = nil
        #if DEBUG
        logAnchor("practiceWholeSong@0.000s", audioTime: player.currentTime)
        #endif
        player.seek(to: 0)
        rebuildPracticeState()
        endTime = min(duration - 0.4, chart.lastNoteTime + 2.0)
    }

    /// Changes practice speed live. The audio clock re-anchors, so
    /// `currentTime` stays continuous — notes stay glued to the music.
    func setPracticeSpeed(_ speed: Double) {
        guard isPractice else { return }
        let clamped = min(max(speed, 0.5), 2.0)
        practiceSpeed = clamped
        player.setRate(clamped)
    }

    func setPracticeLoop(_ enabled: Bool) {
        guard isPractice else { return }
        practiceLoopEnabled = enabled
        if let section = practiceSection {
            endTime = enabled
                ? max(chart.lastNoteTime + 2.0, section.end + 2.0)
                : section.end - 0.05
        }
    }

    func togglePracticeTiming() {
        guard isPractice else { return }
        practiceShowTiming.toggle()
    }

    /// Fresh scheduler/score/feedback/haptics after a jump — the same setup
    /// `start()` performs, minus audio reload. State stays as-is (playing or
    /// paused); `seek` re-anchors the clock either way.
    private func rebuildPracticeState() {
        guard isPractice else { return }
        let window: ClosedRange<Double>? = practiceSection.map { $0.start...$0.end }
        scheduler = NoteScheduler(chart: chart, timeWindow: window)
        score = ScoreManager()
        scoreValue = 0
        comboCount = 0
        maxCombo = 0
        counts = [:]
        feedback = []
        laneFlashes = []
        holdPopups = []
        result = nil
        resulted = false
        currentTime = player.currentTime
        beatPulse = 0
        beatIndex = 0
        autoplayCursor = 0
        holds.cancelAll()
        touchesDown = []
        practiceStats = PracticeStats()
        // Rebuild the haptic schedule from the new position — stale patterns
        // from the previous section can never leak into this one.
        hapticScheduler?.stop()
        if settings.rhythmHapticsEnabled, let analysis {
            hapticScheduler = HapticScheduler(haptics: haptics,
                                              profile: hapticProfile,
                                              beats: analysis.beats,
                                              accents: analysis.events,
                                              sections: analysis.sections,
                                              strengthScale: settings.hapticStrength)
        } else {
            hapticScheduler = nil
        }
    }

    // MARK: - Autoplay (developer tool)

    /// Turns simulator autoplay on/off. Enabling mid-song rewinds the cursor so
    /// any still-unjudged note from the current position onward gets hit.
    func setAutoplay(_ enabled: Bool) {
        guard isAutoplay != enabled else { return }
        isAutoplay = enabled
        autoplayCursor = 0
    }

    /// Hits notes the instant their timestamp arrives on the audio clock. The
    /// tap is fed through `judgeTap` — the identical nearest-note/classify path
    /// real touches use — with the note's own timestamp, so judgments come back
    /// ideal (Δ ≈ calibration) and score/combo/haptics all behave as if played.
    /// Hold heads register normally here; the tick below sustains them to the
    /// tail automatically.
    private func autoplayTick(at time: Double) {
        guard let scheduler else { return }
        let notes = scheduler.sortedNotes
        while autoplayCursor < notes.count, notes[autoplayCursor].time <= time + 0.001 {
            let note = notes[autoplayCursor]
            // Skip notes the player already hit or that already missed; the
            // cursor still advances so we never rescan from zero every frame.
            if scheduler.judgment(for: autoplayCursor) == nil,
               let hit = judgeTap(lane: note.lane, at: note.time, point: CGPoint(x: 0.5, y: 1)) {
                registerHoldIfNeeded(hit, at: note.time)
            }
            autoplayCursor += 1
        }
    }

    // MARK: - Input

    /// Handles a touch-down on a lane. `point` is the touch position in the
    /// lane's local coordinate space (normalized 0…1; y=1 is the hit line).
    /// With a real spatial point, the tap is matched against the note whose
    /// VISIBLE TILE is under the finger — tapping the tile you see works.
    /// Without it (autoplay, accessibility), pure time-first matching applies.
    func handleTap(lane: Int, point: CGPoint = SpatialCatch.unspecifiedTouch) {
        guard state == .playing else { return }
        touchesDown.insert(lane)
        let audioTime = player.currentTime
        let hit = judgeTap(lane: lane, at: audioTime, point: point)
        #if DEBUG
        debugLastTouch = DebugTouch(lane: lane, x: point.x, y: point.y, audioTime: audioTime,
                                    noteID: hit?.note.id,
                                    judged: hit.map { scheduler?.judgment(for: $0.index) } ?? nil,
                                    deltaMs: hit.map { (audioTime - player.outputLatency - $0.note.time) * 1000 })
        #endif
        if let hit { registerHoldIfNeeded(hit, at: audioTime) }
    }

    /// Tracks finger movement along its lane (raw touch layer). If the move
    /// lands spatially on the lane's unjudged candidate note's tile, that
    /// note is judged too — sliding across tiles behaves like tapping them.
    func handleLaneMove(lane: Int, point: CGPoint) {
        guard state == .playing,
              let scheduler, let judge else { return }
        let time = player.currentTime
        let candidates = scheduler.nearestPerLane(to: time,
                                                  window: judge.config.goodWindow + InputJudge.Config.edgeGrace)
        guard let candidate = candidates[lane] else { return }
        // Spatial catch uses the per-moment lead, matching the renderer.
        let distance = SpatialCatch.distance(
            noteTime: candidate.note.time, touchTime: time, touchY: Double(point.y),
            leadTime: dynamicLead(at: time), hitLineY: PlayfieldGeometry.hitLineY, topY: PlayfieldGeometry.topY,
            tileHeightFraction: PlayfieldGeometry.tileHeightFraction,
            holdTailTime: candidate.note.type == .hold
                ? candidate.note.time + candidate.note.duration : nil)
        guard distance <= PlayfieldGeometry.spatialCatchDistance else { return }
        let judgment = judge.classifyForgiving(tapTime: time, noteTime: candidate.note.time)
        apply(judgment, index: candidate.index, lane: lane, time: time, strength: candidate.note.strength)
        if judgment != .miss { registerHoldIfNeeded((candidate.note, candidate.index), at: time) }
    }

    /// Handles a touch-up on a lane. Releases any active hold: at (or within
    /// grace of) its tail it completes with the full bonus; an earlier release
    /// banks the fraction of the hold genuinely sustained — partial bonus,
    /// no combo break — instead of the old double penalty.
    /// The release moment uses the same heard-time compensation as taps:
    /// the player releases in response to what they see/hear, which reads
    /// `outputLatency` late on the raw audio clock.
    func handleTouchUp(lane: Int) {
        touchesDown.remove(lane)
        guard state == .playing else { return }
        let releaseTime = isAutoplay ? player.currentTime
            : player.currentTime - player.outputLatency + settings.calibrationOffsetMs / 1000
        guard let result = holds.release(lane: lane, at: releaseTime) else { return }
        if result.completed {
            completeHold(hold: result.hold, at: player.currentTime)
        } else {
            // `release` has already removed the active hold. Pass its measured
            // fraction through explicitly; querying the tracker now would
            // incorrectly report zero and make every early release look empty.
            bankPartialHold(hold: result.hold, progress: result.progress, at: player.currentTime)
        }
    }

    /// An early release banks the fraction of the hold actually sustained:
    /// proportional bonus, no combo break, note marked judged so the lane
    /// is never blocked by a stale hold.
    private func bankPartialHold(hold: HoldTracker.Active, progress: Double, at time: Double) {
        guard let scheduler else { return }
        score.bankPartialHold(progress: progress)
        scheduler.mark(hold.index, judgment: .good, at: time)
        comboCount = score.comboCount
        maxCombo = score.maxCombo
        counts = score.counts
        scoreValue = score.score
        holdPopups.append(HoldPopup(lane: hold.lane, time: time,
                                    points: max(1, Int(Double(settings.holdCompleteBonus) * progress))))
        feedback.append(JudgmentFeedback(judgment: .good, lane: hold.lane, time: time))
        recordReplayEvent(kind: .holdRelease, noteID: hold.noteID, lane: hold.lane,
                          time: time, judgment: .good, noteTime: hold.endTime)
        #if DEBUG
        print(String(format: "[Hold] lane=%d banked %.0f%% at %.3fs", hold.lane, progress * 100, time))
        #endif
    }

    /// The single tap→judgment pipeline, shared by physical touches and
    /// autoplay. Returns the hit note when one was judged. Real input passes
    /// the live audio time; autoplay passes the note's exact timestamp.
    ///
    /// Latency model: the player reacts to sound arriving at
    /// `audioTime − outputLatency` (and their finger→touch event adds a few
    /// ms more). Measuring against the raw `audioTime` bakes that latency in
    /// as systematic lateness that no amount of skill removes — a real
    /// 0 ms tap grades late, and the bias rides the run. Judgment therefore
    /// evaluates taps against the HEARD time (audio minus output latency).
    /// The user's manual calibration still applies on top for whatever
    /// remains (render pipeline delay, player's individual reaction style).
    ///
    /// Spatial matching: with a real touch point, the tap first tries to match
    /// the note whose visible tile lies under the finger (within
    /// `PlayfieldGeometry.spatialCatchDistance`), judged by timing with a
    /// floor of GOOD — tapping the tile you see can never hard-fail. Notes
    /// near the hit line still use pure timing. Autoplay/synthetic taps keep
    /// the pure time-first path.
    private func judgeTap(lane: Int, at time: Double, point: CGPoint) -> (note: ChartNote, index: Int)? {
        guard let scheduler, let judge else { return nil }
        // Autoplay taps at exact chart times (latency 0, calibration must
        // not perturb validation) — keep the pure path bit-identical.
        let heardTime = isAutoplay ? time : time - player.outputLatency + settings.calibrationOffsetMs / 1000
        let window = judge.config.goodWindow + InputJudge.Config.edgeGrace

        // Spatial path: a real finger position tries tile matching first.
        let spatial = point != SpatialCatch.unspecifiedTouch
        if spatial {
            let lead = dynamicLead(at: time)
            let candidates = scheduler.nearestPerLane(to: time, window: max(window, lead))
            if let candidate = candidates[lane] {
                let distance = SpatialCatch.distance(
                    noteTime: candidate.note.time, touchTime: time, touchY: Double(point.y),
                    leadTime: lead, hitLineY: PlayfieldGeometry.hitLineY,
                    topY: PlayfieldGeometry.topY,
                    tileHeightFraction: PlayfieldGeometry.tileHeightFraction,
                    holdTailTime: candidate.note.type == .hold
                        ? candidate.note.time + candidate.note.duration : nil)
                if distance <= PlayfieldGeometry.spatialCatchDistance {
                    // Judgment floor: a tap physically ON a visible tile is
                    // at worst a GOOD — the player aimed correctly; only the
                    // grade reflects timing.
                    let raw = judge.classifyForgiving(tapTime: heardTime, noteTime: candidate.note.time)
                    let judgment: Judgment = raw == .miss ? .good : raw
                    #if DEBUG
                    print(String(format: "[Input] lane=%d touchY=%.2f note=%.3fs audio=%.3fs Δ%+.0fms d=%.2f → %@ (spatial)",
                                 lane, point.y, candidate.note.time, time,
                                 (heardTime - candidate.note.time) * 1000,
                                 distance, judgment.displayName.uppercased()))
                    recordDebugHit(judgment: judgment, noteTime: candidate.note.time,
                                   tapTime: time)
                    #endif
                    recordPracticeHit(judgment: judgment, noteTime: candidate.note.time, tapTime: time)
                    apply(judgment, index: candidate.index, lane: lane, time: time,
                          strength: candidate.note.strength)
                    return (candidate.note, candidate.index)
                }
            }
        }

        // Timing path: notes within the classic window of the hit line,
        // measured against the heard time.
        guard let hit = scheduler.nearest(in: lane, to: heardTime, window: window) else {
            // Tap registered but nothing eligible: log it so a perceived
            // "swallowed" tap is visible in the diagnostics.
            #if DEBUG
            print(String(format: "[Input] lane=%d touchX=%.2f touchY=%.2f audio=%.3fs NO NOTE within %.0fms",
                         lane, point.x, point.y, time, window * 1000))
            #endif
            return nil
        }
        let judgment = judge.classifyForgiving(tapTime: heardTime, noteTime: hit.note.time)
        #if DEBUG
        print(String(format: "[Input] lane=%d touchX=%.2f touchY=%.2f note.lane=%d note=%.3fs audio=%.3fs Δ%+.1fms (heard %.3fs) → %@",
                     lane, point.x, point.y, hit.note.lane, hit.note.time, time,
                     (heardTime - hit.note.time) * 1000, heardTime, judgment.displayName.uppercased()))
        recordDebugHit(judgment: judgment, noteTime: hit.note.time, tapTime: time)
        #endif
        recordPracticeHit(judgment: judgment, noteTime: hit.note.time, tapTime: time)
        apply(judgment, index: hit.index, lane: lane, time: time, strength: hit.note.strength)
        return (hit.note, hit.index)
    }

    // MARK: - Holds

    /// Starts sustaining a hold after its head was hit: notStarted → active,
    /// plus a light "hold started" tick.
    private func registerHoldIfNeeded(_ hit: (note: ChartNote, index: Int), at time: Double? = nil) {
        guard hit.note.type == .hold else { return }
        let endTime = hit.note.time + hit.note.duration
        // A spatial body press can happen before the head reaches the line.
        // The hold must begin when the finger actually goes down, not at the
        // future chart timestamp; otherwise the visible fill jumps forward and
        // a short hold can appear to complete immediately. Autoplay still uses
        // the exact head timestamp.
        let pressTime = min(time ?? player.currentTime, endTime - 0.001)
        guard pressTime < endTime else { return }
        holds.start(lane: hit.note.lane, index: hit.index, noteID: hit.note.id,
                    startTime: pressTime, endTime: endTime)
        if let pattern = HapticPatternGenerator.holdStartPattern(profile: hapticProfile,
                                                                 enabled: settings.hapticsEnabled,
                                                                 strengthScale: settings.hapticStrength) {
            haptics.play(pattern)
        }
        #if DEBUG
        print(String(format: "[Hold] lane=%d head=%.3fs tail=%.3fs (%.2fs)",
                     hit.note.lane, hit.note.time, hit.note.time + hit.note.duration, hit.note.duration))
        #endif
    }

    /// Sustained to the tail: configurable bonus + strong feedback.
    private func completeHold(hold: HoldTracker.Active, at time: Double) {
        let before = score.score
        score.completeHold(bonus: settings.holdCompleteBonus)
        let points = score.score - before
        scoreValue = score.score
        comboCount = score.comboCount
        maxCombo = score.maxCombo
        holdPopups.append(HoldPopup(lane: hold.lane, time: time, points: points))
        announcementHandler?("Hold complete")
        recordReplayEvent(kind: .holdComplete, noteID: hold.noteID, lane: hold.lane,
                          time: time, judgment: nil, noteTime: hold.endTime)
        laneFlashes.append(LaneFlash(lane: hold.lane, time: time, intensity: 0.8))
        if let pattern = HapticPatternGenerator.holdEndPattern(profile: hapticProfile,
                                                               enabled: settings.hapticsEnabled,
                                                               strengthScale: settings.hapticStrength) {
            haptics.play(pattern)
        }
        #if DEBUG
        print(String(format: "[Hold] lane=%d completed at %.3fs (+%d)", hold.lane, time, points))
        #endif
    }

    /// Render queries for holds (the playfield needs to know how to draw one).
    func holdActive(lane: Int) -> Bool { holds.isActive(lane: lane) }
    func holdCompleted(id: Int) -> Bool { holds.state(for: id) == .completed }
    func holdTailTime(lane: Int) -> Double? { holds.activeHold(lane: lane)?.endTime }
    func recordedHoldProgress(id: Int) -> Double? { holds.recordedProgress(noteID: id) }
    /// Explicit lifecycle state for a note (notStarted default).
    func holdState(for noteID: Int) -> HoldState { holds.state(for: noteID) }
    /// 0…1 sustain progress while a hold is active (nil otherwise).
    func holdProgress(lane: Int) -> Double? { holds.progress(lane: lane, at: player.currentTime) }

    // MARK: - Rendering queries

    /// Notes currently on screen, with their judged state (for dimming). The
    /// lower bound reaches back far enough that an active hold (head already
    /// hit, tail still falling) keeps rendering until its tail passes.
    /// Notes currently on screen, with their judged state and (for judged
    /// notes) the audio-clock time of the judgment — the renderer uses it to
    /// play the brief hit effect from the exact moment it happened.
    func visibleNotes(at time: Double) -> [(note: ChartNote, judged: Judgment?, judgedAt: Double?)] {
        guard let scheduler else { return [] }
        let range = (time - 2.6)...(time + dynamicLead(at: time) + 0.4)
        return scheduler.notes(in: range).map {
            ($0.note, scheduler.judgment(for: $0.index), scheduler.judgmentTime(for: $0.index))
        }
    }

    // MARK: - Internals

    private func tick() {
        guard state == .playing, let scheduler, let judge else { return }
        let t = player.currentTime
        currentTime = t
        // Refresh the render anchor (wall → audio mapping for the view).
        renderAnchorDate = Date().timeIntervalSinceReferenceDate
        renderAnchorAudio = t - player.outputLatency
        // Coarse HUD progress: publish only on a real move (≥0.25%).
        let total = duration
        if total > 0 {
            let progress = min(1, max(0, t / total))
            if abs(progress - displayProgress) >= 0.0025 || progress < displayProgress {
                displayProgress = progress
            }
        }
        updateBeatPulse(t)
        #if DEBUG
        recordDebugTick(audioTime: t)
        #endif

        if isAutoplay {
            autoplayTick(at: t)
        }

        // Hold completions: the finger (or autoplay) has sustained past the
        // tail on the audio clock.
        if !holds.active.isEmpty {
            let due = holds.active.filter { t >= $0.value.endTime && (isAutoplay || touchesDown.contains($0.key)) }
            for (lane, _) in due {
                if let hold = holds.complete(lane: lane) {
                    completeHold(hold: hold, at: t)
                }
            }
        }

        for index in scheduler.pendingMisses(before: t, window: judge.config.missWindow) {
            let note = scheduler.sortedNotes[index]
            #if DEBUG
            recordDebugHit(judgment: .miss, noteTime: note.time, tapTime: t)
            #endif
            // isTapDriven: false — a timeout miss is not a tap attempt and
            // must not feed the live timing-bias readout.
            recordPracticeHit(judgment: .miss, noteTime: note.time, tapTime: t, isTapDriven: false)
            if note.type == .hold {
                holds.markMissed(noteID: note.id)   // head never touched → missed
            }
            // Anchor the judgment at the DECLARATION instant (t), not the
            // note's crossing time: the miss tile effect must start only once
            // the game has actually decided the note is missed.
            apply(.miss, index: index, lane: note.lane, time: t, strength: 0)
        }

        // Practice loop: at the section end, restart it with fully reset state.
        if isPractice, let section = practiceSection, practiceLoopEnabled,
           PracticeClock.shouldRestartLoop(contentTime: t, sectionEnd: section.end, loop: true) {
            practiceJump(to: section)
            return
        }

        hapticScheduler?.update(currentTime: t)

        // Effect arrays: prune ONLY when something actually expires. An
        // unconditional removeAll still publishes (empty → empty) and
        // invalidated the view tree every tick even on quiet frames.
        let cutoff = t - 0.8
        if feedback.contains(where: { $0.time < cutoff }) {
            feedback.removeAll { $0.time < cutoff }
        }
        if laneFlashes.contains(where: { $0.time < cutoff }) {
            laneFlashes.removeAll { $0.time < cutoff }
        }
        if holdPopups.contains(where: { $0.time < cutoff }) {
            holdPopups.removeAll { $0.time < cutoff }
        }

        if t >= endTime {
            finish()
        }
    }

    /// Decorative beat pulse for the background; decays each frame.
    private var beatIndex = 0
    private func updateBeatPulse(_ t: Double) {
        guard let beats = analysis?.beats, !beats.isEmpty else {
            beatPulse = max(0, beatPulse - 0.08)
            return
        }
        // Strong beats (or high-strength beats) pulse the background; weak
        // beats barely register — the screen never flashes on every tick.
        var fired: (strength: Double, strong: Bool)?
        while beatIndex < beats.count && beats[beatIndex].time <= t {
            let beat = beats[beatIndex]
            if beat.time >= t - 0.5 { fired = (beat.strength, beat.isStrong) }
            beatIndex += 1
        }
        // Capped pulse rise: a strong beat no longer slams the whole background
        // to full brightness in one frame (that read as a screen flash), and
        // the decay below stays smooth.
        if let beat = fired {
            let target: Double = beat.strong || beat.strength > 0.6 ? 0.55 : 0.22 * beat.strength
            beatPulse = min(target, beatPulse + 0.25)
        }
        beatPulse = max(0, beatPulse - 0.045)
        // Restart tracking after a restart/seek jump.
        if beatIndex > 0, t - beats[beatIndex - 1].time > 1.5 {
            beatIndex = 0
        }
    }

    // MARK: - Section/energy exposure (background reactivity)

    /// 0…1 energy of the section the audio clock is currently in (0.5 when
    /// no sections were detected).
    var currentSectionEnergy: Double {
        guard let sections = analysis?.sections, !sections.isEmpty else { return 0.5 }
        let t = audioTime
        for section in sections where t >= section.start && t < section.end {
            return section.energy
        }
        return sections.last?.energy ?? 0.5
    }

    /// Index of the section the audio clock is in; −1 when none detected.
    var currentSectionIndex: Int {
        guard let sections = analysis?.sections, !sections.isEmpty else { return -1 }
        let t = audioTime
        for section in sections where t >= section.start && t < section.end {
            return section.index
        }
        return sections.last?.index ?? -1
    }

    /// Appends one compact replay event using the same latency-compensated
    /// delta the judge used. Events are ordered by the audio clock; the
    /// ReplayBuilder normalizes order deterministically at save time.
    private func recordReplayEvent(kind: ReplayEventKind, noteID: Int, lane: Int,
                                   time: Double, judgment: Judgment?,
                                   noteTime: Double) {
        let adjusted = isAutoplay ? time : time - player.outputLatency + settings.calibrationOffsetMs / 1000
        let deltaMs = (adjusted - noteTime) * 1000
        replayEvents.append(ReplayEvent(kind: kind,
                                        noteID: noteID,
                                        lane: lane,
                                        time: time,
                                        judgment: judgment,
                                        timingErrorMs: deltaMs,
                                        score: scoreValue,
                                        combo: comboCount))
    }

    /// Timing telemetry for every judged note: practice stats accumulate in
    /// practice; the rolling signed bias feeds the live HUD in all builds.
    /// `isTapDriven` is false for timeout miss declarations — a note nobody
    /// touched must not teach the player they "tap late".
    private func recordPracticeHit(judgment: Judgment, noteTime: Double, tapTime: Double,
                                   isTapDriven: Bool = true) {
        let adjusted = isAutoplay ? tapTime : tapTime - player.outputLatency + settings.calibrationOffsetMs / 1000
        let deltaMs = (adjusted - noteTime) * 1000
        // Live bias telemetry: a rolling signed mean over the player's real
        // tap attempts tells them (and diagnostics) which way they lean.
        if isTapDriven {
            recentTapDeltasMs.append(deltaMs)
            recentTapBiasCount += 1
            if recentTapDeltasMs.count > 16 { recentTapDeltasMs.removeFirst(recentTapDeltasMs.count - 16) }
        }
        guard isPractice else { return }
        practiceStats.record(judgment: judgment, deltaMs: deltaMs)
    }

    /// Rolling signed tap deltas (ms) for live timing feedback.
    private var recentTapDeltasMs: [Double] = []
    /// Number of taps measured for the live bias (gates the HUD display).
    private(set) var recentTapBiasCount = 0
    /// Signed mean of recent tap deltas (ms; + = tending late). The honest
    /// number a calibration suggestion is derived from.
    var recentTapBiasMs: Double {
        guard !recentTapDeltasMs.isEmpty else { return 0 }
        return recentTapDeltasMs.reduce(0, +) / Double(recentTapDeltasMs.count)
    }

    private func apply(_ judgment: Judgment, index: Int, lane: Int, time: Double, strength: Double) {
        guard let scheduler else { return }
        let note = scheduler.sortedNotes[index]
        score.apply(judgment)
        scheduler.mark(index, judgment: judgment, at: time)
        scoreValue = score.score
        comboCount = score.comboCount
        maxCombo = score.maxCombo
        counts = score.counts
        feedback.append(JudgmentFeedback(judgment: judgment, lane: lane, time: time))
        if judgment == .miss {
            announcementHandler?("Miss")
        } else if comboCount >= 2, isComboMilestone(comboCount),
                  comboCount > lastAnnouncedComboMilestone {
            lastAnnouncedComboMilestone = comboCount
            announcementHandler?("Combo \(comboCount)")
        }
        recordReplayEvent(kind: note.type == .hold ? (judgment == .miss ? .holdMiss : .holdStart) : .note,
                          noteID: note.id, lane: lane, time: time,
                          judgment: judgment, noteTime: note.time)
        if judgment == .perfect || (judgment == .great && strength > 0.7) {
            laneFlashes.append(LaneFlash(lane: lane, time: time, intensity: judgment == .perfect ? 1 : 0.6))
        }
        // Chord haptics: the FIRST voice of a chord carries a dedicated firm
        // chord pulse; later voices within 0.1s are silent so simultaneous
        // notes never stack vibrations (one event per chord, not per voice).
        let isChordVoice = isChordVoice(index: index)
        if !isChordVoice || time - lastNoteHapticAt >= 0.1 {
            let pattern = if isChordVoice {
                HapticPatternGenerator.chordPattern(profile: hapticProfile,
                                                    enabled: settings.hapticsEnabled,
                                                    strengthScale: settings.hapticStrength,
                                                    reduced: effectiveReducedHaptics)
            } else {
                HapticPatternGenerator.pattern(for: judgment,
                                               noteStrength: strength,
                                               profile: hapticProfile,
                                               enabled: settings.hapticsEnabled,
                                               strengthScale: settings.hapticStrength,
                                               reduced: effectiveReducedHaptics)
            }
            if let pattern { haptics.play(pattern) }
            lastNoteHapticAt = time
        }
    }

    /// True when the note at `index` belongs to a chord (another note within
    /// 0.1s, any lane) — used for haptic de-duplication.
    private func isChordVoice(index: Int) -> Bool {
        guard let scheduler, scheduler.sortedNotes.indices.contains(index) else { return false }
        let note = scheduler.sortedNotes[index]
        return scheduler.sortedNotes.contains { $0.id != note.id && abs($0.time - note.time) < 0.1 }
    }

    private func finish() {
        guard !resulted else { return }
        resulted = true
        state = .finished
        #if DEBUG
        logAnchor("finish", audioTime: player.currentTime)
        #endif
        timer?.invalidate()
        timer = nil
        loopGeneration += 1
        player.pause()
        hapticScheduler?.stop()
        result = GameplayResult(
            songTitle: songTitle,
            difficulty: chart.difficulty,
            score: score.score,
            maxCombo: score.maxCombo,
            perfectCount: score.counts[.perfect] ?? 0,
            greatCount: score.counts[.great] ?? 0,
            goodCount: score.counts[.good] ?? 0,
            missCount: score.counts[.miss] ?? 0,
            accuracy: score.accuracy,
            date: Date(),
            holdsCompleted: score.holdsCompleted,
            holdsMissed: score.holdsMissed,
            playedDuration: max(0, player.currentTime)
        )
        #if DEBUG
        if isPractice {
            print(String(format: "[Practice] finish acc=%.1f%% mean|Δ|=%.1fms P%d G%d M%d (loops=%d)",
                         practiceStats.accuracy * 100, practiceStats.meanAbsDeltaMs,
                         practiceStats.perfectCount, practiceStats.greatCount, practiceStats.missCount,
                         practiceLoopCount))
        }
        #endif
    }

    /// Loop count for practice diagnostics (Debug logs).
    #if DEBUG
    private var practiceLoopCount = 0
    #endif
}