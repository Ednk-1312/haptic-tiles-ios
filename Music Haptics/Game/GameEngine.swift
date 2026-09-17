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
    /// Optional validated pre-game advice from Foundation Models. It is
    /// consumed only while constructing the deterministic profile; the model
    /// is never consulted by the real-time loop.
    private let enhancedSpeedPoints: [DynamicSpeedProfile.SpeedCurvePoint]?
    /// Prepared once before the session starts. It is the single source of
    /// truth for visual movement and spatial touch projection.
    private var speedProfile: DynamicSpeedProfile
    private var reduceMotionForSpeed = false

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

    /// Reduce Motion keeps the deterministic audio/chart timeline unchanged,
    /// but removes expressive visual speed variation before the run begins.
    func setReduceMotion(_ reduced: Bool) {
        guard reduceMotionForSpeed != reduced else { return }
        reduceMotionForSpeed = reduced
        speedProfile = DynamicSpeedProfile.make(analysis: analysis, chart: chart,
                                                 enabled: settings.dynamicSpeedEnabled,
                                                 intensity: settings.dynamicSpeedIntensity,
                                                 reduceMotion: reduced,
                                                 enhancedPoints: enhancedSpeedPoints)
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
    /// Lanes whose current physical contact has already claimed a hold. The
    /// lock lasts until touch-up even after the tail completes, so a sustained
    /// finger cannot immediately activate the next hold in the same lane.
    private var holdLaneLocks = Set<Int>()
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
    /// Rendering uses the run's stable latency sample and the monotonic render
    /// anchor. Between logic ticks this is extrapolated at the playback rate,
    /// so the same clock drives the Canvas and hold presentation without
    /// waiting for the next engine tick.
    var renderTime: Double {
        guard renderAnchorDate > 0 else {
            return player.currentTime - (renderLatencyForRun ?? max(0, player.outputLatency))
        }
        guard state == .playing else { return renderAnchorAudio }
        let elapsed = max(0, Date().timeIntervalSinceReferenceDate - renderAnchorDate)
        return renderAnchorAudio + elapsed * clockRate
    }
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
    /// A run keeps one render-latency sample. AVAudioSession can update its
    /// reported latency after playback starts (or when a route changes); using
    /// that changing value directly would re-anchor the visual clock and make
    /// every visible tile jump. The next run samples the new route instead.
    private var renderLatencyForRun: Double?
    /// Long holds must remain queryable after their heads have passed the
    /// normal render window, otherwise the body disappears before its tail.
    private let longestHoldDuration: Double
    var duration: Double { player.duration > 0 ? player.duration : chart.duration }
    /// Note travel time: the user's note-speed base, scaled by the song's BPM
    /// (faster music falls quicker) and clamped to stay readable.
    var approachTime: Double {
        NoteMovement.leadTime(bpm: analysis?.tempoBPM, base: settings.noteApproachTime)
    }

    /// Lead time at the current absolute song position. This compatibility
    /// API now samples the prepared positive speed curve; it does not rebuild
    /// or mutate movement state per frame.
    func dynamicLead(at time: Double) -> Double {
        speedProfile.leadTime(at: time, baseLead: approachTime)
    }

    /// Monotonic absolute-time projection shared by the renderer and touch
    /// matcher. 1 = spawn, 0 = hit line, negative = passed the line.
    func visualProgress(noteTime: Double, at time: Double) -> Double {
        speedProfile.progress(noteTime: noteTime, currentTime: time, baseLead: approachTime)
    }

    var visualMaximumLead: Double {
        speedProfile.maximumLeadTime(baseLead: approachTime)
    }

    var dynamicSpeedIsEnabled: Bool { settings.dynamicSpeedEnabled }
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
         enhancedSpeedPoints: [DynamicSpeedProfile.SpeedCurvePoint]? = nil,
         player: AudioPlayer? = nil) {
        self.audioURL = audioURL
        self.songTitle = songTitle
        self.chart = chart
        self.analysis = analysis
        self.settings = settings
        self.practice = practice
        self.enhancedSpeedPoints = enhancedSpeedPoints
        self.player = player ?? AudioPlayer()
        self.effectiveReducedHaptics = settings.reducedHaptics
        self.longestHoldDuration = chart.notes.filter { $0.type == .hold }.map(\.duration).max() ?? 0
        self.speedProfile = DynamicSpeedProfile.make(analysis: analysis, chart: chart,
                                                      enabled: settings.dynamicSpeedEnabled,
                                                      intensity: settings.dynamicSpeedIntensity,
                                                      enhancedPoints: enhancedSpeedPoints)
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
        displayProgress = 0
        beatPulse = 0
        beatIndex = 0
        autoplayCursor = 0   // autoplay mode survives restarts; the cursor rewinds
        renderLatencyForRun = nil
        recentTapDeltasMs.removeAll(keepingCapacity: true)
        recentTapBiasCount = 0
        holds.cancelAll()
        touchesDown = []
        holdLaneLocks = []

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
        // Establish the wall/audio anchor immediately so the first display
        // refresh cannot show a stale zero-time frame. The latency sample is
        // captured on the first logic tick, after the route has settled.
        refreshRenderAnchor(captureLatency: false, allowDiscontinuity: true)
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
        refreshRenderAnchor(allowDiscontinuity: true)
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
        refreshRenderAnchor(allowDiscontinuity: true)
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
        renderLatencyForRun = nil
        renderAnchorDate = 0
        renderAnchorAudio = 0
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
        refreshRenderAnchor(allowDiscontinuity: true)
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
        refreshRenderAnchor(allowDiscontinuity: true)
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
        refreshRenderAnchor(allowDiscontinuity: true)
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
        holdLaneLocks = []
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
        // A lane already being sustained belongs to that finger until its
        // musical tail (or release). A second touch/move in the same lane must
        // not steal the lane and judge the next hold in front of it.
        guard !holds.isActive(lane: lane) else { return }
        guard !holdLaneLocks.contains(lane) else { return }
        touchesDown.insert(lane)
        let audioTime = player.currentTime
        let hit = judgeTap(lane: lane, at: audioTime, point: point)
        #if DEBUG
        debugLastTouch = DebugTouch(lane: lane, x: point.x, y: point.y, audioTime: audioTime,
                                    noteID: hit?.note.id,
                                    judged: hit.map { scheduler?.judgment(for: $0.index) } ?? nil,
                                    deltaMs: hit.map { (audioTime - player.outputLatency + settings.calibrationOffsetMs / 1000 - $0.note.time) * 1000 })
        #endif
        if let hit { registerHoldIfNeeded(hit, at: audioTime) }
    }

    /// Tracks finger movement along its lane (raw touch layer). If the move
    /// lands spatially on the lane's unjudged candidate note's tile, that
    /// note is judged too — sliding across tiles behaves like tapping them.
    func handleLaneMove(lane: Int, point: CGPoint) {
        guard state == .playing else { return }
        // Once a finger has started a hold, movement is sustain input, not a
        // stream of additional taps. Without this guard a visible hold further
        // ahead in the same lane could be spatially judged by the same finger.
        guard !holds.isActive(lane: lane), !holdLaneLocks.contains(lane) else { return }
        let time = player.currentTime
        // Movement events are spatial-only: sliding a finger should catch a
        // visible tile, but it must not accidentally judge a note merely
        // because the note happens to be near the timing line. The shared
        // judge path still supplies latency compensation, telemetry, replay
        // recording, and the exact renderer projection.
        if let hit = judgeTap(lane: lane, at: time, point: point, spatialOnly: true) {
            registerHoldIfNeeded(hit, at: time)
        }
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
        holdLaneLocks.remove(lane)
        guard state == .playing else { return }
        let rawReleaseTime = player.currentTime
        // Hold sustain is an interval on the song clock, not a tap judgment.
        // Use output-latency projection only; applying the tap calibration
        // offset here can make a calibrated hold require extra physical time
        // after its tail (or finish early) even though the chart is unchanged.
        let releaseTime = holdTimelineTime(for: rawReleaseTime)
        guard let result = holds.release(lane: lane, at: releaseTime) else { return }
        #if DEBUG
        print(String(format: "[HoldTiming] release raw=%.3fs timeline=%.3fs tail=%.3fs delta=%+.0fms grace=%.0fms completed=%@ progress=%.0f%%",
                     rawReleaseTime, releaseTime, result.hold.endTime,
                     (releaseTime - result.hold.endTime) * 1000, 60.0,
                     result.completed ? "yes" : "no", result.progress * 100))
        #endif
        if result.completed {
            completeHold(hold: result.hold, at: releaseTime)
        } else {
            // `release` has already removed the active hold. Pass its measured
            // fraction through explicitly; querying the tracker now would
            // incorrectly report zero and make every early release look empty.
            bankPartialHold(hold: result.hold, progress: result.progress, at: releaseTime)
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
    private func judgeTap(lane: Int, at time: Double, point: CGPoint,
                          spatialOnly: Bool = false) -> (note: ChartNote, index: Int)? {
        guard let scheduler, let judge else { return nil }
        // Autoplay taps at exact chart times (latency 0, calibration must
        // not perturb validation) — keep the pure path bit-identical.
        let heardTime = isAutoplay ? time : projectionTime(for: time)
        let window = judge.config.goodWindow + InputJudge.Config.edgeGrace

        // Spatial path: a real finger position tries tile matching first.
        // Evaluate every visible candidate in this lane, not just the note
        // nearest in time. Same-lane holds can overlap on screen; choosing the
        // closest projected tile makes the finger's location authoritative and
        // gives an earlier tile a deterministic tie-break. Once a hold starts,
        // the lane guard above prevents later candidates from being activated
        // by that same sustained contact.
        let spatial = point != SpatialCatch.unspecifiedTouch
        if spatial {
            let lead = dynamicLead(at: time)
            let projectedTime = projectionTime(for: time)
            // `candidates` is chronological. The earliest tile that contains
            // the finger owns the contact; a later overlapping tile must not
            // steal a hold just because its projected center is closer.
            for candidate in scheduler.candidates(in: lane, to: time, window: max(window, lead)) {
                let headProgress = visualProgress(noteTime: candidate.note.time, at: projectedTime)
                let tailProgress = candidate.note.type == .hold
                    ? visualProgress(noteTime: candidate.note.time + candidate.note.duration, at: projectedTime)
                    : nil
                let distance = SpatialCatch.distance(headProgress: headProgress,
                                                      tailProgress: tailProgress,
                                                      touchY: Double(point.y),
                                                      hitLineY: PlayfieldGeometry.hitLineY,
                                                      topY: PlayfieldGeometry.topY,
                                                      tileHeightFraction: PlayfieldGeometry.tileHeightFraction)
                guard distance <= PlayfieldGeometry.spatialCatchDistance else { continue }

                // Judgment floor: a tap physically ON a visible tile is
                // at worst a GOOD — the player aimed correctly; only the
                // grade reflects timing. Returning immediately is important:
                // same-lane overlapping tiles remain owned by this contact's
                // first chronological candidate.
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

        if spatialOnly { return nil }

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
        // the exact head timestamp. Real touches use the same heard-time
        // coordinate as release, so partial progress is proportional.
        let rawPressTime = min(time ?? player.currentTime, endTime - 0.001)
        // Hold sustain lives on the projected song timeline. Do not apply the
        // tap calibration offset to this interval: calibration changes head
        // judgment only and must never stretch the physical hold beyond its
        // chart tail.
        let pressTime = isAutoplay
            ? rawPressTime
            : projectionTime(for: rawPressTime)
        // A spatial body catch may happen before the chart head reaches the
        // line. Keep the chart tail authoritative and begin the measured
        // sustain at the actual press for the remaining interval.
        let sustainStartTime = max(hit.note.time, pressTime)
        guard sustainStartTime < endTime else { return }
        guard holds.start(lane: hit.note.lane, index: hit.index, noteID: hit.note.id,
                          startTime: sustainStartTime, endTime: endTime,
                          pressTime: pressTime) != nil else { return }
        holdLaneLocks.insert(hit.note.lane)
        if let pattern = HapticPatternGenerator.holdStartPattern(profile: hapticProfile,
                                                                 enabled: settings.hapticsEnabled,
                                                                 strengthScale: settings.hapticStrength) {
            haptics.play(pattern)
        }
        #if DEBUG
        print(String(format: "[Hold] lane=%d press=%.3fs sustainStart=%.3fs head=%.3fs tail=%.3fs musical=%.3fs",
                     hit.note.lane, pressTime, sustainStartTime, hit.note.time,
                     endTime, hit.note.duration))
        #endif
    }

    /// Sustained to the tail: configurable bonus + strong feedback.
    private func completeHold(hold: HoldTracker.Active, at time: Double) {
        // Automatic 60 Hz completion has no touch-up event to release the
        // physical lane lock. Always release it here; a later tap on the lane
        // must be eligible even if UIKit never delivers the cancelled touch.
        holdLaneLocks.remove(hold.lane)
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
    func holdActive(id: Int) -> Bool { holds.isActive(noteID: id) }
    func holdCompleted(id: Int) -> Bool { holds.state(for: id) == .completed }
    func holdTailTime(lane: Int) -> Double? { holds.activeHold(lane: lane)?.endTime }
    func holdStartTime(lane: Int) -> Double? { holds.activeHold(lane: lane)?.startTime }
    func recordedHoldProgress(id: Int) -> Double? { holds.recordedProgress(noteID: id) }
    /// Explicit lifecycle state for a note (notStarted default).
    func holdState(for noteID: Int) -> HoldState { holds.state(for: noteID) }
    /// 0…1 sustain progress while an active hold is rendered. When `at` is
    /// supplied it is already the renderer's latency-compensated absolute
    /// song time; subtracting output latency again would make the fill lag
    /// behind the head/tail during dynamic-speed sections. The no-argument
    /// path converts the raw audio clock exactly once for non-render callers.
    func holdProgress(lane: Int, at time: Double? = nil) -> Double? {
        let sustainTime: Double
        if let time {
            // Renderer callers already provide the latency-compensated
            // absolute song time. Calibration is intentionally excluded: it is
            // a point-judgment preference, not a hold-duration adjustment.
            sustainTime = time
        } else {
            sustainTime = holdTimelineTime(for: player.currentTime)
        }
        return holds.progress(lane: lane, at: sustainTime)
    }

    /// Visual fill progress starts at the player's actual touch-down location
    /// and reaches 100% at the chart tail. This is deliberately independent of
    /// the hit-line location: a player may begin holding anywhere on the visible
    /// hold body, and the animation must respond immediately rather than waiting
    /// for the head to reach the bottom line.
    ///
    /// The prepared Dynamic Speed profile controls how that visual progress
    /// advances, while the deterministic chart timestamps still control hold
    /// scoring and completion. Dynamic Speed therefore changes presentation
    /// pacing without changing the musical end time.
    func holdVisualProgress(lane: Int, at time: Double) -> Double? {
        guard let hold = holds.activeHold(lane: lane) else { return nil }
        return speedProfile.relativeProgress(from: hold.pressTime,
                                             to: hold.endTime,
                                             at: time)
    }

    /// Spatial progress through an active hold's musical interval. This is
    /// computed from the same integrated positive speed curve as note heads
    /// and tails, so the fill boundary accelerates/decelerates with Dynamic
    /// Speed without changing the hold's start/end timestamps.
    func holdRelativeVisualProgress(startTime: Double, endTime: Double,
                                    at time: Double) -> Double {
        speedProfile.relativeProgress(from: startTime, to: endTime, at: time)
    }

    // MARK: - Rendering queries

    /// Notes currently on screen, with their judged state (for dimming). The
    /// lower bound reaches back far enough that an active hold (head already
    /// hit, tail still falling) keeps rendering until its tail passes.
    /// Notes currently on screen, with their judged state and (for judged
    /// notes) the audio-clock time of the judgment — the renderer uses it to
    /// play the brief hit effect from the exact moment it happened.
    func visibleNotes(at time: Double) -> [(note: ChartNote, judged: Judgment?, judgedAt: Double?)] {
        guard let scheduler else { return [] }
        let longestHold = longestHoldDuration + 0.3
        let range = (time - max(2.6, longestHold))...(time + visualMaximumLead + 0.4)
        return scheduler.notes(in: range).map {
            ($0.note, scheduler.judgment(for: $0.index), scheduler.judgmentTime(for: $0.index))
        }
    }

    // MARK: - Internals

    private func projectionTime(for rawTime: Double) -> Double {
        rawTime - (renderLatencyForRun ?? max(0, player.outputLatency))
    }

    private func holdTimelineTime(for rawTime: Double) -> Double {
        isAutoplay ? rawTime : projectionTime(for: rawTime)
    }

    private func judgedTime(for rawTime: Double) -> Double {
        guard !isAutoplay else { return rawTime }
        return projectionTime(for: rawTime) + settings.calibrationOffsetMs / 1000
    }

    private func refreshRenderAnchor(captureLatency: Bool = true,
                                     allowDiscontinuity: Bool = false) {
        if captureLatency, renderLatencyForRun == nil {
            let sample = player.outputLatency
            renderLatencyForRun = sample.isFinite ? min(0.5, max(0, sample)) : 0
        }
        let now = Date().timeIntervalSinceReferenceDate
        let latency = renderLatencyForRun ?? max(0, player.outputLatency)
        let sampledAudio = player.currentTime - latency

        // A display frame can be ahead of the last 60 Hz logic tick. Replacing
        // the anchor with that tick's raw sample would make the next Canvas
        // frame move backward whenever the timer fired a little late or the
        // audio clock rounded differently. During uninterrupted playback keep
        // the larger of the sampled clock and the already-projected clock;
        // this correction is monotonic and therefore cannot teleport a visible
        // tile backward. Explicit seeks, restarts, pause/resume, and rate
        // changes opt into a deliberate re-anchor below.
        if !allowDiscontinuity, renderAnchorDate > 0, state == .playing {
            let elapsed = max(0, now - renderAnchorDate)
            let projectedAudio = renderAnchorAudio + elapsed * max(0, player.rate)
            // Keep extrapolation continuous, but bound it to a small lead over
            // the authoritative sampled clock. The old unbounded max could
            // ratchet the anchor ahead forever after timer/audio jitter.
            // A bounded lead lets the sampled clock catch up without changing
            // note timestamps, scoring, or hit windows.
            let maxLead = 0.08
            renderAnchorDate = now
            // If the sampled clock has advanced beyond our initial anchor,
            // catch up immediately; otherwise a fresh run would remain near
            // zero until the extrapolated clock reached the audio sample.
            // Only the forward path is immediate. An over-ahead projection is
            // bounded, preserving continuity while the sampled clock catches
            // up naturally.
            renderAnchorAudio = sampledAudio >= projectedAudio
                ? sampledAudio
                : min(projectedAudio, sampledAudio + maxLead)
        } else {
            renderAnchorDate = now
            renderAnchorAudio = sampledAudio
        }
    }

    private func tick() {
        guard state == .playing, let scheduler, let judge else { return }
        let t = player.currentTime
        let gameplayTime = judgedTime(for: t)
        currentTime = t
        // Refresh the render anchor (wall → audio mapping for the view).
        refreshRenderAnchor()
        // Coarse HUD progress: publish only on a real move (≥0.25%).
        let total = duration
        if total > 0 {
            let progress = min(1, max(0, t / total))
            if abs(progress - displayProgress) >= 0.0025 || progress < displayProgress {
                displayProgress = progress
            }
        }
        updateBeatPulse(renderTime)
        #if DEBUG
        recordDebugTick(audioTime: t)
        #endif

        if isAutoplay {
            autoplayTick(at: t)
        }

        let holdTime = holdTimelineTime(for: t)
        if !holds.active.isEmpty {
            // An active hold represents a contact that has already been
            // accepted. Releasing before the tail is handled synchronously by
            // `handleTouchUp`; once the authoritative timeline reaches the
            // tail, completion must not depend on a later touch-up or a
            // successfully delivered UIKit touch-state callback. This removes
            // the old indefinite-active edge case without changing the tail.
            let due = holds.active.filter { holdTime >= $0.value.endTime }
            for (lane, _) in due {
                if let hold = holds.complete(lane: lane) {
                    completeHold(hold: hold, at: holdTime)
                    #if DEBUG
                    print(String(format: "[HoldTiming] automatic completion timeline=%.3fs tail=%.3fs delta=%+.0fms",
                                 holdTime, hold.endTime, (holdTime - hold.endTime) * 1000))
                    #endif
                }
            }
        }

        for index in scheduler.pendingMisses(before: gameplayTime, window: judge.config.missWindow) {
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
            apply(.miss, index: index, lane: note.lane, time: gameplayTime, strength: 0)
        }

        // Practice loop: at the section end, restart it with fully reset state.
        if isPractice, let section = practiceSection, practiceLoopEnabled,
           PracticeClock.shouldRestartLoop(contentTime: gameplayTime, sectionEnd: section.end, loop: true) {
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