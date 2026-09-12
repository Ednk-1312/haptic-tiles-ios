import Foundation

/// JSON persistence for analysis + chart artifacts.
/// Charts are versioned; bump `chartVersion` when generation logic changes.
///
/// Each DIFFICULTY is a separate chart with its own file
/// (`songID.<difficulty>.chart.json`), so one analysis serves every level and
/// regenerating one difficulty never clobbers another. The legacy single-chart
/// path (`songID.chart.json`) is still read as a fallback for records created
/// before multi-difficulty storage.
enum ChartStorage {
    /// v5: onset-first placement (tiles land on audible hits, not grid
    /// estimates) — forces regeneration of all cached charts.
    static let chartVersion = 5

    /// Difficulty levels that get a generated chart (Normal = .medium;
    /// Casual is not a menu level; Extreme is generated but labeled
    /// experimental in the UI).
    static let generatedDifficulties: [DifficultyLevel] = [.easy, .medium, .hard, .expert, .extreme]

    static func save(_ chart: Chart, for songID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(chart).write(to: chartURL(for: songID, difficulty: chart.difficulty), options: .atomic)
    }

    /// Loads the chart for one difficulty. Falls back to the legacy
    /// single-chart file when the per-difficulty file doesn't exist yet.
    static func loadChart(for songID: UUID, difficulty: DifficultyLevel) throws -> Chart? {
        let url = chartURL(for: songID, difficulty: difficulty)
        if FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Chart.self, from: Data(contentsOf: url))
        }
        // Legacy fallback: pre-multi-difficulty records kept one chart at the
        // song-level path. Only honor it when its difficulty matches.
        if let legacy = try legacyChart(for: songID), legacy.difficulty == difficulty {
            return legacy
        }
        return nil
    }

    /// Legacy single-chart file (pre-multi-difficulty layout).
    static func legacyChart(for songID: UUID) throws -> Chart? {
        let url = chartURL(for: songID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Chart.self, from: Data(contentsOf: url))
    }

    /// All cached difficulty charts for a song, keyed by difficulty.
    static func loadCharts(for songID: UUID) throws -> [DifficultyLevel: Chart] {
        var charts: [DifficultyLevel: Chart] = [:]
        for difficulty in generatedDifficulties {
            if let chart = try loadChart(for: songID, difficulty: difficulty) {
                charts[difficulty] = chart
            }
        }
        return charts
    }

    static func deleteChart(for songID: UUID, difficulty: DifficultyLevel) {
        try? FileManager.default.removeItem(at: chartURL(for: songID, difficulty: difficulty))
    }

    /// Removes every chart file for a song: the per-difficulty set plus the
    /// legacy single-chart file.
    static func deleteAllCharts(for songID: UUID) {
        for difficulty in generatedDifficulties {
            deleteChart(for: songID, difficulty: difficulty)
            deleteEditedChart(for: songID, difficulty: difficulty)
        }
        try? FileManager.default.removeItem(at: chartURL(for: songID))
    }

    // MARK: - Edited charts (chart editor)

    /// Saves an EDITED chart as a separate versioned file. The generated
    /// chart is never overwritten: edits and regenerations coexist, and
    /// incompatible regenerations are detected via `originalChartVersion`.
    static func saveEdited(_ file: EditedChartFile, for songID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: editedChartURL(for: songID, difficulty: file.chart.difficulty),
                                       options: .atomic)
    }

    /// Loads the edited chart for a difficulty, if present and schema-valid.
    static func loadEdited(for songID: UUID, difficulty: DifficultyLevel) throws -> EditedChartFile? {
        let url = editedChartURL(for: songID, difficulty: difficulty)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(EditedChartFile.self, from: Data(contentsOf: url)),
              file.editorSchemaVersion <= EditedChartFile.currentEditorSchemaVersion else {
            return nil
        }
        return file
    }

    static func hasEditedChart(for songID: UUID, difficulty: DifficultyLevel) -> Bool {
        FileManager.default.fileExists(atPath: editedChartURL(for: songID, difficulty: difficulty).path)
    }

    static func deleteEditedChart(for songID: UUID, difficulty: DifficultyLevel) {
        try? FileManager.default.removeItem(at: editedChartURL(for: songID, difficulty: difficulty))
    }

    private static func editedChartURL(for songID: UUID, difficulty: DifficultyLevel) -> URL {
        AppDirectories.chartsDirectory
            .appendingPathComponent(songID.uuidString + "." + difficulty.rawValue + ".edited.chart.json")
    }

    /// Edited-chart file URL for a difficulty (used by tests).
    static func editedChartURLForTesting(songID: UUID, difficulty: DifficultyLevel) -> URL? {
        editedChartURL(for: songID, difficulty: difficulty)
    }

    static func saveAnalysis(_ analysis: AudioAnalysis, for songID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(analysis).write(to: analysisURL(for: songID), options: .atomic)
    }

    static func loadAnalysis(for songID: UUID) throws -> AudioAnalysis? {
        let url = analysisURL(for: songID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AudioAnalysis.self, from: Data(contentsOf: url))
    }

    static func deleteAnalysis(for songID: UUID) {
        try? FileManager.default.removeItem(at: analysisURL(for: songID))
    }

    /// Legacy (song-level) chart file — kept for backward-compatible reads.
    private static func chartURL(for songID: UUID) -> URL {
        AppDirectories.chartsDirectory.appendingPathComponent(songID.uuidString + ".chart.json")
    }

    private static func chartURL(for songID: UUID, difficulty: DifficultyLevel) -> URL {
        AppDirectories.chartsDirectory
            .appendingPathComponent(songID.uuidString + "." + difficulty.rawValue + ".chart.json")
    }

    private static func analysisURL(for songID: UUID) -> URL {
        AppDirectories.analysisDirectory.appendingPathComponent(songID.uuidString + ".analysis.json")
    }

    // MARK: - Test hooks (internal so LogicTests can exercise recovery paths)

    /// Chart file URL for a song+difficulty (used by reliability tests to
    /// write corrupt cache files).
    static func chartURLForTesting(songID: UUID, difficulty: DifficultyLevel) -> URL? {
        chartURL(for: songID, difficulty: difficulty)
    }

    /// Analysis file URL for a song (used by reliability tests).
    static func analysisURLForTesting(songID: UUID) -> URL {
        analysisURL(for: songID)
    }
}