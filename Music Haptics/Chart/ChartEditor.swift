import Foundation

/// Snapping grid for the chart editor. Beats come from the detected beat
/// track; subdivisions interpolate between consecutive beats.
enum SnapGrid: String, CaseIterable, Sendable {
    case off, quarter, eighth, sixteenth

    var displayName: String {
        switch self {
        case .off: return "Free"
        case .quarter: return "1/4"
        case .eighth: return "1/8"
        case .sixteenth: return "1/16"
        }
    }

    /// Snap candidates derived from the beat times. A quarter grid is the
    /// beats themselves; eighths/sixteenths split each beat interval evenly.
    func points(beats: [Beat]) -> [Double] {
        guard self != .off else { return [] }
        var points: [Double] = []
        for (i, beat) in beats.enumerated() {
            points.append(beat.time)
            if self == .eighth || self == .sixteenth {
                guard i + 1 < beats.count else { continue }
                let next = beats[i + 1].time
                let step = (next - beat.time) / 2
                points.append(beat.time + step)
            }
            if self == .sixteenth {
                guard i + 1 < beats.count else { continue }
                let next = beats[i + 1].time
                let step = (next - beat.time) / 4
                points.append(beat.time + step)
                points.append(beat.time + step * 2)
                points.append(beat.time + step * 3)
            }
        }
        return points
    }

    /// Snap `time` to the nearest grid point IF it is within `tolerance`
    /// seconds of one — fine manual edits are never forced onto the grid.
    func snapIfClose(_ time: Double, beats: [Beat], tolerance: Double = 0.045) -> Double {
        guard self != .off else { return time }
        var best = time
        var bestDelta = tolerance
        for point in points(beats: beats) {
            let delta = abs(point - time)
            if delta < bestDelta {
                bestDelta = delta
                best = point
            }
        }
        return best
    }
}

/// Lightweight rhythm-chart editor — a working copy of a generated chart with
/// add/delete/move/hold/chord operations, optional beat-grid snapping, undo/
/// redo, and deterministic validation on every mutation. The original
/// generated chart is preserved untouched; saving writes a SEPARATE versioned
/// edited file, so regeneration never silently overwrites edits.
struct ChartEditor: Sendable {
    /// The generated baseline this editor started from (never mutated).
    let original: Chart
    /// Working note set, always sorted by time.
    private(set) var notes: [ChartNote]
    let songDuration: Double
    /// Beat track used for snapping + grid display.
    let beats: [Beat]
    let constraints: ChartConstraints

    private(set) var undoStack: [[ChartNote]] = []
    private(set) var redoStack: [[ChartNote]] = []

    init(chart: Chart, songDuration: Double, beats: [Beat] = [],
         constraints: ChartConstraints? = nil) {
        self.original = chart
        self.songDuration = songDuration
        self.beats = beats
        self.constraints = constraints
            ?? ChartConstraints.forDifficulty(chart.difficulty, densityMultiplier: 1.0)
        self.notes = chart.notes.sorted { $0.time < $1.time }
    }

    /// True when the working notes differ from the generated baseline.
    var isModified: Bool { notes != original.notes }

    var nextNoteID: Int { (notes.map(\.id).max() ?? -1) + 1 }

    /// Current validation result (recomputed on every mutation).
    private(set) var validation: ValidationResult = ValidationResult(hardFailures: ["Chart is empty"], warnings: [])

    // MARK: - Mutations (each pushes undo, recomputes validation)

    private mutating func pushUndo() {
        undoStack.append(notes)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private mutating func commit() {
        notes.sort { $0.time < $1.time }
        validation = ChartValidator.validate(notes, constraints: constraints)
    }

    /// Adds a note at (time, lane). `snap` grid applies when the position is
    /// within the snapping tolerance of a grid point. Returns the new note
    /// (nil when the lane or position is invalid).
    @discardableResult
    mutating func addNote(time: Double, lane: Int, type: ChartNoteType = .tap,
                          duration: Double = 0, snap: SnapGrid? = nil) -> ChartNote? {
        guard (0..<4).contains(lane), time.isFinite, duration.isFinite,
              time >= 0, time <= songDuration, duration >= 0 else { return nil }
        let snapped = snap?.snapIfClose(time, beats: beats) ?? time
        guard snapped >= 0, snapped <= songDuration else { return nil }
        pushUndo()
        let note = ChartNote(id: nextNoteID, time: snapped, lane: lane,
                             duration: type == .hold ? max(duration, 0.05) : 0,
                             type: type, strength: 0.8)
        notes.append(note)
        commit()
        return note
    }

    /// Adds a CHORD voice at the same time as an existing note, in the first
    /// free lane (different from every note within 0.1s of that time).
    @discardableResult
    mutating func addChordVoice(at time: Double) -> ChartNote? {
        let occupied = Set(notes.filter { abs($0.time - time) < 0.1 }.map(\.lane))
        guard let lane = (0..<4).first(where: { !occupied.contains($0) }) else { return nil }
        return addNote(time: time, lane: lane)
    }

    /// Deletes the given note ids (a chord is deleted voice by voice, or all
    /// at once via the selection set).
    @discardableResult
    mutating func deleteNotes(ids: Set<Int>) -> Bool {
        let before = notes.count
        pushUndo()
        notes.removeAll { ids.contains($0.id) }
        commit()
        return notes.count != before
    }

    /// Moves a note in time and/or lane. Snapping applies when enabled and
    /// within tolerance; out-of-bounds positions are clamped.
    @discardableResult
    mutating func moveNote(id: Int, to time: Double, lane: Int, snap: SnapGrid? = nil) -> Bool {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return false }
        let clampedLane = min(3, max(0, lane))
        let clampedTime = min(songDuration, max(0, time))
        let snapped = snap?.snapIfClose(clampedTime, beats: beats) ?? clampedTime
        guard notes[idx].time != snapped || notes[idx].lane != clampedLane else { return false }
        pushUndo()
        notes[idx].time = min(songDuration, max(0, snapped))
        notes[idx].lane = clampedLane
        commit()
        return true
    }

    /// Turns a tap into a hold of the given duration, or resizes an existing
    /// hold. Duration is clamped to the song.
    @discardableResult
    mutating func setHold(id: Int, duration: Double) -> Bool {
        guard let idx = notes.firstIndex(where: { $0.id == id }),
              duration.isFinite else { return false }
        let clamped = min(songDuration - notes[idx].time, max(0.05, duration))
        guard notes[idx].type != .hold || notes[idx].duration != clamped else { return false }
        pushUndo()
        notes[idx].type = .hold
        notes[idx].duration = clamped
        commit()
        return true
    }

    /// Removes a hold (back to a tap).
    @discardableResult
    mutating func removeHold(id: Int) -> Bool {
        guard let idx = notes.firstIndex(where: { $0.id == id }),
              notes[idx].type == .hold else { return false }
        pushUndo()
        notes[idx].type = .tap
        notes[idx].duration = 0
        commit()
        return true
    }

    // MARK: - Undo / redo

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(notes)
        notes = previous
        commit()
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(notes)
        notes = next
        commit()
    }

    // MARK: - Save

    /// Builds the playable chart for this edited state: a copy of the
    /// generated chart with the edited notes, a bumped chart version, fresh
    /// validation warnings, and re-computed density/difficulty metadata.
    /// The edited variant NEVER overwrites the generated chart file.
    func makeEditedChart() -> Chart {
        var chart = original
        chart.notes = notes
        chart.chartVersion = original.chartVersion + 1
        chart.validationWarnings = validation.hardFailures + validation.warnings
        chart.nps = notes.isEmpty ? 0 : Double(notes.count) / max(songDuration, 1)
        chart.difficultyScore = recomputeDifficultyScore()
        return chart
    }

    /// Difficulty estimate for the edited chart: difficulty rises/falls with
    /// density and chord usage relative to the generated baseline, keeping
    /// the same scale.
    private func recomputeDifficultyScore() -> Double {
        guard !original.notes.isEmpty, !notes.isEmpty else {
            return min(10, max(0, original.difficultyScore))
        }
        let originalNPS = Double(original.notes.count) / max(original.duration, 1)
        let editedNPS = Double(notes.count) / max(songDuration, 1)
        let densityFactor = originalNPS > 0 ? editedNPS / originalNPS : 1
        let chordFactor = chordShare(notes) / max(chordShare(original.notes), 0.001)
        let score = original.difficultyScore * (0.65 + 0.35 * min(2.5, densityFactor))
            * (0.9 + 0.1 * min(3, chordFactor))
        return min(10, max(0, score))
    }

    private func chordShare(_ notes: [ChartNote]) -> Double {
        let sorted = notes.sorted { $0.time < $1.time }
        var inChord = 0
        var i = 0
        while i < sorted.count {
            let j = i + 1
            if j < sorted.count, sorted[j].time - sorted[i].time < 0.1 { inChord += 2; i = j + 1 }
            else { i += 1 }
        }
        return notes.isEmpty ? 0 : Double(inChord) / Double(notes.count)
    }
}

/// On-disk wrapper for an edited chart: the edited chart itself, the generated
/// chart version it was based on (so incompatible regenerations are detected),
/// and the editor schema version.
struct EditedChartFile: Codable, Sendable {
    static let currentEditorSchemaVersion = 1

    var chart: Chart
    var originalChartVersion: Int
    var editedAt: Date
    var editorSchemaVersion: Int

    init(chart: Chart, originalChartVersion: Int, editedAt: Date = Date(),
         editorSchemaVersion: Int = currentEditorSchemaVersion) {
        self.chart = chart
        self.originalChartVersion = originalChartVersion
        self.editedAt = editedAt
        self.editorSchemaVersion = editorSchemaVersion
    }
}