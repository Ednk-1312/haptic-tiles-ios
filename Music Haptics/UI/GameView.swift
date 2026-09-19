import SwiftUI

/// One playthrough host: owns the engine for a single GameSession and renders
/// the full gameplay UI. The queue-aware `GameView` wrapper swaps sessions
/// (auto-transition) by changing `session` — each new session id builds a
/// fresh engine, so no state survives between songs.
struct GameSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var engine: GameEngine
    @State private var theme: SongBackgroundTheme
    @State private var comboPop = false
    @State private var resultsDismissed = false
    /// Throttle box for VoiceOver announcements (misses, holds, milestones).
    /// A small class so the engine's closure captures a stable reference,
    /// never the view itself.
    private let announcementThrottle = VoiceOverThrottle()

    /// Replay recording of this run. nil for practice and developer-autoplay
    /// runs (never presented as official replays).
    private var replayContext: ReplayContext? {
        guard !engine.isPractice, !engine.isAutoplay, !engine.replayEvents.isEmpty else {
            return nil
        }
        return ReplayContext(songID: session.chart.songID,
                             songTitle: session.title,
                             difficulty: session.chart.difficulty,
                             chartVersion: session.chart.chartVersion,
                             audioURL: session.audioURL,
                             duration: engine.duration,
                             noteCount: session.chart.notes.count,
                             events: engine.replayEvents)
    }
    @State private var milestones: [StatMilestone] = []

    private let session: GameSession
    private let song: SongRecord
    private let autoplayOnLaunch: Bool

    /// Combo pop animation (or a static highlight under Reduce Motion).
    private func flashComboPopupIfNeeded() {
        guard engine.comboCount >= 2 else { return }
        if reduceMotion {
            comboPop = true
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                comboPop = false
            }
        } else {
            withAnimation(.easeOut(duration: 0.18)) { comboPop = true }
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.easeIn(duration: 0.12)) { comboPop = false }
            }
        }
    }


    /// Invisible but real (2×2 pt) accessibility element that reports the
    /// current score and combo as its value. `.updatesFrequently` lets
    /// VoiceOver re-read it as the run progresses.
    private var voiceOverStatus: some View {
        Text(voiceOverStatusText)
            .font(.caption2)
            .frame(width: 2, height: 2)
            .foregroundStyle(.clear)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Game status")
            .accessibilityValue(voiceOverStatusText)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var voiceOverStatusText: String {
        let score = Format.compact(engine.scoreValue)
        if engine.comboCount >= 2 {
            return "Score \(score), combo \(engine.comboCount)"
        }
        return "Score \(score)"
    }

    /// The background theme is fully prepared before the session is presented.
    /// In particular, no genre lookup or artwork task is allowed to begin after
    /// the audio clock starts.

    private static func stableSeed(_ id: UUID) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01B3
            }
        }
        return hash
    }
    /// Queue decision hook: called when this session finishes naturally.
    /// `.replayCurrent` restarts in place; `.next` reports via `onAdvance`;
    /// `.none` (or nil) shows the results screen.
    var onFinishDecision: ((GameplayResult) -> QueueAdvanceDecision)? = nil
    /// Called when the session must hand over to another song (auto skip /
    /// advance). The wrapper swaps `session`; this view then disappears and
    /// its engine fully cleans up (audio, haptics, touches, holds).
    var onAdvance: ((QueueEntry) -> Void)? = nil
    /// Autoplay continuity across transitions (simulator demo).
    var onAutoplayChange: ((Bool) -> Void)? = nil
    /// Records a finished run (statistics + result persistence). Returns the
    /// personal records broken, shown on the results screen. nil = practice
    /// or autoplay (never recorded as official results).
    var onFinished: ((GameplayResult) -> [StatMilestone])? = nil

    init(session: GameSession, song: SongRecord, settings: SettingsStore,
         autoplay: Bool = false,
         onFinishDecision: ((GameplayResult) -> QueueAdvanceDecision)? = nil,
         onAdvance: ((QueueEntry) -> Void)? = nil,
         onAutoplayChange: ((Bool) -> Void)? = nil,
         onFinished: ((GameplayResult) -> [StatMilestone])? = nil) {
        self.session = session
        self.song = song
        self.autoplayOnLaunch = autoplay
        _theme = State(initialValue: SongBackgroundThemeFactory.make(
            artworkData: song.artworkData,
            seed: Self.stableSeed(song.id),
            mood: session.backgroundMood))
        self.onFinishDecision = onFinishDecision
        self.onAdvance = onAdvance
        self.onAutoplayChange = onAutoplayChange
        self.onFinished = onFinished
        _engine = StateObject(wrappedValue: GameEngine(audioURL: session.audioURL,
                                                       songTitle: session.title,
                                                       chart: session.chart,
                                                       analysis: session.analysis,
                                                       settings: settings,
                                                       practice: session.practice,
                                                       enhancedSpeedPoints: session.enhancedSpeedPoints))
    }

    var body: some View {
        // One root geometry contract owns the complete physical display. The
        // old arrangement measured a nested GeometryReader before the
        // full-screen expansion, which could hand the Canvas a half-width
        // proposal on notched devices. The renderer and UIKit touch surface
        // now receive this exact same, already-expanded size.
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Quantized decorative inputs: the background only re-diffs
                // when its values actually change, not on every 60 Hz clock
                // publish. Without this the artwork layers churn every frame
                // and the whole screen stutters under the diff load.
                GameBackgroundView(theme: theme,
                                   pulse: (engine.beatPulse * 8).rounded() / 8,
                                   energy: (engine.currentSectionEnergy * 8).rounded() / 8,
                                   sectionIndex: engine.currentSectionIndex,
                                   effects: settings.visualEffects)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                playfieldLayer(in: proxy.size)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                // The score block owns its own contrast. Keeping the gameplay
                // field free of a separate top gradient avoids a rectangular
                // gray veil under the Dynamic Island and eliminates one full-
                // screen compositing layer from every frame.
                VStack(spacing: 0) {
                    hud
                    Spacer()
                    if engine.isPractice {
                        practiceBar
                    }
                }
                // Keep the gameplay field edge-to-edge, but always place the
                // interactive HUD inside the system safe area. This prevents
                // the Dynamic Island from covering Pause, score, or progress
                // controls on physical iPhones while preserving all four full-
                // width lanes underneath.
                // This stack is intentionally safe-area aware even though the
                // playfield behind it is edge-to-edge. Reading insets from the
                // outer GeometryReader after `.ignoresSafeArea` can yield zero
                // on Dynamic-Island devices, placing Pause and score under the
                // island. Let SwiftUI apply the actual container insets.
                .safeAreaPadding(.top)
                .safeAreaPadding(.bottom)
                .frame(width: proxy.size.width, height: proxy.size.height,
                       alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea(.container)
            // Full-screen overlays live above the measured playfield layers.
            // Keeping them in one overlay builder preserves the exact full-
            // screen bounds the game measured above.
            .overlay(alignment: .topLeading) {
                if engine.state == .paused {
                    PauseOverlay(engine: engine) { dismiss() }
                }

            if engine.state == .finished, let result = engine.result, !resultsDismissed {
                ResultsView(result: result,
                            milestones: milestones,
                            replayContext: replayContext,
                            analyticsInput: RunAnalyticsInput(events: engine.replayEvents,
                                                              sections: session.analysis?.sections ?? [],
                                                              title: session.title,
                                                              difficulty: session.chart.difficulty,
                                                              duration: engine.duration),
                            onRetry: { resultsDismissed = false; engine.restart() },
                            onDone: { dismiss() })
            }

            #if DEBUG
            if engine.debugOverlayVisible {
                GeometryReader { geo in
                    GameTimingOverlay(engine: engine,
                                      playfieldWidth: geo.size.width,
                                      laneWidth: geo.size.width / 4)
                }
            }
            if engine.debugChartMode {
                // A small legend so the chart-structure overlay is readable.
                VStack(alignment: .leading, spacing: 2) {
                    legendRow(mark: "━ ━", color: .white.opacity(0.8), text: "section boundary")
                    legendRow(mark: "──", color: .white.opacity(0.9), text: "beats (thick = strong)")
                    legendRow(mark: "●", color: .cyan, text: "detected events/onsets")
                    legendRow(mark: "▔", color: .yellow, text: "chart notes / holds")
                }
                .font(.system(size: 9, weight: .medium).monospaced())
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 30)
                .padding(.top, 60)
                .allowsHitTesting(false)
            }
            #endif

            // Invisible live status for VoiceOver: score/combo are re-read
            // whenever they change (updatesFrequently), so a screen-reader
            // user can check where the run stands at any moment.
            voiceOverStatus
            }   // end .overlay content
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        // Gameplay is fixed-layout by design (four full-width lanes); bound
        // Dynamic Type so accessibility text sizes can't break the playfield.
        .dynamicTypeSize(.xSmall...(.accessibility2))
        .onAppear {
            // Apply accessibility presentation choices before the audio clock
            // starts. Rebuilding the visual profile after playback begins could
            // move visible tiles when the environment changes; the chart and
            // scoring timeline remain untouched.
            engine.setReducedHaptics(settings.reducedHaptics || reduceMotion)
            engine.setReduceMotion(reduceMotion)
            engine.start()
            #if DEBUG
            // Launch-arg automation: `-debugOverlay` shows the lane-geometry
            // overlay immediately (used by the simulator verification flow).
            if CommandLine.arguments.contains("-debugOverlay") {
                engine.toggleDebugOverlay()
            }
            #endif
            // System accessibility preferences: Reduce Motion also softens
            // haptics (softer hits, no miss feedback) unless the user has an
            // explicit preference in Settings.
            engine.announcementHandler = { [throttle = announcementThrottle] message in
                throttle.post(message)
            }
            if autoplayOnLaunch {
                engine.setAutoplay(true)
                onAutoplayChange?(true)
            }
        }
        .onDisappear { engine.cleanup() }
        .onChange(of: engine.comboCount) { _, _ in
            flashComboPopupIfNeeded()
        }

        .alert("Playback Error", isPresented: Binding(get: { engine.lastError != nil },
                                                      set: { if !$0 { engine.lastError = nil } })) {
            Button("OK") { dismiss() }
        } message: {
            Text(engine.lastError ?? "")
        }
        .onChange(of: engine.state) { _, newState in
            if newState != .finished {
                milestones = []   // fresh run (restart / replay / advance)
                return
            }
            guard let result = engine.result else { return }
            // Record the run once: practice and autoplay runs are never
            // official records; everything else (queue AND standalone play)
            // feeds results persistence + statistics.
            if !engine.isPractice, !engine.isAutoplay, milestones.isEmpty {
                milestones = onFinished?(result) ?? []
            }
            guard let decision = onFinishDecision else { return }
            switch decision(result) {
            case .replayCurrent:
                // Repeat One: restart in place — results are suppressed.
                resultsDismissed = true
                engine.restart()
            case .next(let entry):
                resultsDismissed = true
                onAdvance?(entry)
            case .none:
                break   // show results
            }
        }
    }

    // MARK: - Playfield (rendering + input share the full container)

    /// A single measured container owns BOTH the renderer and the four input
    /// regions. The explicit frames are important: an HStack of bare
    /// GeometryReaders has only its 10-point ideal height/width on a real
    /// device, which leaves touch working only in a thin strip and can cause
    /// the canvas to be laid out from an incorrect proposal. Every lane is
    /// therefore given exactly one quarter of this container, and the Canvas
    /// receives the identical width and height.
    private func playfieldLayer(in size: CGSize) -> some View {
        let width = size.width
        let height = size.height
        let laneWidth = width / 4

        return ZStack {
            GamePlayfieldView(engine: engine, expandToSafeArea: false)
                .frame(width: width, height: height)                // One raw multi-touch layer owns all four lanes: every finger is
                // tracked by identity (chords + hold + tap simultaneously),
                // touches-Moved keeps holds sustained, and cancel is delivered.
                LaneTouchLayerView(
                    onLaneDown: { lane, point in
                        engine.handleTap(lane: lane, point: point)
                    },
                    onLaneMove: { lane, point in
                        engine.handleLaneMove(lane: lane, point: point)
                    },
                    onLaneUp: {
                        engine.handleTouchUp(lane: $0)
                    })
                .frame(width: width, height: height)
                .accessibilityHidden(true)

            // VoiceOver path: four explicit lane buttons mirroring the raw
            // touch layer (which is hidden from accessibility). activates on
            // accessibility activation without stealing physical touches.
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { lane in
                    LaneAccessibilityButton(lane: lane,
                                            onTouchDown: { engine.handleTap(lane: lane) },
                                            onTouchUp: { engine.handleTouchUp(lane: lane) })
                        .frame(width: laneWidth, height: height)
                }
            }
            .frame(width: width, height: height)
            .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        #if DEBUG
        .onAppear {
            print(String(format: "[Playfield] measured %.1f × %.1fpt → 4 lanes × %.1fpt",
                         width, height, laneWidth))
        }
        #endif
    }

    // MARK: - HUD (big score/combo, never covers the note stream core)

    private var hud: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    engine.pause()
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.title3.weight(.semibold))
                        .frame(width: 46, height: 46)
                        .background(Color.black.opacity(0.6), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                }
                .accessibilityLabel("Pause")

                // Exit is available during active play as well as from the
                // pause sheet. Cleaning the engine before dismissal prevents
                // audio, haptics, timers, and held-lane state from surviving
                // when the view is removed.
                Button {
                    engine.cleanup()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.bold))
                        .frame(width: 46, height: 46)
                        .background(Color.black.opacity(0.6), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                }
                .accessibilityLabel("Exit game")
                .accessibilityHint("Stops gameplay and returns to the library")

                if engine.isPractice {
                    Text("PRACTICE")
                        .font(.system(size: 9, weight: .heavy).monospaced())
                        .foregroundStyle(.mint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.mint.opacity(0.16), in: Capsule())
                        .accessibilityLabel("Practice mode")
                }
            }

            // Developer controls stay available through launch arguments and
            // diagnostics APIs, but never occupy the production gameplay HUD.
            // The old autoplay/scope cluster was the second button seen beside
            // Pause on Debug installs and could be mistaken for a Dynamic Island
            // control.
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .foregroundStyle(.white)
        .overlay(alignment: .top) {
            centerScoreBlock
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
    }

    #if DEBUG
    /// Small legend row for the chart-structure debug overlay.
    private func legendRow(mark: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Text(mark).foregroundStyle(color)
            Text(text).foregroundStyle(.white.opacity(0.9))
        }
    }
    #endif

    /// Centered score + combo (reference-style HUD): a dark translucent box
    /// with sharp corners holding the big white score, combo beneath it.
    /// Non-interactive so it never steals lane touches.
    private var centerScoreBlock: some View {
        Group {
            if engine.practiceShowScore {
                VStack(spacing: 4) {
                    Text(Format.compact(engine.scoreValue))
                        .font(.system(size: 48, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                        .frame(minWidth: 112)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    comboLine
                    timingBiasLine
                }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.18), lineWidth: 1))
            } else {
                comboLine   // score hidden: combo floats alone
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// Live timing bias under the score: rolling signed mean of recent tap
    /// deltas, quantized to 5 ms so the label doesn't flicker per tap, and
    /// published only when the QUANTIZED value changes (an every-tick text
    /// update would re-diff the HUD each frame). Shows nothing until there
    /// are ≥4 measured taps. Real feedback — the honest answer to "why is my
    /// accuracy low?": a persistent +45 ms tells the player they (or their
    /// route's latency) genuinely run late, and calibration fixes it.
    private var timingBiasLine: some View {
        Group {
            if !engine.isPractice, engine.recentTapBiasCount >= 4 {
                let quantized = (engine.recentTapBiasMs / 5).rounded() * 5
                if abs(quantized) >= 10 {
                    let late = quantized > 0
                    Text("\(late ? "LATE" : "EARLY") \(Int(abs(quantized)))ms")
                        .font(.system(size: 9, weight: .heavy).monospaced())
                        .foregroundStyle(late ? Color(red: 1.0, green: 0.62, blue: 0.30) : Color(red: 0.45, green: 0.85, blue: 1.0))
                        .accessibilityLabel("Timing bias: \(late ? "late" : "early") by \(Int(abs(quantized))) milliseconds")
                }
            }
        }
    }

    /// Combo line under the score (yellow/orange gradient, pops on change).
    private var comboLine: some View {
        Group {
            if engine.practiceShowCombo, engine.comboCount >= 2 {
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("\(engine.comboCount)")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .monospacedDigit()
                    Text("COMBO")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                    if engine.multiplier > 1 {
                        Text("×\(engine.multiplier)")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundStyle(.yellow)
                    }
                }
                .foregroundStyle(LinearGradient(colors: [.yellow, .orange],
                                                startPoint: .leading, endPoint: .trailing))
                .scaleEffect(comboPop ? 1.14 : 1)
            }
        }
    }

    /// The score card is the only HUD scrim. There used to be a separate
    /// 160-point full-width gradient here; on a notched iPhone it read as a
    /// gray rectangle/image at the top of gameplay and added an unnecessary
    /// compositing layer. Contrast now comes from `centerScoreBlock` itself.
    private var hudScrim: some View {
        EmptyView()
    }

    // MARK: - Practice bar

    /// Compact practice controls (speed / section / loop / restart / timing).
    /// Sits above the progress bar so it never covers the note stream.
    private var practiceBar: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                speedMenu
                sectionMenu
                loopButton
                restartSectionButton
                timingButton
            }
            if engine.practiceShowTiming {
                timingLine
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(PracticeConfig.supportedSpeeds, id: \.self) { speed in
                Button(String(format: "%.2f×", speed)) {
                    engine.setPracticeSpeed(speed)
                }
            }
        } label: {
            Label(String(format: "%.2f×", engine.practiceSpeed), systemImage: "speedometer")
        }
        .accessibilityLabel("Practice speed")
    }

    private var sectionMenu: some View {
        Menu {
            Button("Whole Song") { engine.practiceSelectWholeSong() }
            ForEach(engine.practiceSections) { section in
                Button(section.label) { engine.practiceJump(to: section) }
            }
        } label: {
            Label(engine.practiceSection?.label ?? "Whole Song", systemImage: "music.note.list")
        }
        .accessibilityLabel("Practice section")
    }

    private var loopButton: some View {
        Button {
            engine.setPracticeLoop(!engine.practiceLoopEnabled)
        } label: {
            Image(systemName: engine.practiceLoopEnabled ? "repeat.circle.fill" : "repeat.circle")
                .foregroundStyle(engine.practiceLoopEnabled ? .mint : .white)
        }
        .accessibilityLabel(engine.practiceLoopEnabled ? "Loop section on" : "Loop section off")
    }

    private var restartSectionButton: some View {
        Button {
            engine.practiceRestartSection()
        } label: {
            Image(systemName: "arrow.counterclockwise.circle")
        }
        .accessibilityLabel("Restart section")
    }

    private var timingButton: some View {
        Button {
            engine.togglePracticeTiming()
        } label: {
            Image(systemName: engine.practiceShowTiming ? "chart.bar.fill" : "chart.bar")
                .foregroundStyle(engine.practiceShowTiming ? .mint : .white)
        }
        .accessibilityLabel("Toggle timing info")
    }

    private var timingLine: some View {
        let stats = engine.practiceStats
        return Text(String(format: "ACC %.0f%% · AVG Δ %.1f ms · P %d · G %d · M %d",
                           stats.accuracy * 100, stats.meanAbsDeltaMs,
                           stats.perfectCount, stats.greatCount, stats.missCount))
            .font(.system(size: 10, weight: .medium).monospaced())
            .foregroundStyle(.mint.opacity(0.95))
    }
}

/// Accessible lane control for VoiceOver users: mirrors the raw touch layer,
/// which is hidden from accessibility. Activating it taps the lane; double-
/// tap-and-hold (accessibility activate semantics map to a press/hold here)
/// sustains until the next activation. Physical touches never reach this
/// (allowsHitTesting(false) upstream) — it exists only for assistive tech.
private struct LaneAccessibilityButton: View {
    let lane: Int
    let onTouchDown: () -> Void
    let onTouchUp: () -> Void
    @State private var pressed = false

    var body: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel(laneLabel)
            .accessibilityHint("Double-tap to hit; double-tap and hold to sustain hold tiles.")
            .accessibilityAddTraits(pressed ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default) {
                if pressed {
                    pressed = false
                    onTouchUp()
                } else {
                    pressed = true
                    onTouchDown()
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        if pressed {
                            pressed = false
                            onTouchUp()
                        }
                    }
                }
            }
    }

    private var laneLabel: String {
        switch lane {
        case 0: return "Lane 1, leftmost column"
        case 1: return "Lane 2, second column from the left"
        case 2: return "Lane 3, second column from the right"
        default: return "Lane 4, rightmost column"
        }
    }
}

/// Pause menu overlay.
private struct PauseOverlay: View {
    let engine: GameEngine
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Paused")
                    .font(.title.bold())
                Button("Resume") { engine.resume() }
                    .buttonStyle(.borderedProminent)
                    .font(.headline)
                Button("Restart") { engine.restart() }
                    .buttonStyle(.bordered)
                    .font(.headline)
                if engine.isPractice {
                    Button("Restart Section") { engine.practiceRestartSection() }
                        .buttonStyle(.bordered)
                        .font(.headline)
                }
                Button("Exit to Library", role: .destructive) { onExit() }
                    .buttonStyle(.bordered)
                    .font(.headline)
            }
            .padding(30)
            .background(Color(red: 0.09, green: 0.09, blue: 0.14).opacity(0.97),
                        in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
        }
        .foregroundStyle(.white)
    }
}

#if DEBUG
/// Live timing overlay (Debug builds): audio-clock position, render frame
/// cadence, next-note countdown, calibration, and measured per-hit timing
/// errors — everything on-device sync validation needs at a glance.
private struct GameTimingOverlay: View {
    @ObservedObject var engine: GameEngine
    let playfieldWidth: CGFloat
    let laneWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row("state", "\(engine.state.rawValue) · session \(engine.sessionID.uuidString.prefix(8))")
            if let tick = engine.debugTick {
                row("audio", String(format: "%.3fs / %.1fs", tick.audioTime, tick.chartDuration))
                row("render", String(format: "frame %.1fms · avg %.1f · max %.1f",
                                     tick.frameIntervalMs, tick.avgFrameMs, tick.maxFrameMs))
                row("next note", tick.nextNoteInMs.map { String(format: "+%.1fms", $0) } ?? "—")
            } else {
                row("audio", "—")
            }
            row("playfield", String(format: "W %.0f · lane %.0f · active %d · tier %d",
                                    playfieldWidth, laneWidth, engine.activeNoteCount,
                                    engine.chartFallbackTier ?? 1))
            if let touch = engine.debugLastTouch {
                row("last touch", String(format: "lane %d · x %.2f y %.2f · audio %.3fs · note %@ · %@",
                                         touch.lane, touch.x, touch.y, touch.audioTime,
                                         touch.noteID.map(String.init) ?? "none",
                                         touch.judged?.displayName ?? "—"))
            }
            row("calibration", String(format: "%+.1fms", engine.debugCalibrationOffsetMs))
            row("measured", String(format: "mean |Δ| %.1fms · %d hits",
                                   engine.debugMeanAbsDeltaMs, engine.debugHitCount))
            if let last = engine.debugAnchorLog.last {
                row("anchor", last)
            }
            ForEach(engine.debugHits.suffix(5)) { hit in
                row(hit.judgment.displayName,
                    String(format: "note %.3fs · Δ%+.1fms", hit.noteTime, hit.deltaMs))
            }
        }
        .font(.system(size: 9, weight: .medium).monospaced())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 8)
        .padding(.bottom, 22)
        .allowsHitTesting(false)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.white.opacity(0.65))
            Text(value).foregroundStyle(.white.opacity(0.95))
        }
    }
}
#endif

// MARK: - Queue-aware wrapper

/// Full-screen gameplay entry point. Renders one `GameSessionView` per
/// session and drives the in-app queue: when a song ends (or the player
/// skips) it saves the result, swaps to the next session — a fresh engine, so
/// no score/combo/touches/haptics can leak between songs — and pre-generates
/// the following entry in the background.
struct GameView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    private let song: SongRecord
    private let settings: SettingsStore
    private let autoplayOnLaunch: Bool
    @State private var session: GameSession
    @State private var autoplayChain = false
    @State private var isTransitioning = false
    @State private var nextLabel: String?
    @State private var queueError: String?
    /// Monotonic song-transition identity. Each `advance(to:)` bumps it; an
    /// in-flight session-build Task only applies when it is still the LATEST
    /// transition — rapid Skip/Skip can never apply out of order (a stale
    /// build must not clobber the newer session).
    @State private var transitionGeneration = 0

    init(session: GameSession, song: SongRecord, settings: SettingsStore,
         autoplay: Bool = false) {
        self.song = song
        self.settings = settings
        self.autoplayOnLaunch = autoplay
        _session = State(initialValue: session)
    }

    var body: some View {
        ZStack {
            GameSessionView(session: session, song: song, settings: settings,
                            autoplay: autoplayOnLaunch || autoplayChain,
                            onFinishDecision: queueDecisionForFinish,
                            onAdvance: { advance(to: $0) },
                            onAutoplayChange: { autoplayChain = $0 },
                            onFinished: { result in
                                let milestones = appState.recordResult(result, for: song.id)
                                appState.schedulePlayerAnalysis(after: result)
                                return milestones
                            })
                .id(session.id)

            if session.practice == nil {
                upNextChip
            }

            if isTransitioning, let nextLabel {
                transitionOverlay(nextLabel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container)
        .alert("Queue", isPresented: Binding(get: { queueError != nil },
                                             set: { if !$0 { queueError = nil } })) {
            Button("OK") {}
        } message: {
            Text(queueError ?? "")
        }
    }

    /// Queue decision when the current session finishes (Repeat One honored).
    /// Result persistence + statistics already happened via `onFinished`.
    private func queueDecisionForFinish(_ result: GameplayResult) -> QueueAdvanceDecision {
        let queue = appState.queue
        guard session.practice == nil, !queue.entries.isEmpty else { return .none }
        return queue.decisionAfterFinish()
    }

    /// Hand-over to another song: build its session, swap, and pre-generate
    /// the song after it. If the session can't be built (song vanished or its
    /// audio is unavailable) the entry is dropped and the queue falls back to
    /// the next decision — the player is never stranded on a dead end.
    /// Token-gated: only the LATEST transition may apply, so two rapid
    /// skips can never complete out of order.
    private func advance(to entry: QueueEntry) {
        guard session.practice == nil else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        nextLabel = entry.title
        isTransitioning = true
        #if DEBUG
        print("[Queue] advance → \(entry.displayName) (song \(entry.songID.uuidString.prefix(8)))")
        #endif
        Task {
            let nextSession: GameSession?
            do {
                nextSession = try await appState.session(for: entry)
            } catch is CancellationError {
                // The chart build was superseded by a newer pipeline for the
                // same song — benign; keep the entry queued and let the user
                // skip again rather than dropping the song.
                #if DEBUG
                print("[Queue] advance superseded for \(entry.title); entry kept")
                #endif
                isTransitioning = false
                return
            } catch {
                nextSession = nil
            }
            // A newer transition superseded this one: never apply a stale
            // session (out-of-order completion protection).
            guard generation == transitionGeneration else { return }
            #if DEBUG
            print("[Queue] session built: \(nextSession != nil ? "yes" : "NO")")
            #endif
            if nextSession == nil {
                appState.queue.remove(entryID: entry.id)
            }
            isTransitioning = false
            guard let nextSession else {
                queueError = "Couldn't load \"\(entry.title)\" — it was skipped."
                return
            }
            appState.queue.setCurrent(entryID: entry.id)
            appState.prepareNextAfter(entry)
            session = nextSession
        }
    }

    /// Manual skip: advances without honoring Repeat One.
    private func skipToNext() {
        guard session.practice == nil else { return }
        switch appState.queue.decisionAfterSkip() {
        case .none:
            break
        case .replayCurrent:
            break   // skip never returns replayCurrent; ignore defensively
        case .next(let entry):
            advance(to: entry)
        }
    }

    // MARK: - Queue chrome

    private var upNextChip: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                if let next = appState.queue.upNext {
                    HStack(spacing: 8) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.caption)
                        Text("UP NEXT · \(next.title)")
                            .font(.system(size: 10, weight: .bold).monospaced())
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
                    Button {
                        skipToNext()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.caption)
                            .frame(width: 28, height: 28)
                            .background(Color.black.opacity(0.6), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
                    }
                    .accessibilityLabel("Skip to next song")
                }
            }
            .padding(.bottom, 14)
        }
    }

    private func transitionOverlay(_ label: String) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Loading \(label)…")
                    .font(.headline)
            }
            .padding(24)
            .background(Color(red: 0.09, green: 0.09, blue: 0.14).opacity(0.95),
                        in: RoundedRectangle(cornerRadius: 16))
        }
        .foregroundStyle(.white)
    }
}
/// Throttles UIAccessibility announcements: at most one every 0.6 s, and only
/// while VoiceOver is actually running. Owned by the game view; the engine's
/// announcement closure captures ONLY this box, never the view, so there is
/// no retain cycle across sessions.
@MainActor
private final class VoiceOverThrottle {
    private var lastAnnouncementAt: CFAbsoluteTime = 0

    func post(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAnnouncementAt > 0.6 else { return }
        lastAnnouncementAt = now
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
