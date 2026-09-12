import SwiftUI
import UIKit

/// Chart Preview — inspect a generated chart before playing it.
///
/// Header (artwork, title, artist, BPM, difficulty, note count, NPS,
/// duration), a difficulty switcher, jump-to-section chips, and a scrollable
/// timeline you can watch (simulated slow-motion scroll, or real audio-synced
/// playback when the song's audio is accessible). Layers: waveform, detected
/// beats, section shading and the notes themselves on four lane rows — the
/// same chart data gameplay uses, never a second format. Developer mode
/// (Debug builds) overlays onsets, candidate events, AI importance, selected
/// events, section boundaries and lane-transition jumps, and surfaces
/// suspicious chart properties.
struct ChartPreviewView: View {
    let song: SongRecord
    /// In-preview difficulty switcher (the same tier the detail screen picks).
    @State private var difficulty: DifficultyLevel

    init(song: SongRecord, difficulty: DifficultyLevel = .medium) {
        self.song = song
        _difficulty = State(initialValue: difficulty)
    }

    @Environment(AppState.self) private var appState
    @State private var analysis: AudioAnalysis?
    @State private var chart: Chart?
    @State private var aiDiagnostics: AISongDiagnostics?
    @State private var loadFailed = false

    // Playback / scrubbing state
    @State private var t0: Double = 0            // chart time at the left edge
    @State private var isScrolling = false       // simulated slow-motion scroll
    @State private var simSpeed: Double = 0.5    // seconds of music per second
    @State private var dragStartT0: Double = 0
    @State private var isDragging = false
    @State private var layerWaveform = true
    @State private var layerBeats = false
    @State private var layerSections = true
    @State private var devOverlay = false

    @StateObject private var player = AudioPlayer()
    @State private var audioLoaded = false
    @State private var audioError = false

    /// Presentation density (points per chart second). Larger = more zoomed.
    @State private var zoom: Double = 90

    private let hitLineFraction: CGFloat = 0.18
    private let laneRowHeight: CGFloat = 40
    private let waveformHeight: CGFloat = 46

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if loadFailed {
                    ContentUnavailableView("No chart yet",
                                           systemImage: "chart.bar.doc.horizontal",
                                           description: Text("This song has no stored analysis or chart. Generate one first."))
                } else if let chart {
                    headerCard(chart)
                    difficultyPicker
                    statsCard(chart)
                    validationCard(chart)
                    timelineCard(chart)
                    sectionChips
                    controls
                } else {
                    ProgressView("Loading chart…")
                        .padding(40)
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("Chart Preview")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .onDisappear {
            player.stop()
            isScrolling = false
        }
        .task(id: isScrolling) {
            guard isScrolling else { return }
            let interval = 1.0 / 60.0
            while !Task.isCancelled {
                tick(dt: interval)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        .task(id: player.state) {
            // Keep the playhead on the audio clock while real audio plays.
            guard player.state == .playing, !isScrolling else { return }
            let interval = 1.0 / 60.0
            while !Task.isCancelled && player.state == .playing {
                setT0(player.currentTime)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: - Data

    private func load() {
        let songID = song.id
        let difficulty = self.difficulty
        Task {
            let loaded = try? await Task.detached {
                (try ChartStorage.loadAnalysis(for: songID),
                 try ChartStorage.loadChart(for: songID, difficulty: difficulty))
            }.value
            analysis = loaded?.0
            chart = loaded?.1
            loadFailed = analysis == nil || chart == nil
            t0 = 0
            #if DEBUG
            if let chart, let analysis {
                print("[Preview] loaded \(chart.difficulty.displayName) chart: \(chart.notes.count) notes, \(analysis.sections.count) sections")
            } else {
                print("[Preview] load failed (analysis=\(analysis != nil), chart=\(loaded?.1 != nil))")
            }
            #endif
        }
        aiDiagnostics = appState.ai.diagnostics(for: song.id)
        // Try to load real audio for the synced-playback mode.
        Task {
            guard let url = await appState.resolveAudioURL(for: song) else { return }
            do {
                try player.load(url: url)
                audioLoaded = true
            } catch {
                audioError = true
            }
        }
    }

    /// Switch difficulty in place: reload that tier's chart and rewind.
    private func selectDifficulty(_ level: DifficultyLevel) {
        guard level != difficulty, chart != nil else { return }
        difficulty = level
        pauseAll()
        load()
    }

    // MARK: - Header

    private func headerCard(_ chart: Chart) -> some View {
        HStack(spacing: 14) {
            ArtworkView(data: song.artworkData)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    DifficultyBadge(difficulty: chart.difficulty)
                    tempoText
                }
                Text("\(chart.notes.count) notes · \(String(format: "%.2f", chart.nps)) notes/s · \(Format.duration(chart.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var tempoText: some View {
        if let bpm = song.tempoBPM {
            HStack(spacing: 3) {
                Image(systemName: "metronome")
                    .font(.caption2)
                Text(String(format: "%.0f BPM", bpm))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.white.opacity(0.08), in: Capsule())
        }
    }

    // MARK: - Difficulty switcher

    private var difficultyPicker: some View {
        Picker("Difficulty", selection: Binding(get: { difficulty },
                                                set: { selectDifficulty($0) })) {
            ForEach(DifficultyLevel.allCases, id: \.self) { level in
                Text(level.displayName).tag(level)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Validation flags

    /// Suspicious chart properties (density, lane balance, jumps, spikes,
    /// chords). Always computed; shown compactly in normal mode and in detail
    /// with the developer overlay.
    private func validationFlags(_ chart: Chart) -> [ValidationFlag] {
        let a = ChartAnalyticsBuilder.analyze(chart: chart, analysis: analysis)
        let target = chart.difficulty.targetNPS
        var flags: [ValidationFlag] = []
        if a.notesPerSecond > target * 1.6 {
            flags.append(.init(title: "Excessive density",
                               detail: String(format: "%.2f notes/s vs %.1f target", a.notesPerSecond, target)))
        }
        if a.isSuspiciouslyOneSided {
            let shares = a.laneShares.map { String(format: "%.0f%%", $0 * 100) }.joined(separator: " / ")
            flags.append(.init(title: "Lane imbalance",
                               detail: "lane usage \(shares)"))
        }
        let transitions = max(1, a.sameLaneSteps + a.jump1Steps + a.jump2Steps + a.jump3Steps)
        let jump3Share = Double(a.jump3Steps) / Double(transitions)
        if jump3Share > 0.12 {
            flags.append(.init(title: "Huge jumps",
                               detail: String(format: "%.0f%% of moves are lane 1↔4", jump3Share * 100)))
        }
        if a.maxExtremeBounceRun >= 6 {
            flags.append(.init(title: "Repetitive 1↔4 run",
                               detail: "\(a.maxExtremeBounceRun) consecutive extreme bounces"))
        }
        if let maxSection = a.sectionDensity.map(\.nps).max(),
           a.sustainedNPS > 0.5, maxSection > a.sustainedNPS * 2.5 {
            flags.append(.init(title: "Difficulty spike",
                               detail: String(format: "section peaks at %.1f vs %.1f avg", maxSection, a.sustainedNPS)))
        }
        if a.chordFrequency > 0.22 {
            flags.append(.init(title: "Heavy chords",
                               detail: String(format: "%.0f%% of notes are chords", a.chordFrequency * 100)))
        }
        return flags
    }

    private func validationCard(_ chart: Chart) -> some View {
        let flags = validationFlags(chart)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Chart check", systemImage: flags.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(flags.isEmpty ? .green : .orange)
                Spacer()
                if !flags.isEmpty {
                    Text("\(flags.count) flagged")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            if flags.isEmpty {
                Text("No suspicious properties detected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if devOverlay {
                ForEach(flags) { flag in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(flag.title)
                                .font(.caption.weight(.semibold))
                            Text(flag.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Stats

    private func statsCard(_ chart: Chart) -> some View {
        let a = ChartAnalyticsBuilder.analyze(chart: chart, analysis: analysis)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(chart.difficulty.displayName) · \(String(format: "%.1f / 10", chart.difficultyScore))",
                      systemImage: "gauge.with.dots.needle.50percent")
                    .font(.headline)
                Spacer()
                Text("v\(chart.chartVersion)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow {
                    statCell("Notes", "\(chart.notes.count)")
                    statCell("Notes/s", String(format: "%.2f", a.notesPerSecond))
                    statCell("Sustained", String(format: "%.2f", a.sustainedNPS))
                }
                GridRow {
                    statCell("Simult. max", "\(a.maxSimultaneous)")
                    statCell("Chords", "\(a.chordGroups)")
                    statCell("Beat-fill", "\(a.beatFillNoteCount)")
                }
                GridRow {
                    statCell("Onsets charted", "\(a.eventsCharted)/\(a.eventCandidateCount)")
                    statCell("Span", Format.duration(chart.duration))
                    statCell("Gen", String(format: "%.2fs", chart.generationDuration))
                }
                GridRow {
                    statCell("Holds", "\(a.holdCount)")
                    statCell("Rests", String(format: "%.0f%%", a.restFrequency * 100))
                    statCell("Quality", chart.qualityScore.map { String(format: "%.1f", $0) } ?? "—")
                }
            }
            .font(.subheadline)
            if !chart.validationWarnings.isEmpty {
                Label("\(chart.validationWarnings.count) validation warning(s) — see Diagnostics",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func statCell(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Timeline

    private func timelineCard(_ chart: Chart) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text("Timeline")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                #if DEBUG
                Toggle("Developer", isOn: $devOverlay)
                    .toggleStyle(.button)
                    .font(.caption)
                #endif
                zoomControl
            }
            .padding(.horizontal, 4)

            GeometryReader { geo in
                let width = geo.size.width
                let hitX = width * hitLineFraction
                let scale = zoom   // points per second

                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        drawLayers(context: context, size: size, chart: chart, hitX: hitX, scale: scale)
                    }
                    // Fixed hit-line marker.
                    Rectangle()
                        .fill(.white.opacity(0.28))
                        .frame(width: 2)
                        .offset(x: hitX - 1)
                    // Left-edge current-time badge.
                    Text(Format.duration(max(0, t0)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: Capsule())
                        .offset(x: 4, y: 2)
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture(hitX: hitX, scale: scale))
                .accessibilityLabel("Chart timeline")
                .accessibilityHint("Drag to scrub. Notes approach the white line.")
            }
            .frame(height: laneRowHeight * 4 + waveformHeight + 26)
            .frame(maxWidth: .infinity)

            Text(tipText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var zoomControl: some View {
        Picker("Zoom", selection: $zoom) {
            Text("0.5×").tag(45.0)
            Text("1×").tag(90.0)
            Text("2×").tag(180.0)
        }
        .pickerStyle(.segmented)
        .frame(width: 170)
    }

    private func drawLayers(context: GraphicsContext, size: CGSize, chart: Chart,
                            hitX: CGFloat, scale: Double) {
        guard let analysis else { return }
        let x = { (time: Double) -> CGFloat in hitX + CGFloat(time - t0) * scale }

        // Section shading + boundaries.
        if layerSections {
            for section in analysis.sections {
                let start = x(section.start)
                let end = x(section.end)
                guard end > 0, start < size.width else { continue }
                let color = sectionColor(section.label)
                context.fill(Path(CGRect(x: max(0, start), y: 0,
                                         width: min(size.width, end) - max(0, start),
                                         height: size.height)),
                             with: .color(color.opacity(0.10)))
                if devOverlay {
                    var boundary = Path()
                    boundary.move(to: CGPoint(x: start, y: 0))
                    boundary.addLine(to: CGPoint(x: start, y: size.height))
                    context.stroke(boundary, with: .color(color.opacity(0.6)), lineWidth: 1)
                }
            }
        }

        // Lane rows + waveform strip.
        let lanesTop = waveformHeight + 8
        for lane in 0..<4 {
            let y = lanesTop + CGFloat(lane) * laneRowHeight
            let laneRect = CGRect(x: 0, y: y, width: size.width, height: laneRowHeight)
            context.fill(Path(laneRect), with: .color(.white.opacity(lane % 2 == 0 ? 0.015 : 0.035)))
        }

        // Waveform (RMS envelope) behind the note rows.
        if layerWaveform, analysis.waveform.count > 1 {
            let midY = waveformHeight / 2
            var path = Path()
            for (i, value) in analysis.waveform.enumerated() {
                let time = Double(i) / Double(analysis.waveform.count - 1) * analysis.duration
                let px = x(time)
                guard px >= -2, px <= size.width + 2 else { continue }
                let v = CGFloat(max(0, min(1, value))) * (midY - 3)
                let point = CGPoint(x: px, y: midY - v)
                if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(.cyan.opacity(0.55)), lineWidth: 1.2)
        }

        // Beats (thin ticks across the lane rows).
        if layerBeats {
            for beat in analysis.beats {
                let px = x(beat.time)
                guard px >= 0, px <= size.width else { continue }
                var line = Path()
                line.move(to: CGPoint(x: px, y: lanesTop))
                line.addLine(to: CGPoint(x: px, y: size.height))
                context.stroke(line, with: .color(beat.isStrong ? .yellow.opacity(0.5) : .white.opacity(0.16)),
                               lineWidth: beat.isStrong ? 1.4 : 0.8)
            }
        }

        #if DEBUG
        if devOverlay {
            drawDevOverlay(context: context, size: size, chart: chart,
                           lanesTop: lanesTop, x: x)
        }
        #endif

        // Notes on their lane rows.
        for note in chart.notes {
            let px = x(note.time)
            guard px >= -14, px <= size.width + 14 else { continue }
            let laneY = lanesTop + CGFloat(note.lane) * laneRowHeight
            let rect = CGRect(x: px - 6, y: laneY + 8, width: 12, height: laneRowHeight - 16)
            let color = Color(red: 0.35, green: 0.85, blue: 1.0)
            let alpha = 0.35 + 0.55 * note.strength
            let path = Path(roundedRect: rect, cornerRadius: 4)
            context.fill(path, with: .color(color.opacity(alpha)))
        }
    }

    /// Developer overlay: onsets, candidate events with AI importance,
    /// selected-event rings, lane-transition jumps. Debug builds only.
    private func drawDevOverlay(context: GraphicsContext, size: CGSize, chart: Chart,
                                lanesTop: CGFloat, x: (Double) -> CGFloat) {
        guard let analysis else { return }

        // Detected onsets (green ticks in the waveform strip).
        for onset in analysis.onsets {
            let px = x(onset.time)
            guard px >= 0, px <= size.width else { continue }
            let rect = CGRect(x: px - 1.5, y: 2, width: 3, height: 14)
            context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.green.opacity(0.8)))
        }

        // Candidate events: bar height = AI importance; ring = selected by
        // the chart; magenta = AI contributed, gray = deterministic only.
        if let events = aiDiagnostics?.events {
            for event in events {
                let px = x(event.time)
                guard px >= 0, px <= size.width else { continue }
                let height: CGFloat = 4 + CGFloat(event.finalImportance) * 16
                let rect = CGRect(x: px - 1.5, y: waveformHeight - 4 - height, width: 3, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(event.usedAI ? .purple.opacity(0.85) : .gray.opacity(0.45)))
                if event.selected {
                    let ring = Path(ellipseIn: CGRect(x: px - 4, y: waveformHeight - 4 - height - 4,
                                                      width: 8, height: 8))
                    context.stroke(ring, with: .color(.mint), lineWidth: 1.2)
                }
            }
        }

        // Lane transitions between consecutive notes, colored by jump size
        // (green = adjacent, orange = two lanes, red = 1↔4).
        let notes = chart.notes.sorted { $0.time < $1.time }
        for i in 1..<notes.count {
            let a = notes[i - 1]
            let b = notes[i]
            guard a.lane != b.lane else { continue }
            let ax = x(a.time)
            let bx = x(b.time)
            guard min(ax, bx) >= -10, max(ax, bx) <= size.width + 10 else { continue }
            let ay = lanesTop + CGFloat(a.lane) * laneRowHeight + laneRowHeight / 2
            let by = lanesTop + CGFloat(b.lane) * laneRowHeight + laneRowHeight / 2
            var line = Path()
            line.move(to: CGPoint(x: ax, y: ay))
            line.addLine(to: CGPoint(x: bx, y: by))
            let jump = abs(b.lane - a.lane)
            let color: Color = jump == 1 ? .green.opacity(0.55)
                : jump == 2 ? .orange.opacity(0.6)
                : .red.opacity(0.75)
            context.stroke(line, with: .color(color), lineWidth: 1)
        }
    }

    private func sectionColor(_ label: SectionLabel) -> Color {
        switch label {
        case .intro, .outro: return .gray
        case .verse: return .blue
        case .chorus: return .pink
        case .bridge: return .purple
        case .breakdown: return .teal
        case .generic: return .gray
        }
    }

    // MARK: - Section jump

    private var sectionChips: some View {
        Group {
            if let analysis, !analysis.sections.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Jump to section")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(analysis.sections.enumerated()), id: \.offset) { index, section in
                                Button {
                                    jump(to: section.start)
                                } label: {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(sectionColor(section.label))
                                            .frame(width: 6, height: 6)
                                        Text("\(index + 1). \(section.label.displayName)")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.white.opacity(0.07), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    /// Pause and move the playhead to a section start (audio seeks too).
    private func jump(to time: Double) {
        pauseAll()
        setT0(time)
        if audioLoaded {
            player.seek(to: max(0, time))
        }
    }

    private var tipText: String {
        var parts = ["Drag the timeline to scrub."]
        if isScrolling { parts.append("Scrolling at \(String(format: "%.0f", simSpeed * 100))% speed.") }
        if audioLoaded, player.state == .playing { parts.append("Playing with audio — follow the music.") }
        return parts.joined(separator: " ")
    }

    // MARK: - Scrubbing + simulated playback

    private func dragGesture(hitX: CGFloat, scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    pauseAll()
                    dragStartT0 = t0
                }
                let deltaSeconds = Double(value.translation.width) / scale
                setT0(dragStartT0 - deltaSeconds)
            }
            .onEnded { _ in
                isDragging = false
            }
    }

    /// Advance the timeline by `dt` simulated seconds of music. While real
    /// audio plays, the audio-clock task below owns the playhead instead.
    private func tick(dt: Double) {
        guard isScrolling, !isDragging, player.state != .playing else { return }
        setT0(t0 + dt * simSpeed)
    }

    private func setT0(_ value: Double) {
        let duration = chart?.duration ?? 0
        let upper = max(0, duration - 0.2)
        t0 = min(upper, max(-0.5, value))
        if t0 >= upper { pauseAll() }
    }

    private func pauseAll() {
        isScrolling = false
        player.pause()
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            if isScrolling || player.state == .playing {
                Button {
                    pauseAll()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 10) {
                    Button {
                        isScrolling = true
                    } label: {
                        Label("Scroll", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)

                    if audioLoaded {
                        Button {
                            restartPlayback()
                        } label: {
                            Label("Play with audio", systemImage: "music.note")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                    } else if audioError {
                        Text("Audio unavailable for this song — simulated scroll only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Restart") {
                    pauseAll()
                    setT0(0)
                }
                .disabled(t0 <= 0)

                Spacer()

                Picker("Scroll speed", selection: $simSpeed) {
                    Text("0.25×").tag(0.25)
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .font(.subheadline)

            HStack(spacing: 14) {
                Toggle("Waveform", isOn: $layerWaveform).toggleStyle(.button)
                Toggle("Beats", isOn: $layerBeats).toggleStyle(.button)
                Toggle("Sections", isOn: $layerSections).toggleStyle(.button)
                Spacer()
            }
            .font(.caption)
        }
        .padding(.horizontal, 14)
    }

    /// Start real audio from the current scrub position so the chart runs with
    /// the music; the playhead then follows the audio clock (see the task above).
    private func restartPlayback() {
        isScrolling = true
        player.play(from: max(0, t0))
    }
}

/// One flagged chart property (validation card).
private struct ValidationFlag: Identifiable {
    let title: String
    let detail: String
    var id: String { title }
}