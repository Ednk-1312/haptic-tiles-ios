import SwiftUI

/// Lightweight rhythm-chart editor. Tap an empty lane to add a note (snapped
/// to the beat grid when within tolerance — fine edits are never forced), tap
/// a note to select it (chord-aware: a tap selects every simultaneous voice),
/// drag a selected note to move it in time and lane, use the toolbar for
/// hold/chord/delete, and undo/redo freely. Saving writes a SEPARATE versioned
/// edited file; the generated chart is never overwritten. The same playability
/// validator as generation runs on every mutation — warnings show, never block.
struct ChartEditorView: View {
    let song: SongRecord
    var difficulty: DifficultyLevel = .medium

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var editor: ChartEditor?
    @State private var analysis: AudioAnalysis?
    @State private var baselineOriginalVersion: Int = ChartStorage.chartVersion
    @State private var loadFailed = false

    @State private var selection: Set<Int> = []
    @State private var snap: SnapGrid = .eighth
    @State private var holdMode = false
    @State private var holdBeats: Double = 1.0
    @State private var t0: Double = 0
    @State private var zoom: Double = 90
    @State private var savedToast = false
    @State private var confirmRegenerate = false
    @State private var confirmDiscard = false

    private let laneRowHeight: CGFloat = 56

    var body: some View {
        Group {
            if let editor, let analysis {
                VStack(spacing: 0) {
                    headerBar(editor)
                    timeline(editor, analysis)
                    toolbar
                    snapBar
                    holdControls
                    validationPanel(editor)
                }
            } else if loadFailed {
                ContentUnavailableView("No chart to edit",
                                       systemImage: "pencil.slash",
                                       description: Text("Generate a chart for this difficulty first."))
            } else {
                ProgressView("Loading chart…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Chart Editor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .confirmationDialog("Regenerate the chart?",
                            isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) {
                appState.regenerateEditedChart(for: song, difficulty: difficulty)
                load()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your edits for this difficulty will be discarded and a fresh chart will be generated from the analysis.")
        }
        .confirmationDialog("Discard edits?",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                appState.discardEdits(for: song, difficulty: difficulty)
                load()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Revert to the generated chart. Your edited version will be removed.")
        }
    }

    // MARK: - Loading

    private func load() {
        let songID = song.id
        let difficulty = self.difficulty
        Task {
            let loaded = try? await Task.detached {
                let analysis = try ChartStorage.loadAnalysis(for: songID)
                // Prefer an existing edited variant as the baseline; fall back
                // to the generated chart.
                let edited = try ChartStorage.loadEdited(for: songID, difficulty: difficulty)
                let generated = try ChartStorage.loadChart(for: songID, difficulty: difficulty)
                return (analysis, edited, generated)
            }.value
            analysis = loaded?.0
            loadFailed = loaded == nil
            guard let loaded else { return }
            if let edited = loaded.1 {
                baselineOriginalVersion = edited.originalChartVersion
                guard let analysis else { return }
                editor = ChartEditor(chart: edited.chart, songDuration: analysis.duration,
                                     beats: analysis.beats)
            } else if let generated = loaded.2 {
                baselineOriginalVersion = generated.chartVersion
                guard let analysis else { return }
                editor = ChartEditor(chart: generated, songDuration: analysis.duration,
                                     beats: analysis.beats)
            } else {
                loadFailed = true
            }
            selection = []
            t0 = 0
        }
    }

    // MARK: - Header

    private func headerBar(_ editor: ChartEditor) -> some View {
        HStack(spacing: 8) {
            Label(editor.isModified ? "Edited" : "Generated",
                  systemImage: editor.isModified ? "pencil.circle.fill" : "checkmark.circle")
                .font(.caption.weight(.bold))
                .foregroundStyle(editor.isModified ? .orange : .green)
            Spacer()
            Text("\(editor.notes.count) notes · v\(editor.original.chartVersion + (editor.isModified ? 1 : 0))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Timeline

    private func timeline(_ editor: ChartEditor, _ analysis: AudioAnalysis) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            Canvas { context, size in
                drawLanes(context: context, size: size, editor: editor, analysis: analysis)
            }
            .contentShape(Rectangle())
            .gesture(canvasGesture(editor: editor, analysis: analysis, width: width))
        }
        .frame(height: laneRowHeight * 4 + 20)
        .background(Color(red: 0.07, green: 0.07, blue: 0.11))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                Button { t0 = max(0, t0 - 5) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Scroll timeline back 5 seconds")
                Text(Format.duration(max(0, t0)))
                    .font(.caption2.monospacedDigit())
                    .accessibilityLabel("Timeline position")
                Button { t0 = min(max(0, analysis.duration - 3), t0 + 5) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Scroll timeline forward 5 seconds")
            }
            .font(.caption2)
            .buttonStyle(.bordered)
            .padding(4)
        }
    }

    private func x(_ time: Double, width: CGFloat) -> CGFloat {
        CGFloat(time - t0) * zoom + width * 0.15
    }

    private func drawLanes(context: GraphicsContext, size: CGSize,
                           editor: ChartEditor, analysis: AudioAnalysis) {
        // Lane rows.
        for lane in 0..<4 {
            let y = CGFloat(lane) * laneRowHeight
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: laneRowHeight)),
                         with: .color(lane % 2 == 0 ? .white.opacity(0.02) : .white.opacity(0.045)))
            var label = Path()
            label.move(to: CGPoint(x: 0, y: y))
            label.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(label, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
        }

        // Beat grid + section shading.
        for section in analysis.sections {
            let sx = x(section.start, width: size.width)
            let ex = x(section.end, width: size.width)
            guard ex > 0, sx < size.width else { continue }
            let color = sectionColor(section.label)
            context.fill(Path(CGRect(x: max(0, sx), y: 0,
                                     width: min(size.width, ex) - max(0, sx),
                                     height: size.height)), with: .color(color.opacity(0.07)))
        }
        for beat in analysis.beats {
            let bx = x(beat.time, width: size.width)
            guard bx >= 0, bx <= size.width else { continue }
            var line = Path()
            line.move(to: CGPoint(x: bx, y: 0))
            line.addLine(to: CGPoint(x: bx, y: size.height))
            context.stroke(line, with: .color(beat.isStrong ? .yellow.opacity(0.30) : .white.opacity(0.10)),
                           lineWidth: beat.isStrong ? 1.2 : 0.6)
        }

        // Notes. Holds render as long vertical tiles; selected notes (and
        // their simultaneous voices) get a bright outline.
        let sorted = editor.notes
        for note in sorted {
            let px = x(note.time, width: size.width)
            guard px >= -20, px <= size.width + 20 else { continue }
            let laneY = CGFloat(note.lane) * laneRowHeight
            let durationPx = max(6, CGFloat(note.duration) * zoom)
            let rect = CGRect(x: px - 7, y: laneY + 6,
                              width: 14, height: max(laneRowHeight - 12, durationPx))
            let isSelected = selection.contains(note.id)
            let inChord = sorted.contains { $0.id != note.id && abs($0.time - note.time) < 0.1 }
            let color: Color = note.type == .hold
                ? (isSelected ? .pink : Color(red: 0.95, green: 0.55, blue: 0.65))
                : (isSelected ? .yellow : Color(red: 0.35, green: 0.85, blue: 1.0))
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(0.85)))
            if isSelected || inChord {
                context.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 5),
                               with: .color(isSelected ? .white.opacity(0.95) : .white.opacity(0.30)),
                               lineWidth: isSelected ? 2 : 1)
            }
        }
    }

    // MARK: - Canvas gestures

    private func canvasGesture(editor: ChartEditor, analysis: AudioAnalysis,
                               width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Hit-test on the initial touch: drag a note, or scroll.
                if !isDraggingNote, !isScrollingCanvas {
                    let time = t0 + Double((value.startLocation.x - width * 0.15) / zoom)
                    let lane = min(3, max(0, Int(value.startLocation.y / laneRowHeight)))
                    if let hit = editor.notes.last(where: {
                        $0.lane == lane && abs($0.time - time) <= 0.09
                    }) {
                        isDraggingNote = true
                        draggedID = hit.id
                        selection = editor.notes.filter { abs($0.time - hit.time) < 0.1 }.map(\.id).reduce(into: Set<Int>()) { $0.insert($1) }
                        return
                    }
                    isScrollingCanvas = true
                    scrollStartT0 = t0
                    scrollStartX = value.startLocation.x
                }
                if isDraggingNote, let id = draggedID {
                    let time = t0 + Double((value.location.x - width * 0.15) / zoom)
                    let lane = min(3, max(0, Int(value.location.y / laneRowHeight)))
                    mutate { $0.moveNote(id: id, to: time, lane: lane, snap: snap) }
                } else if isScrollingCanvas {
                    t0 = min(max(0, analysis.duration - 1), max(0, scrollStartT0 - Double(value.location.x - scrollStartX) / zoom))
                }
            }
            .onEnded { value in
                // Tap (no real drag): add a note on empty space, or select.
                if !isDraggingNote, !isScrollingCanvas {
                    let time = t0 + Double((value.location.x - width * 0.15) / zoom)
                    let lane = min(3, max(0, Int(value.location.y / laneRowHeight)))
                    if let hit = editor.notes.last(where: { $0.lane == lane && abs($0.time - time) <= 0.09 }) {
                        selection = editor.notes.filter { abs($0.time - hit.time) < 0.1 }.map(\.id).reduce(into: Set<Int>()) { $0.insert($1) }
                    } else if time >= 0, time <= analysis.duration {
                        mutate {
                            $0.addNote(time: time, lane: lane,
                                       type: holdMode ? .hold : .tap,
                                       duration: holdMode ? holdDurationSeconds(analysis) : 0,
                                       snap: snap)
                        }
                    }
                }
                isDraggingNote = false
                isScrollingCanvas = false
                draggedID = nil
            }
    }

    private func holdDurationSeconds(_ analysis: AudioAnalysis) -> Double {
        let bpm = max(analysis.tempoBPM ?? 120, 1)
        return holdBeats * 60.0 / bpm
    }

    /// Runs an editor mutation through the state (ChartEditor is a value
    /// type, so mutations go through the @State property).
    private func mutate(_ body: (inout ChartEditor) -> Void) {
        guard var ed = editor else { return }
        body(&ed)
        editor = ed
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { mutate { $0.undo() } } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(editor?.undoStack.isEmpty ?? true)
            .accessibilityLabel("Undo")
            Button { mutate { $0.redo() } } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(editor?.redoStack.isEmpty ?? true)
            .accessibilityLabel("Redo")

            Divider().frame(height: 22)

            Picker("", selection: $holdMode) {
                Text("Tap").tag(false)
                Text("Hold").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .disabled(editor == nil)

            Button {
                if let note = editor?.notes.first(where: { selection.contains($0.id) }) {
                    mutate { $0.addChordVoice(at: note.time) }
                }
            } label: {
                Image(systemName: "rectangle.3.group")
            }
            .disabled(selection.isEmpty)
            .accessibilityLabel("Add chord voice")

            Button {
                mutate { $0.deleteNotes(ids: selection) }
                selection = []
            } label: {
                Image(systemName: "trash")
            }
            .disabled(selection.isEmpty)
            .accessibilityLabel("Delete selected notes")

            Spacer()

            Button {
                save()
            } label: {
                Label("Save", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(editor?.isModified != true)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.10, green: 0.10, blue: 0.15))
        .overlay(alignment: .top) {
            if savedToast {
                Text("Saved")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.green.opacity(0.9), in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// Hold duration (beats) when a hold is selected.
    private var holdControls: some View {
        Group {
            if let editor, selection.count == 1,
               let note = editor.notes.first(where: { selection.contains($0.id) }),
               note.type == .hold {
                HStack(spacing: 8) {
                    Text("Hold")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Slider(value: $holdBeats, in: 0.5...4, step: 0.25)
                    Text(String(format: "%.2f beats", holdBeats))
                        .font(.caption.monospacedDigit())
                    Button("Release") {
                        mutate { $0.removeHold(id: note.id) }
                        selection = []
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    /// Snap picker + hold controls row.
    private var snapBar: some View {
        HStack(spacing: 10) {
            Text("Snap")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Snap", selection: $snap) {
                ForEach(SnapGrid.allCases, id: \.self) { grid in
                    Text(grid.displayName).tag(grid)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Spacer()
            if let editor, selection.count == 1,
               let note = editor.notes.first(where: { selection.contains($0.id) }),
               note.type == .tap {
                Button {
                    if let analysis {
                        mutate { $0.setHold(id: note.id, duration: holdDurationSeconds(analysis)) }
                    }
                } label: {
                    Label("Make Hold", systemImage: "rectangle.portrait.fill")
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Validation

    private func validationPanel(_ editor: ChartEditor) -> some View {
        let result = editor.validation
        return Group {
            if !result.hardFailures.isEmpty || !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Validation · \(result.hardFailures.count) issues, \(result.warnings.count) warnings")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(result.hardFailures.isEmpty ? .orange : .red)
                    ForEach(Array(result.hardFailures.enumerated()), id: \.offset) { _, text in
                        Label(text, systemImage: "xmark.octagon.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, text in
                        Label(text, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Save / regenerate / discard

    private func save() {
        guard let editor, editor.isModified else { return }
        let file = EditedChartFile(chart: editor.makeEditedChart(),
                                   originalChartVersion: baselineOriginalVersion)
        appState.saveEditedChart(file, for: song)
        withAnimation { savedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation { savedToast = false }
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

    // MARK: - Gesture scratch state

    @State private var isDraggingNote = false
    @State private var isScrollingCanvas = false
    @State private var draggedID: Int?
    @State private var scrollStartT0: Double = 0
    @State private var scrollStartX: CGFloat = 0
}