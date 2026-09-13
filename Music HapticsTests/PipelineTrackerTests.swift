import XCTest
@testable import Music_Haptics

/// The app guards every pipeline stage (analysis, chart generation, queue
/// pre-generation, gameplay session building) with per-song generation
/// tokens. These tests exercise the REAL `PipelineTracker` (the type AppState
/// uses), proving a task started for Song A can never modify Song B — even
/// when both songs carry the same generation number.
final class PipelineTrackerTests: XCTestCase {

    /// Minimal model of AppState's guarded mutation path: mutations are keyed
    /// by song id and validated against that song's OWN counter.
    private actor GuardedStore {
        struct Record: Equatable {
            var analysisLabel = ""
            var chartLabel = ""
        }

        var tracker = PipelineTracker()
        var records: [UUID: Record] = [:]

        func begin(_ id: UUID) -> PipelineToken { tracker.begin(for: id) }

        /// Returns true when the mutation landed (stale work is dropped).
        /// The target record is ALWAYS `token.songID` — exactly like AppState
        /// (which fetches the record for the token's own song and validates
        /// the token against that same id). There is no API to write another
        /// song with someone else's token.
        func applyAnalysis(_ token: PipelineToken, label: String) -> Bool {
            guard tracker.isCurrent(token, for: token.songID) else { return false }
            records[token.songID, default: Record()].analysisLabel = label
            return true
        }

        func applyChart(_ token: PipelineToken, label: String) -> Bool {
            guard tracker.isCurrent(token, for: token.songID) else { return false }
            records[token.songID, default: Record()].chartLabel = label
            return true
        }

        func record(_ id: UUID) -> Record? { records[id] }

        /// Direct tracker-level check: can A's token pass validation against
        /// B's song id?
        func canValidate(_ token: PipelineToken, against id: UUID) -> Bool {
            tracker.isCurrent(token, for: id)
        }
    }

    func testSongATaskCannotModifySongB() async {
        let store = GuardedStore()
        let songA = UUID(), songB = UUID()

        // Song A starts work (slow), then the user switches to Song B. Both
        // are each song's FIRST run, so their generation numbers collide (1).
        let tokenA = await store.begin(songA)
        let tokenB = await store.begin(songB)
        XCTAssertEqual(tokenA.generation, tokenB.generation, "colliding generation numbers make this test meaningful")

        // The token is self-describing: the tracker refuses to validate A's
        // token against B's id, even though the generation numbers collide.
        let aTokenAgainstB = await store.canValidate(tokenA, against: songB)
        XCTAssertFalse(aTokenAgainstB, "A's token must never pass validation for song B")
        let bTokenAgainstA = await store.canValidate(tokenB, against: songA)
        XCTAssertFalse(bTokenAgainstA)
        let aTokenAgainstA = await store.canValidate(tokenA, against: songA)
        XCTAssertTrue(aTokenAgainstA)

        // A's slow analysis completes after the switch: it may still finish
        // A's own record (writes go to token.songID — never to B)…
        let aOnA = await store.applyAnalysis(tokenA, label: "A-analysis")
        XCTAssertTrue(aOnA)
        // …and B's own work lands on B.
        let bOnB = await store.applyAnalysis(tokenB, label: "B-analysis")
        XCTAssertTrue(bOnB)
        // A's chart completion cannot touch B either.
        _ = await store.applyChart(tokenA, label: "A-chart")

        let recordA = await store.record(songA)
        let recordB = await store.record(songB)
        XCTAssertEqual(recordA?.analysisLabel, "A-analysis")
        XCTAssertEqual(recordB?.analysisLabel, "B-analysis")
        XCTAssertEqual(recordB?.chartLabel, "", "B must be untouched by A's chart work")
    }

    func testReanalysisInvalidatesOlderRunOfSameSong() async {
        let store = GuardedStore()
        let song = UUID()

        let token1 = await store.begin(song)
        let token2 = await store.begin(song)   // user re-analyzes the same song

        let oldLanded = await store.applyAnalysis(token1, label: "old")
        XCTAssertFalse(oldLanded)
        let newLanded = await store.applyAnalysis(token2, label: "new")
        XCTAssertTrue(newLanded)
        let record = await store.record(song)
        XCTAssertEqual(record?.analysisLabel, "new", "stale run must never overwrite the newer result")
    }

    func testSwitchToSongBKeepsAStaleForItsOwnFutureRuns() async {
        let store = GuardedStore()
        let song = UUID()

        let token1 = await store.begin(song)
        _ = await store.begin(song)   // switch away and back = new run
        // The FIRST run's chart must be rejected even though the song id
        // matches — the run predates the newest generation.
        let staleLanded = await store.applyChart(token1, label: "stale-chart")
        XCTAssertFalse(staleLanded)
    }

    func testRapidSwitchStormOnlyLatestLandsPerSong() async {
        let store = GuardedStore()
        let songA = UUID(), songB = UUID()
        var tokensA: [PipelineToken] = []
        var tokensB: [PipelineToken] = []

        for i in 0..<25 {
            tokensA.append(await store.begin(songA))
            if i % 3 == 0 { tokensB.append(await store.begin(songB)) }
        }

        for (i, token) in tokensA.enumerated() {
            let landed = await store.applyChart(token, label: "A-\(i)")
            XCTAssertEqual(landed, i == tokensA.count - 1, "only A's latest generation may land")
        }
        for (i, token) in tokensB.enumerated() {
            let landed = await store.applyChart(token, label: "B-\(i)")
            XCTAssertEqual(landed, i == tokensB.count - 1, "only B's latest generation may land")
        }

        let a = await store.record(songA)
        let b = await store.record(songB)
        XCTAssertEqual(a?.chartLabel, "A-24")
        XCTAssertEqual(b?.chartLabel, "B-\(tokensB.count - 1)")
    }

    func testSlowACompletesAfterFastBInRealTasks() async {
        let store = GuardedStore()
        let songA = UUID(), songB = UUID()

        // Song A begins a slow pipeline; user switches to B (fast).
        let tokenA = await store.begin(songA)
        let tokenB = await store.begin(songB)

        func slowWork(label: String, delayNanos: UInt64) async -> String {
            try? await Task.sleep(nanoseconds: delayNanos)
            return label
        }

        async let aResult = slowWork(label: "A-slow", delayNanos: 30_000_000)
        async let bResult = slowWork(label: "B-fast", delayNanos: 1_000_000)
        let (aLabel, bLabel) = await (aResult, bResult)

        // B's fast work lands…
        let bLanded = await store.applyAnalysis(tokenB, label: bLabel)
        XCTAssertTrue(bLanded)
        // …and A's slow work arriving last writes only to A (token-bound),
        // never to B.
        let aLanded = await store.applyAnalysis(tokenA, label: aLabel)
        XCTAssertTrue(aLanded, "A's own record may still finish")   // writes to songA only
        let aAgainstB = await store.canValidate(tokenA, against: songB)
        XCTAssertFalse(aAgainstB)

        let b = await store.record(songB)
        XCTAssertEqual(b?.analysisLabel, "B-fast", "stale A work must not overwrite B")
        XCTAssertFalse(b?.analysisLabel.hasPrefix("A") ?? false)
        let a = await store.record(songA)
        XCTAssertEqual(a?.analysisLabel, "A-slow", "A's work lands on A's own record")
    }

    // MARK: - Observation tokens (generation 0)

    /// Regression for the "brief loading, then back home" bug: ensure-chart
    /// builds a READ-ONLY observation token via `current(for:)`, which reports
    /// 0 when no pipeline has run for the song this session. A generation-0
    /// token must validate while no run has begun — otherwise every
    /// regeneration requested before the first pipeline of the launch fails
    /// its currency check forever, exhausts its retries, and dies as a raw
    /// CancellationError.
    func testObservationTokenValidatesBeforeAnyRun() {
        let tracker = PipelineTracker()
        let song = UUID()

        // No run has begun: the observation token is current.
        let observation = PipelineToken(songID: song, generation: tracker.current(for: song))
        XCTAssertEqual(observation.generation, 0, "current(for:) reports 0 for an unseen song")
        XCTAssertTrue(tracker.isCurrent(observation, for: song),
                      "a generation-0 observation token must validate while no run has begun")
    }

    /// A generation-0 observation token must STOP being current the moment a
    /// real run begins (counter 0 → 1) — the observation's purpose is to
    /// detect exactly that supersession.
    func testObservationTokenInvalidatedByNewRun() {
        var tracker = PipelineTracker()
        let song = UUID()
        let observation = PipelineToken(songID: song, generation: tracker.current(for: song))

        _ = tracker.begin(for: song)
        XCTAssertFalse(tracker.isCurrent(observation, for: song),
                       "a real run supersedes a pre-run observation")
    }

    /// A run token (generation ≥ 1) must NEVER validate as generation 0 —
    /// and cross-song validation stays forbidden for observation tokens too.
    func testObservationTokenCrossSongAndRunTokens() {
        var tracker = PipelineTracker()
        let songA = UUID(), songB = UUID()
        let observationB = PipelineToken(songID: songB, generation: tracker.current(for: songB))

        XCTAssertFalse(tracker.isCurrent(observationB, for: songA),
                       "observation tokens stay song-bound")

        let runA = tracker.begin(for: songA)
        XCTAssertTrue(tracker.isCurrent(runA, for: songA))
        XCTAssertFalse(tracker.isCurrent(runA, for: songB))
        // Generation 0 never equals a real run's generation.
        XCTAssertFalse(tracker.isCurrent(PipelineToken(songID: songA, generation: 0), for: songA),
                       "run began — generation-0 token for the same song is stale")
    }
}