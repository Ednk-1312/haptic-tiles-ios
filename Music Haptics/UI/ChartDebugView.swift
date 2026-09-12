import SwiftUI

/// Debug visualization: waveform, beats, onsets and generated notes.
/// Developer-only (Debug builds).
struct ChartDebugView: View {
    @Environment(AppState.self) private var appState
    let song: SongRecord
    var difficulty: DifficultyLevel = .medium

    @State private var analysis: AudioAnalysis?
    @State private var chart: Chart?
    @State private var aiDiagnostics: AISongDiagnostics?
    @State private var showBeats = true
    @State private var showOnsets = true
    @State private var showNotes = true
    @State private var showSections = true
    @State private var showAI = false

    private let pointsPerSecond: CGFloat = 30
    private let laneBandHeight: CGFloat = 56

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if let analysis, let chart {
                Canvas { context, size in
                    drawSections(context, size: size, analysis)
                    drawWaveform(context, size: size, analysis)
                    if showBeats { drawBeats(context, size: size, analysis) }
                    if showOnsets { drawOnsets(context, size: size, analysis) }
                    if showAI { drawAIImportance(context, size: size) }
                    if showNotes { drawNotes(context, size: size, chart) }
                    drawLegend(context, size: size)
                }
                .frame(width: max(400, CGFloat(analysis.duration) * pointsPerSecond),
                       height: 140 + laneBandHeight * 4 + 40)
            } else {
                Text("No analysis or chart stored for this song yet.")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
        .navigationTitle("Chart Debug")
        .task { load() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Toggle("Sections", isOn: $showSections).toggleStyle(.button)
                Toggle("Beats", isOn: $showBeats).toggleStyle(.button)
                Toggle("Onsets", isOn: $showOnsets).toggleStyle(.button)
                if aiDiagnostics != nil { Toggle("AI", isOn: $showAI).toggleStyle(.button) }
                Toggle("Notes", isOn: $showNotes).toggleStyle(.button)
            }
        }
    }

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
            aiDiagnostics = appState.ai.diagnostics(for: songID)
        }
    }

    // MARK: - Drawing

    private func x(_ time: Double) -> CGFloat { CGFloat(time) * pointsPerSecond }

    private func drawWaveform(_ context: GraphicsContext, size: CGSize, _ analysis: AudioAnalysis) {
        let samples = analysis.waveform
        guard samples.count > 1 else { return }
        var path = Path()
        let midY: CGFloat = 60
        let amplitude: CGFloat = 50
        for i in samples.indices {
            let t = Double(i) / Double(samples.count - 1) * analysis.duration
            let v = CGFloat(samples[i]) * amplitude
            let point = CGPoint(x: x(t), y: midY - v)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(.cyan.opacity(0.7)), lineWidth: 1.5)
    }

    private func drawBeats(_ context: GraphicsContext, size: CGSize, _ analysis: AudioAnalysis) {
        for beat in analysis.beats {
            var line = Path()
            line.move(to: CGPoint(x: x(beat.time), y: 10))
            line.addLine(to: CGPoint(x: x(beat.time), y: 110))
            context.stroke(line, with: .color(beat.isStrong ? .yellow.opacity(0.9) : .orange.opacity(0.5)),
                           lineWidth: beat.isStrong ? 2 : 1)
        }
    }

    private func drawOnsets(_ context: GraphicsContext, size: CGSize, _ analysis: AudioAnalysis) {
        for onset in analysis.onsets {
            let rect = CGRect(x: x(onset.time) - 2, y: 112, width: 4, height: 12)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.green.opacity(0.9)))
        }
    }

    /// AI importance overlay: candidate events scaled by fused importance
    /// (tall = high AI importance, magenta = AI used, gray = deterministic
    /// fallback, ring = selected by the chart). Developer visualization only.
    private func drawAIImportance(_ context: GraphicsContext, size: CGSize) {
        guard let events = aiDiagnostics?.events else { return }
        for event in events {
            let height: CGFloat = 4 + CGFloat(event.finalImportance) * 14
            let rect = CGRect(x: x(event.time) - 2, y: 108 - height, width: 4, height: height)
            let color: Color = event.usedAI ? .purple.opacity(0.85) : .gray.opacity(0.45)
            context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
            if event.selected {
                let ring = Path(ellipseIn: CGRect(x: x(event.time) - 5, y: 108 - height - 5, width: 10, height: 10))
                context.stroke(ring, with: .color(.mint), lineWidth: 1.5)
            }
        }
    }

    private func drawNotes(_ context: GraphicsContext, size: CGSize, _ chart: Chart) {
        for note in chart.notes {
            let laneY: CGFloat = 140 + CGFloat(note.lane) * laneBandHeight
            let rect = CGRect(x: x(note.time) - 5, y: laneY + 6, width: 10, height: laneBandHeight - 12)
            context.fill(Path(roundedRect: rect, cornerRadius: 3),
                         with: .color(.mint.opacity(0.5 + 0.5 * note.strength)))
        }
    }

    private func drawSections(_ context: GraphicsContext, size: CGSize, _ analysis: AudioAnalysis) {
        for section in analysis.sections {
            let rect = CGRect(x: x(section.start), y: 0,
                              width: x(section.end) - x(section.start), height: size.height)
            let color: Color
            switch section.label {
            case .intro: color = .gray
            case .verse: color = .blue
            case .chorus: color = .pink
            case .bridge: color = .purple
            case .breakdown: color = .teal
            case .outro: color = .gray
            case .generic: color = .gray
            }
            context.fill(Path(rect), with: .color(color.opacity(0.08)))
            let label = Text(section.label.displayName.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(color)
            context.draw(label, at: CGPoint(x: x(section.start) + 24, y: 124))
        }
    }

    private func drawLegend(_ context: GraphicsContext, size: CGSize) {
        let text = Text("waveform · beats(orange/yellow) · onsets(green) · AI importance(purple/gray) · notes per lane(mint)")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
        context.draw(text, at: CGPoint(x: 12, y: size.height - 12), anchor: .bottomLeading)
    }
}