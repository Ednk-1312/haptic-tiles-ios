import Foundation
import XCTest
@testable import Music_Haptics

/// Cancellation of analysis/chart work: a cancelled task must stop promptly
/// (cooperative checks in the decode loop and between generation tiers)
/// instead of running to completion with a result that can never land.
/// AppState-level supersession (stale runs cannot overwrite newer files) is
/// covered in AppStateCancellationTests (iOS test target).
final class AnalysisCancellationTests: XCTestCase {

    /// A cancelled analysis must throw CancellationError promptly instead of
    /// decoding the whole file and returning a (stale) result.
    func testAnalyzerStopsPromptlyWhenCancelled() async throws {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cancel-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = SignalFixtures.metronome(bpm: 120, seconds: 60)
        try AudioAnalyzerIntegrationTests.writeWAVPublic(samples, sampleRate: 44100, to: url)

        let started = Date()
        let task = Task { try await AudioAnalyzer().analyze(url: url) }
        try await Task.sleep(nanoseconds: 150_000_000)   // let decoding start
        task.cancel()
        // Use `result`, NOT `value`: `value` throws CancellationError even
        // when the closure ran to completion on a cancelled task, which
        // would mask a regression. `result` reports what the analysis
        // actually did.
        let outcome = await task.result
        switch outcome {
        case .failure(let error as CancellationError):
            break   // expected — the pipeline must unwind cooperatively
        case .failure(let error):
            XCTFail("expected CancellationError, got \(error)")
        case .success:
            XCTFail("a cancelled analysis must not complete with a result")
        }
        // Prompt-unwind budget. NOTE: on iOS simulators, AVURLAsset's
        // loadTracks/load(formatDescriptions) can block uninterruptibly for
        // ~15 s on freshly-written files (Apple runtime behavior; bundle
        // assets load instantly). The app cannot pre-empt that platform
        // call, so the strict budget is enforced where the load is fast
        // (devices and macOS). The cooperative checks themselves are
        // exercised by the macOS LogicTests run of this same file.
        #if targetEnvironment(simulator)
        if case .failure = outcome {
            // Still verify the unwinding finished the call at all (no hang).
            XCTAssertLessThan(Date().timeIntervalSince(started), 30,
                              "cancelled analysis never unwound")
        }
        #else
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "cancellation did not stop the decode promptly")
        #endif
    }

    /// A cancelled chart generation must unwind between tiers instead of
    /// returning a chart built from a stale analysis.
    func testChartGenerationStopsWhenCancelled() async throws {
        // 10-minute dense fixture: generation takes ~2–3 s in Debug, so the
        // 50 ms cancel lands mid-work.
        let analysis = SignalFixtures.drumHeavy(bpm: 200, seconds: 600)
        let request = ChartGenerator.Request(difficulty: .expert, densityMultiplier: 1.0, seed: 42)
        let started = Date()
        let task = Task {
            try await ChartGenerator().generate(analysis: analysis,
                                                songID: UUID(), request: request)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled generation must not return a chart")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "cancellation did not stop generation promptly")
    }
}