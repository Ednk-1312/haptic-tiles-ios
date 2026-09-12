import Foundation
import SwiftData
import XCTest
@testable import Music_Haptics

/// AppState-level analysis cancellation (iOS test target — AppState depends
/// on UIKit/SwiftData, so these run in the Xcode test bundle, not the
/// platform-neutral logic package).
@MainActor
final class AppStateCancellationTests: XCTestCase {

    /// Start the pipeline three times back-to-back on the same song: the two
    /// superseded runs must be cancelled (and their results dropped), and the
    /// final run must settle cleanly — record `.ready`, no error, valid
    /// analysis + chart files on disk. A stale run that wrote files would
    /// clobber the newer run's analysis or delete its charts.
    func testSupersededPipelineRunsSettleCleanly() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CancelTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        AppDirectories.testRootOverride = tempRoot
        defer {
            AppDirectories.testRootOverride = nil
            try? FileManager.default.removeItem(at: tempRoot)
        }

        // A real 25 s WAV in the songs directory (the file source the
        // pipeline resolves).
        let songsDir = AppDirectories.songsDirectory
        try? FileManager.default.createDirectory(at: songsDir, withIntermediateDirectories: true)
        let wavName = "cancel-run-\(UUID().uuidString).wav"
        let samples = SignalFixtures.metronome(bpm: 120, seconds: 25)
        try AudioAnalyzerIntegrationTests.writeWAVPublic(samples, sampleRate: 44100,
                                                         to: songsDir.appendingPathComponent(wavName))

        let container = try ModelContainer(for: SongRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let appState = AppState(container: container,
                                settings: SettingsStore(),
                                mediaLibrary: MediaLibraryService())
        let record = SongRecord(title: "Cancel Test", artist: "Tests",
                                fileName: wavName, duration: 25)
        record.sourceKind = .file
        container.mainContext.insert(record)
        try container.mainContext.save()

        // Fire three generations in quick succession — a cancellation storm.
        appState.runPipeline(for: record)
        appState.runPipeline(for: record)
        appState.runPipeline(for: record)

        // Wait for the final run to settle.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if record.analysisState == .ready || record.analysisState == .failed { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(record.analysisState, .ready,
                       "pipeline never settled: \(record.errorMessage ?? "no error")")
        XCTAssertNil(record.errorMessage, "a cancelled run must never fail the newer run")
        XCTAssertNotNil(record.tempoBPM)
        // Exactly one valid analysis + a valid medium chart must exist on disk
        // (a stale run overwriting/deleting files would break these).
        let savedAnalysis = try? ChartStorage.loadAnalysis(for: record.id)
        XCTAssertNotNil(savedAnalysis, "final analysis missing after supersession")
        let chart = try? ChartStorage.loadChart(for: record.id, difficulty: .medium)
        XCTAssertNotNil(chart, "final chart missing after supersession")
    }

    /// After a completed run, re-running the pipeline must also settle cleanly
    /// (idempotent restart; the completed task must be fully superseded).
    func testPipelineRerunAfterCompletionIsClean() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CancelTest2-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        AppDirectories.testRootOverride = tempRoot
        defer {
            AppDirectories.testRootOverride = nil
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let songsDir = AppDirectories.songsDirectory
        try? FileManager.default.createDirectory(at: songsDir, withIntermediateDirectories: true)
        let wavName = "cancel-rerun-\(UUID().uuidString).wav"
        let samples = SignalFixtures.metronome(bpm: 120, seconds: 10)
        try AudioAnalyzerIntegrationTests.writeWAVPublic(samples, sampleRate: 44100,
                                                         to: songsDir.appendingPathComponent(wavName))

        let container = try ModelContainer(for: SongRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let appState = AppState(container: container,
                                settings: SettingsStore(),
                                mediaLibrary: MediaLibraryService())
        let record = SongRecord(title: "Rerun Test", artist: "Tests",
                                fileName: wavName, duration: 10)
        record.sourceKind = .file
        container.mainContext.insert(record)
        try container.mainContext.save()

        func waitUntilSettled() async throws {
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if record.analysisState == .ready || record.analysisState == .failed { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTFail("pipeline never settled: \(record.errorMessage ?? "no error")")
        }

        appState.runPipeline(for: record)
        try await waitUntilSettled()
        XCTAssertEqual(record.analysisState, .ready)
        XCTAssertNil(record.errorMessage)

        appState.runPipeline(for: record)
        try await waitUntilSettled()
        XCTAssertEqual(record.analysisState, .ready,
                       "rerun failed: \(record.errorMessage ?? "no error")")
        XCTAssertNil(record.errorMessage)
        XCTAssertNotNil(try? ChartStorage.loadAnalysis(for: record.id))
        XCTAssertNotNil(try? ChartStorage.loadChart(for: record.id, difficulty: .medium))
    }
}