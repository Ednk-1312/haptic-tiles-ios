import XCTest
@testable import Music_Haptics

/// Deterministic chart-editor tests. ChartEditor is a pure state machine —
/// every operation, snap decision and validation result is reproducible.
final class ChartEditorTests: XCTestCase {
    private var songID: UUID { UUID(uuidString: "11111111-2222-3333-4444-555555555555")! }

    override func setUpWithError() throws {
        ChartStorage.deleteAllCharts(for: songID)
    }

    override func tearDownWithError() throws {
        ChartStorage.deleteAllCharts(for: songID)
    }

    private func makeChart(notes: [ChartNote] = [], duration: Double = 30) -> Chart {
        Chart(songID: songID, difficulty: .medium, chartVersion: 4, seed: 1,
              notes: notes, generatedAt: Date(timeIntervalSince1970: 0), nps: 1,
              duration: duration, difficultyScore: 5.0, validationWarnings: [],
              generationDuration: 0.1)
    }

    private func beats(at times: [Double]) -> [Beat] {
        times.map { Beat(time: $0, strength: 1.0, isStrong: false) }
    }

    // MARK: - Add / delete / move

    @MainActor
    func testAddAndDelete() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 30)
        XCTAssertTrue(editor.isModified == false)

        let note = editor.addNote(time: 5, lane: 1)!
        XCTAssertEqual(editor.notes.count, 1)
        XCTAssertEqual(note.time, 5)
        XCTAssertEqual(note.lane, 1)
        XCTAssertEqual(note.type, .tap)
        XCTAssertTrue(editor.isModified)
        XCTAssertTrue(editor.undoStack.count == 1)

        XCTAssertTrue(editor.deleteNotes(ids: [note.id]))
        XCTAssertTrue(editor.notes.isEmpty)
        XCTAssertFalse(editor.isModified)   // back to the generated baseline
    }

    @MainActor
    func testAddRejectsInvalidLaneAndTime() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 30)
        XCTAssertNil(editor.addNote(time: 5, lane: 4))
        XCTAssertNil(editor.addNote(time: 5, lane: -1))
        XCTAssertNil(editor.addNote(time: 31, lane: 0))
        XCTAssertNil(editor.addNote(time: -1, lane: 0))
        XCTAssertNil(editor.addNote(time: .nan, lane: 0))
        XCTAssertTrue(editor.notes.isEmpty)
    }

    @MainActor
    func testMoveNoteInTimeAndLane() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 30)
        let note = editor.addNote(time: 5, lane: 1)!
        XCTAssertTrue(editor.moveNote(id: note.id, to: 12.5, lane: 3))
        let moved = editor.notes[0]
        XCTAssertEqual(moved.time, 12.5)
        XCTAssertEqual(moved.lane, 3)
        // Out-of-bounds lanes clamp, not crash.
        XCTAssertTrue(editor.moveNote(id: note.id, to: 8, lane: 99))
        XCTAssertEqual(editor.notes[0].lane, 3)
        // Moving to the same position is a no-op.
        XCTAssertFalse(editor.moveNote(id: note.id, to: 8, lane: 3))
        // Unknown ids are safe no-ops.
        XCTAssertFalse(editor.moveNote(id: 999, to: 1, lane: 1))
    }

    // MARK: - Holds

    @MainActor
    func testHoldCreateEditAndRemove() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 30)
        let note = editor.addNote(time: 5, lane: 1)!

        XCTAssertTrue(editor.setHold(id: note.id, duration: 2.0))
        var held = editor.notes[0]
        XCTAssertEqual(held.type, .hold)
        XCTAssertEqual(held.duration, 2.0)

        XCTAssertTrue(editor.setHold(id: note.id, duration: 4.5))
        held = editor.notes[0]
        XCTAssertEqual(held.duration, 4.5)

        XCTAssertTrue(editor.removeHold(id: note.id))
        held = editor.notes[0]
        XCTAssertEqual(held.type, .tap)
        XCTAssertEqual(held.duration, 0)

        // removeHold on a tap is a no-op.
        XCTAssertFalse(editor.removeHold(id: note.id))
    }

    @MainActor
    func testAddHoldDirectly() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 30)
        let hold = editor.addNote(time: 4, lane: 2, type: .hold, duration: 1.5)!
        XCTAssertEqual(hold.type, .hold)
        XCTAssertEqual(hold.duration, 1.5)
    }

    // MARK: - Chords

    @MainActor
    func testChordVoices() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 30)
        _ = editor.addNote(time: 5, lane: 0)
        let voice = editor.addChordVoice(at: 5)!
        XCTAssertEqual(voice.time, 5)
        XCTAssertNotEqual(voice.lane, 0)

        // Third voice lands in the remaining free lane.
        let third = editor.addChordVoice(at: 5)!
        XCTAssertEqual(Set([0, voice.lane, third.lane]).count, 3)

        // Fourth voice fills the last lane; a fifth is impossible.
        let fourth = editor.addChordVoice(at: 5)!
        XCTAssertNotNil(fourth)
        XCTAssertNil(editor.addChordVoice(at: 5))

        // The validator flags the 4-note chord (medium max = 2).
        XCTAssertFalse(editor.validation.hardFailures.isEmpty)
    }

    // MARK: - Undo / redo

    @MainActor
    func testUndoRedoCycle() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 30)
        let a = editor.addNote(time: 5, lane: 0)!
        let b = editor.addNote(time: 7, lane: 1)!
        XCTAssertEqual(editor.notes.count, 2)

        editor.undo()
        XCTAssertEqual(editor.notes.count, 1)
        XCTAssertEqual(editor.notes[0].id, a.id)
        editor.undo()
        XCTAssertTrue(editor.notes.isEmpty)
        // Nothing to undo.
        editor.undo()
        XCTAssertTrue(editor.notes.isEmpty)

        editor.redo()
        XCTAssertEqual(editor.notes.count, 1)
        editor.redo()
        XCTAssertEqual(editor.notes.count, 2)
        XCTAssertEqual(Set(editor.notes.map(\.id)), Set([a.id, b.id]))
        // Nothing to redo.
        editor.redo()
        XCTAssertEqual(editor.notes.count, 2)
    }

    @MainActor
    func testNewEditClearsRedo() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 30)
        let note = editor.addNote(time: 5, lane: 0)!
        editor.undo()
        XCTAssertEqual(editor.redoStack.count, 1)
        _ = editor.addNote(time: 6, lane: 1)
        XCTAssertTrue(editor.redoStack.isEmpty)
        _ = note
    }

    // MARK: - Snapping

    @MainActor
    func testSnapCloseButNotFar() {
        let gridBeats = beats(at: [1.0, 2.0, 3.0])
        // Quarter grid: 1.03 snaps to 1.0; 1.2 stays 1.2 (fine edit).
        XCTAssertEqual(SnapGrid.quarter.snapIfClose(1.03, beats: gridBeats), 1.0, accuracy: 0.0001)
        XCTAssertEqual(SnapGrid.quarter.snapIfClose(1.2, beats: gridBeats), 1.2, accuracy: 0.0001)
        // Off never snaps.
        XCTAssertEqual(SnapGrid.off.snapIfClose(1.03, beats: gridBeats), 1.03, accuracy: 0.0001)
        // Eighths split each beat interval in half: 1.49 → 1.5.
        XCTAssertEqual(SnapGrid.eighth.snapIfClose(1.49, beats: gridBeats), 1.5, accuracy: 0.0001)
        // A position between eighth points (1.25 is a sixteenth, not an
        // eighth) is left alone.
        XCTAssertEqual(SnapGrid.eighth.snapIfClose(1.26, beats: gridBeats), 1.26, accuracy: 0.0001)
        // Sixteenths: quarters at 1.25/1.5/1.75 between the 1s beats.
        XCTAssertEqual(SnapGrid.sixteenth.snapIfClose(1.24, beats: gridBeats), 1.25, accuracy: 0.0001)
        XCTAssertEqual(SnapGrid.sixteenth.snapIfClose(1.51, beats: gridBeats), 1.5, accuracy: 0.0001)
    }

    @MainActor
    func testAddNoteUsesSnapWhenClose() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 30, beats: beats(at: [1.0, 2.0, 3.0]))
        let snapped = editor.addNote(time: 1.02, lane: 0, snap: .quarter)!
        XCTAssertEqual(snapped.time, 1.0, accuracy: 0.0001)
        // A deliberate fine position stays untouched.
        let fine = editor.addNote(time: 1.35, lane: 0, snap: .quarter)!
        XCTAssertEqual(fine.time, 1.35, accuracy: 0.0001)
    }

    // MARK: - Validation

    @MainActor
    func testValidationCatchesProblems() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 30)
        // Baseline empty chart hard-fails (nothing to play).
        XCTAssertFalse(editor.validation.hardFailures.isEmpty)

        // Two notes 10ms apart in different lanes are ONE valid chord (the
        // validator treats a 0.1s window as one musical event).
        _ = editor.addNote(time: 1, lane: 0)!
        _ = editor.addNote(time: 1.01, lane: 3)!
        XCTAssertTrue(editor.validation.hardFailures.isEmpty)
        // A THIRD voice in the same window exceeds the medium cap (2).
        _ = editor.addNote(time: 1.02, lane: 1)!
        XCTAssertFalse(editor.validation.hardFailures.isEmpty)
    }

    @MainActor
    func testValidationWarnsOnSpikes() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 60)
        for i in 0..<25 {
            editor.addNote(time: 1 + Double(i) * 0.1, lane: i % 4)
        }
        // Dense burst at the start: hard density failure (25 in 2.4s).
        XCTAssertFalse(editor.validation.hardFailures.isEmpty)
    }

    // MARK: - Edited chart construction

    @MainActor
    func testMakeEditedChartVersionsAndPreservesOriginal() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 30)
        _ = editor.addNote(time: 5, lane: 1)
        let edited = editor.makeEditedChart()
        XCTAssertEqual(edited.chartVersion, 5)            // bumped from 4
        XCTAssertEqual(edited.notes.count, 1)
        XCTAssertEqual(edited.validationWarnings, editor.validation.hardFailures + editor.validation.warnings)
        // The original chart object is untouched.
        XCTAssertTrue(editor.original.notes.isEmpty)
        XCTAssertEqual(editor.original.chartVersion, 4)
    }

    // MARK: - Versioned persistence

    @MainActor
    func testEditedChartSaveLoadRoundTrip() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 30)
        _ = editor.addNote(time: 5, lane: 2)
        let file = EditedChartFile(chart: editor.makeEditedChart(), originalChartVersion: 4)
        try! ChartStorage.saveEdited(file, for: songID)

        XCTAssertTrue(ChartStorage.hasEditedChart(for: songID, difficulty: .medium))
        let loaded = try! ChartStorage.loadEdited(for: songID, difficulty: .medium)
        XCTAssertEqual(loaded?.chart.notes.count, 1)
        XCTAssertEqual(loaded?.chart.chartVersion, 5)
        XCTAssertEqual(loaded?.originalChartVersion, 4)
        XCTAssertEqual(loaded?.editorSchemaVersion, EditedChartFile.currentEditorSchemaVersion)
    }

    @MainActor
    func testEditedChartIsSeparateFromGenerated() {
        // Persist the generated baseline first (the editor never does this).
        let generatedChart = makeChart()
        try! ChartStorage.save(generatedChart, for: songID)

        var editor = ChartEditor(chart: generatedChart, songDuration: 30)
        _ = editor.addNote(time: 5, lane: 2)
        try! ChartStorage.saveEdited(EditedChartFile(chart: editor.makeEditedChart(), originalChartVersion: 4),
                                     for: songID)

        // The generated chart file still holds the ORIGINAL (empty) chart —
        // saving edits never overwrites it.
        let generated = try! ChartStorage.loadChart(for: songID, difficulty: .medium)
        XCTAssertEqual(generated?.notes.count, 0)
        XCTAssertEqual(generated?.chartVersion, 4)

        // Deleting the generated chart leaves the edited file alone.
        ChartStorage.deleteChart(for: songID, difficulty: .medium)
        XCTAssertTrue(ChartStorage.hasEditedChart(for: songID, difficulty: .medium))

        // deleteAllCharts removes everything, including edited variants.
        ChartStorage.deleteAllCharts(for: songID)
        XCTAssertFalse(ChartStorage.hasEditedChart(for: songID, difficulty: .medium))
    }

    @MainActor
    func testNewerEditorSchemaIgnored() {
        var editor = ChartEditor(chart: makeChart(), songDuration: 30)
        _ = editor.addNote(time: 5, lane: 2)
        var file = EditedChartFile(chart: editor.makeEditedChart(), originalChartVersion: 4)
        file.editorSchemaVersion = 99   // future schema
        try! ChartStorage.saveEdited(file, for: songID)
        XCTAssertNil(try! ChartStorage.loadEdited(for: songID, difficulty: .medium))
    }

    // MARK: - Regenerate / discard semantics (storage level)

    @MainActor
    func testDiscardDeletesOnlyEditedVariant() {
        try! ChartStorage.save(makeChart(), for: songID)
        var editor = ChartEditor(chart: makeChart(), songDuration: 30)
        _ = editor.addNote(time: 5, lane: 2)
        try! ChartStorage.saveEdited(EditedChartFile(chart: editor.makeEditedChart(), originalChartVersion: 4),
                                     for: songID)
        ChartStorage.deleteEditedChart(for: songID, difficulty: .medium)
        XCTAssertFalse(ChartStorage.hasEditedChart(for: songID, difficulty: .medium))
        // The generated chart survives a discard.
        XCTAssertNotNil(try! ChartStorage.loadChart(for: songID, difficulty: .medium))
    }
}