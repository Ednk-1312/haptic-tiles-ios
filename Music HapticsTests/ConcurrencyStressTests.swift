import XCTest
@testable import Music_Haptics

/// Simulates a slow analysis task that completes out of order. A free
/// function (not a method) so @Sendable task closures never capture `self`.
private func analysisTask(label: String, delayNanos: UInt64) async -> String {
    try? await Task.sleep(nanoseconds: delayNanos)
    return label
}

/// The app guards every pipeline stage (analysis, chart generation, playback)
/// with a per-song generation counter so a stale task can never overwrite
/// newer state. These tests exercise that exact pattern with real Swift
/// concurrency: racing analysis/chart tasks complete out of order and the
/// actor must only accept work from the LATEST generation.
final class ConcurrencyStressTests: XCTestCase {

    /// Minimal model of the app's guarded pipeline state.
    private actor PipelineState {
        struct Snapshot: Equatable {
            var analysisLabel: String = ""
            var chartLabel: String = ""
            var startedSession = false
        }

        private var generation = 0
        private var snapshot = Snapshot()

        func begin() -> Int {
            generation += 1
            return generation
        }

        func isCurrent(_ gen: Int) -> Bool {
            gen == generation
        }

        /// Applies work only when it belongs to the current generation.
        /// Returns whether the work landed (stale work is dropped).
        func applyAnalysis(_ gen: Int, _ label: String) -> Bool {
            guard isCurrent(gen) else { return false }
            snapshot.analysisLabel = label
            return true
        }

        func applyChart(_ gen: Int, _ label: String) -> Bool {
            guard isCurrent(gen) else { return false }
            snapshot.chartLabel = label
            return true
        }

        func startSession(_ gen: Int) -> Bool {
            guard isCurrent(gen) else { return false }
            snapshot.startedSession = true
            return true
        }

        func currentSnapshot() -> Snapshot { snapshot }
    }

    func testStaleTasksCannotOverwriteNewerState() async {
        let state = PipelineState()

        // Song A begins a pipeline (gen 1) — slow analysis.
        let genA = await state.begin()
        // User switches to song B — but the guard is per-song in the app;
        // here the same actor models rapid switches, so B bumps again.
        let genB = await state.begin()
        // Song C switches immediately (gen 3).
        let genC = await state.begin()

        async let slowAnalysis = analysisTask(label: "A-slow", delayNanos: 30_000_000)
        async let fastAnalysis = analysisTask(label: "C-fast", delayNanos: 1_000_000)
        let slowResult = await slowAnalysis
        let fastResult = await fastAnalysis

        // C's fast work lands…
        let cLanded = await state.applyAnalysis(genC, fastResult)
        XCTAssertTrue(cLanded)
        // …and A's slow work — arriving LAST — must be rejected.
        let aLanded = await state.applyAnalysis(genA, slowResult)
        XCTAssertFalse(aLanded, "stale generation-1 analysis must be dropped")
        let aChartLanded = await state.applyChart(genA, "A-chart")
        XCTAssertFalse(aChartLanded)
        // B never completed: its generation is already stale too.
        let bLanded = await state.applyChart(genB, "B-chart")
        XCTAssertFalse(bLanded)

        let snapshot = await state.currentSnapshot()
        XCTAssertEqual(snapshot.analysisLabel, "C-fast")
        XCTAssertEqual(snapshot.chartLabel, "")
    }

    func testOldSessionCannotStartAfterSwitch() async {
        let state = PipelineState()
        let genA = await state.begin()
        _ = await state.begin()   // switch to B

        let started = await state.startSession(genA)
        XCTAssertFalse(started, "a session started from a stale generation must be refused")
        let snapshot = await state.currentSnapshot()
        XCTAssertFalse(snapshot.startedSession)
    }

    func testRapidSwitchStormKeepsFinalGeneration() async {
        let state = PipelineState()
        var generations: [Int] = []
        // Rapid-fire switches: 50 generations.
        for _ in 0..<50 {
            generations.append(await state.begin())
        }
        // Old generations all rejected; only the last can land.
        for (i, gen) in generations.enumerated() {
            let landed = await state.applyChart(gen, "chart-\(i)")
            XCTAssertEqual(landed, i == generations.count - 1,
                           "only the final generation may land")
        }
        let snapshot = await state.currentSnapshot()
        XCTAssertEqual(snapshot.chartLabel, "chart-49")
    }

    func testManyConcurrentCompletionsOnlyLatestWins() async {
        let state = PipelineState()
        let gen = await state.begin()
        // 40 racing completions of the same generation: exactly one value
        // survives (the last applied), never a torn/duplicated state.
        var tasks: [Task<Bool, Never>] = []
        for i in 0..<40 {
            tasks.append(Task {
                let label = await analysisTask(label: "v\(i)", delayNanos: UInt64(1_000_000 + i))
                return await state.applyAnalysis(gen, label)
            })
        }
        var landed: [Bool] = []
        for task in tasks {
            landed.append(await task.value)
        }
        XCTAssertTrue(landed.allSatisfy { $0 })
        let snapshot = await state.currentSnapshot()
        XCTAssertTrue(snapshot.analysisLabel.hasPrefix("v"))
    }
}