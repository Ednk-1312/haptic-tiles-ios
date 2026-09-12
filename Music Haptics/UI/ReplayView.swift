import SwiftUI
import UIKit

/// Visual replay of a saved run.
///
/// Playback is driven by the SAME authoritative clock as live gameplay: the
/// audio clock (`AudioPlayer.currentTime`). Recorded events are re-injected
/// at their chart timestamps, so a replay is deterministic — the exact same
/// timeline always produces the exact same playback. If the original audio is
/// no longer reachable, a clearly-labeled fallback wall clock drives the
/// visuals instead (chart-relative timing stays identical).
@MainActor
struct ReplayView: View {
    @Environment(\.dismiss) private var dismiss
    let replay: ReplayFile

    @StateObject private var player = AudioPlayer()
    @State private var chart: Chart?
    @State private var chartLoadError = false
    @State private var audioFailed = false
    @State private var isPlaying = false
    @State private var time: Double = 0
    @State private var consumedCount = 0
    @State private var currentScore = 0
    @State private var currentCombo = 0
    @State private var popups: [ReplayPopup] = []
    @State private var showInspector = false
    @State private var showAnalytics = false
    @State private var analytics: RunAnalytics?
    @State private var fallbackAnchor: (content: Double, uptime: Double)?
    @State private var timer: Timer?
    @State private var approach = 2.0
    @State private var initialLoaded = false

    /// One transient popup re-injected from a replay event.
    private struct ReplayPopup: Identifiable {
        let id = UUID()
        let lane: Int
        let time: Double
        let text: String
        let color: Color
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.10).ignoresSafeArea()
            if chartLoadError {
                missingChartState
            } else if chart == nil {
                ProgressView("Loading replay…")
                    .foregroundStyle(.white)
            } else {
                playfield
            }
        }
        .preferredColorScheme(.dark)
        .navigationTitle("Replay — \(replay.songTitle)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "list.number")
                }
                .accessibilityLabel("Timing inspector")
            }
        }
        .sheet(isPresented: $showInspector) {
            if let chart {
                inspector(chart: chart)
            }
        }
        .sheet(isPresented: $showAnalytics) {
            if let analytics {
                NavigationStack {
                    RunAnalyticsView(analytics: analytics,
                                     title: replay.songTitle,
                                     difficulty: replay.difficulty)
                }
                .presentationDetents([.large])
            }
        }
        .task { await load() }
        .onDisappear { timer?.invalidate(); player.stop() }
    }

    // MARK: - Load

    private func load() async {
        do {
            guard let loaded = try? ChartStorage.loadChart(for: replay.songID,
                                                           difficulty: replay.difficulty),
                  ReplayBuilder.matches(replay, chart: loaded) else {
                chartLoadError = true
                return
            }
            chart = loaded
            approach = NoteMovement.leadTime(bpm: nil, base: 2.0)
            // Audio may be gone (deleted import, revoked library item): the
            // replay still plays on the fallback clock.
            if let url = replay.audioURL {
                do {
                    try player.load(url: url)
                } catch {
                    audioFailed = true
                }
            } else {
                audioFailed = true
            }
            initialLoaded = true
            startPlayback()
        }
    }

    /// Current position: the audio clock when audio is available, else a
    /// clearly-labeled fallback wall clock (chart-relative timing identical).
    private var currentTime: Double {
        if !audioFailed { return player.currentTime }
        if let anchor = fallbackAnchor {
            return anchor.content + ProcessInfo.processInfo.systemUptime - anchor.uptime
        }
        return 0
    }

    // MARK: - Controls

    private func startPlayback() {
        if audioFailed, fallbackAnchor == nil {
            fallbackAnchor = (currentTime, ProcessInfo.processInfo.systemUptime)
        }
        if !audioFailed {
            player.play(from: time)
        }
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                tick()
            }
        }
    }

    private func pausePlayback() {
        if !audioFailed { player.pause() }
        isPlaying = false
        timer?.invalidate()
    }

    private func restartPlayback() {
        pausePlayback()
        time = 0
        consumedCount = 0
        currentScore = 0
        currentCombo = 0
        popups = []
        fallbackAnchor = nil
        startPlayback()
    }

    private func seek(to target: Double) {
        let clamped = min(max(target, 0), replay.duration)
        time = clamped
        fallbackAnchor = nil
        // Re-consume from the beginning so score/combo/judgments reflect the
        // new position exactly (deterministic by construction).
        consumedCount = 0
        currentScore = 0
        currentCombo = 0
        popups = []
        if !audioFailed, isPlaying {
            player.seek(to: clamped)
        } else if !audioFailed {
            player.seek(to: clamped)
        }
        if audioFailed {
            fallbackAnchor = (clamped, ProcessInfo.processInfo.systemUptime)
        }
    }

    private func tick() {
        let t = currentTime
        guard let chart else { return }
        let end = max(replay.duration, chart.duration)
        if t >= end {
            time = end
            consumeEvents(upTo: end)
            pausePlayback()
            return
        }
        time = t
        consumeEvents(upTo: t)
        // Prune old popups.
        let cutoff = t - 0.9
        if !popups.isEmpty {
            popups.removeAll { $0.time < cutoff }
        }
    }

    private func consumeEvents(upTo t: Double) {
        let events = replay.events
        while consumedCount < events.count && events[consumedCount].time <= t {
            let event = events[consumedCount]
            consumedCount += 1
            currentScore = event.score
            currentCombo = event.combo
            popups.append(popup(for: event))
        }
    }

    private func popup(for event: ReplayEvent) -> ReplayPopup {
        switch event.kind {
        case .note, .holdStart:
            let judgment = event.judgment ?? .miss
            return ReplayPopup(lane: event.lane, time: event.time,
                               text: judgment.displayName.uppercased(),
                               color: judgmentColor(judgment))
        case .holdComplete:
            return ReplayPopup(lane: event.lane, time: event.time, text: "HOLD +", color: .mint)
        case .holdRelease:
            return ReplayPopup(lane: event.lane, time: event.time, text: "EARLY", color: .orange)
        case .holdMiss:
            return ReplayPopup(lane: event.lane, time: event.time, text: "MISS", color: .red)
        }
    }

    private func judgmentColor(_ judgment: Judgment) -> Color {
        switch judgment {
        case .perfect: return .yellow
        case .great: return .green
        case .good: return .blue
        case .miss: return .red
        }
    }

    // MARK: - Playfield

    private var playfield: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let laneWidth = width / 4
            let hitY = height - 140

            ZStack {
                // Lane columns.
                ForEach(0..<4, id: \.self) { lane in
                    let x = laneWidth * CGFloat(lane)
                    Rectangle()
                        .fill(lane % 2 == 0 ? Color.white.opacity(0.045) : Color.white.opacity(0.02))
                        .frame(width: laneWidth, height: height)
                        .position(x: x + laneWidth / 2, y: height / 2)
                    if lane < 3 {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 1, height: height)
                            .position(x: x + laneWidth, y: height / 2)
                    }
                }

                // Notes.
                if let chart {
                    ForEach(chart.notes, id: \.id) { note in
                        noteTile(note: note, laneWidth: laneWidth, hitY: hitY)
                    }
                }

                // Hit line.
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: width, height: 2)
                    .position(x: width / 2, y: hitY)

                // Judgment popups.
                ForEach(popups) { popup in
                    Text(popup.text)
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(popup.color)
                        .shadow(color: .black.opacity(0.8), radius: 4)
                        .position(x: laneWidth * CGFloat(popup.lane) + laneWidth / 2,
                                  y: hitY - 26)
                }

                // HUD.
                VStack {
                    HStack {
                        Text(Format.compact(currentScore))
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Spacer()
                        if currentCombo >= 2 {
                            Text("\(currentCombo)×")
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    Spacer()
                    controls(hitY: hitY)
                }
                .frame(width: width, height: height)

                // Progress bar.
                VStack {
                    Spacer()
                    ProgressView(value: min(max(time / max(replay.duration, 0.001), 0), 1))
                        .tint(.white.opacity(0.8))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 74)
                }
                .frame(width: width, height: height)

                if audioFailed {
                    VStack {
                        Text("Audio unavailable — fallback clock")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                        Spacer()
                    }
                    .padding(.top, 54)
                }
            }
        }
    }

    private func noteTile(note: ChartNote, laneWidth: CGFloat, hitY: CGFloat) -> some View {
        let progress = InputGeometry.progress(noteTime: note.time,
                                              currentAudioTime: time,
                                              leadTime: approach)
        guard progress > 0, progress < 1.25 else { return AnyView(EmptyView()) }
        let y = hitY - CGFloat(progress * 60)
        let tileWidth = laneWidth * 0.92
        let baseHeight: CGFloat = note.type == .hold ? 26 : 22
        var height = baseHeight
        var opacity = 1.0
        if note.type == .hold {
            let tailProgress = InputGeometry.progress(noteTime: note.time + note.duration,
                                                      currentAudioTime: time,
                                                      leadTime: approach)
            if tailProgress > 0 {
                height += CGFloat((progress - tailProgress) * 60)
            }
        }
        // Judged notes fade once their moment passed.
        if progress < 0.02 {
            opacity = 0.25
        }
        return AnyView(
            RoundedRectangle(cornerRadius: 8)
                .fill(noteColor(note))
                .opacity(opacity)
                .frame(width: tileWidth, height: max(height, 8))
                .position(x: laneWidth * CGFloat(note.lane) + laneWidth / 2, y: y)
        )
    }

    private func noteColor(_ note: ChartNote) -> Color {
        let palette: [Color] = [.pink, .cyan, .purple, .mint]
        let base = palette[note.lane % 4]
        return note.type == .hold ? base.opacity(0.85) : base
    }

    private func controls(hitY: CGFloat) -> some View {
        HStack(spacing: 16) {
            Button {
                restartPlayback()
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Restart replay")

            Button {
                isPlaying ? pausePlayback() : startPlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            // Scrub slider.
            Slider(value: Binding(get: { time },
                                  set: { seek(to: $0) }),
                   in: 0...max(replay.duration, 1))
                .tint(.white)
                .accessibilityLabel("Scrub")

            Text(String(format: "%.1f / %.1fs", time, replay.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 30)
    }

    // MARK: - Inspector

    private func inspector(chart: Chart) -> some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Song", value: replay.songTitle)
                    LabeledContent("Difficulty", value: replay.difficulty.displayName)
                    LabeledContent("Chart version", value: "\(replay.chartVersion)")
                    LabeledContent("Notes in chart", value: "\(chart.notes.count)")
                    LabeledContent("Events recorded", value: "\(replay.events.count)")
                    LabeledContent("Duration", value: String(format: "%.1f s", replay.duration))
                    LabeledContent("Saved", value: replay.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if audioFailed {
                        Label("Audio unavailable — replay uses the fallback clock",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Run")
                }

                Section {
                    ForEach(Array(replay.events.enumerated()), id: \.offset) { index, event in
                        eventRow(event: event, index: index)
                    }
                } header: {
                    Text("Timing — \(replay.events.count) events")
                } footer: {
                    Text("Each event replays at its chart time on the audio clock. Timing error is tap + calibration − note time; negative = early.")
                }
            }
            .navigationTitle("Timing Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showInspector = false }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        let sections = (try? ChartStorage.loadAnalysis(for: replay.songID))?.sections ?? []
                        analytics = RunAnalyticsCalculator.compute(events: replay.events,
                                                                  sections: sections,
                                                                  duration: replay.duration)
                        showAnalytics = true
                    } label: {
                        Label("Analytics", systemImage: "chart.bar.xaxis")
                    }
                }
            }
        }
    }

    private func eventRow(event: ReplayEvent, index: Int) -> some View {
        Button {
            showInspector = false
            seek(to: event.time)
            startPlayback()
        } label: {
            HStack(spacing: 10) {
                Text(String(format: "%5.3f", event.time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                Text(kindLabel(event.kind))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(kindColor(event.kind))
                    .frame(width: 86, alignment: .leading)
                if let judgment = event.judgment {
                    Text(judgment.displayName.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(judgmentColor(judgment))
                        .frame(width: 64, alignment: .leading)
                } else {
                    Text("—")
                        .font(.caption)
                        .frame(width: 64, alignment: .leading)
                }
                Text(String(format: "%@%.0f ms", event.timingErrorMs < 0 ? "" : "+", event.timingErrorMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(timingColor(event))
                    .frame(width: 70, alignment: .trailing)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(event.score)")
                        .font(.caption2.monospacedDigit())
                    Text("\(event.combo)×")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(event.combo >= 2 ? .orange : .secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func kindLabel(_ kind: ReplayEventKind) -> String {
        switch kind {
        case .note: return "Note"
        case .holdStart: return "Hold start"
        case .holdComplete: return "Hold +"
        case .holdRelease: return "Early release"
        case .holdMiss: return "Hold miss"
        }
    }

    private func kindColor(_ kind: ReplayEventKind) -> Color {
        switch kind {
        case .note, .holdStart: return .primary
        case .holdComplete: return .mint
        case .holdRelease, .holdMiss: return .red
        }
    }

    private func timingColor(_ event: ReplayEvent) -> Color {
        guard let judgment = event.judgment else { return .secondary }
        switch judgment {
        case .perfect: return .yellow
        case .great: return .green
        case .good: return .blue
        case .miss: return .red
        }
    }

    // MARK: - Missing chart

    private var missingChartState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Chart unavailable")
                .font(.title2.weight(.bold))
            Text("The chart this replay was recorded against (v\(replay.chartVersion), \(replay.difficulty.displayName)) is no longer in the library. Regenerate the chart to view this replay.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
    }
}