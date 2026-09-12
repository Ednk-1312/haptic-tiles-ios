import XCTest
@testable import Music_Haptics

/// Deterministic tests for the replay system: builder normalization, versioned
/// storage, corruption handling, and chart matching.
final class ReplayTests: XCTestCase {

    private let songID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherSongID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ReplayStorage.customDirectory = tempDir
    }

    override func tearDown() {
        ReplayStorage.customDirectory = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func event(_ kind: ReplayEventKind, id: Int, time: Double, judgment: Judgment? = .perfect,
                       lane: Int = 0, delta: Double = 0, score: Int = 100, combo: Int = 1) -> ReplayEvent {
        ReplayEvent(kind: kind, noteID: id, lane: lane, time: time,
                    judgment: judgment, timingErrorMs: delta, score: score, combo: combo)
    }

    private func makeReplay(id: UUID = UUID(), events: [ReplayEvent]) -> ReplayFile {
        ReplayBuilder.make(songID: songID, songTitle: "Test Song", difficulty: .hard,
                           chartVersion: 3, audioURL: nil, duration: 120, noteCount: 50,
                           events: events, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                           id: id)
    }

    // MARK: - Builder normalization

    func testBuilderSortsDeterministically() {
        let events = [event(.note, id: 2, time: 2.0), event(.note, id: 1, time: 1.0),
                      event(.note, id: 3, time: 3.0)]
        let replay = makeReplay(events: events)
        XCTAssertEqual(replay.events.map(\.noteID), [1, 2, 3])
    }

    func testBuilderDropsExactDuplicates() {
        let events = [event(.note, id: 1, time: 1.0), event(.note, id: 1, time: 1.0)]
        let replay = makeReplay(events: events)
        XCTAssertEqual(replay.events.count, 1)
    }

    func testBuilderKeepsDistinctKindsAtSameTime() {
        // A holdStart at 1.0 and a holdComplete at 1.0 are distinct events.
        let events = [event(.holdComplete, id: 7, time: 1.0, judgment: nil),
                      event(.holdStart, id: 7, time: 1.0)]
        let replay = makeReplay(events: events)
        XCTAssertEqual(replay.events.count, 2)
        XCTAssertEqual(replay.events.map(\.kind), [.holdStart, .holdComplete])
    }

    func testBuilderWritesCurrentVersion() {
        XCTAssertEqual(makeReplay(events: []).version, ReplayFile.currentVersion)
        XCTAssertTrue(makeReplay(events: []).isCurrentVersion)
    }

    // MARK: - Chart matching

    private func chart(version: Int, difficulty: DifficultyLevel = .hard) -> Chart {
        Chart(songID: songID, difficulty: difficulty, chartVersion: version, seed: 42,
              notes: [], generatedAt: Date(), nps: 0, duration: 120, difficultyScore: 4.2,
              validationWarnings: [], generationDuration: 0)
    }

    func testMatchesExactChart() {
        let replay = makeReplay(events: [])
        XCTAssertTrue(ReplayBuilder.matches(replay, chart: chart(version: 3)))
    }

    func testRejectsWrongSongDifficultyOrChartVersion() {
        let replay = makeReplay(events: [])
        XCTAssertFalse(ReplayBuilder.matches(replay, chart: chart(version: 4)))
        XCTAssertFalse(ReplayBuilder.matches(replay, chart: chart(version: 3, difficulty: .easy)))

        var wrongSong = replay
        wrongSong.songID = otherSongID
        XCTAssertFalse(ReplayBuilder.matches(wrongSong, chart: chart(version: 3)))
    }

    // MARK: - Storage round trip

    func testSaveLoadRoundTrip() {
        let events = [event(.note, id: 1, time: 0.5, judgment: .great, delta: -23, score: 400, combo: 2),
                      event(.holdStart, id: 2, time: 1.0, judgment: .perfect, lane: 2)]
        let replay = makeReplay(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, events: events)
        XCTAssertTrue(ReplayStorage.save(replay))
        let loaded = ReplayStorage.load(id: replay.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, replay)
    }

    func testLoadMissingFileReturnsNil() {
        XCTAssertNil(ReplayStorage.load(id: UUID()))
    }

    func testCorruptFileReturnsNilAndIsRemoved() {
        let id = UUID()
        let url = tempDir.appendingPathComponent("\(id.uuidString).replay.json")
        try! Data("{not json".utf8).write(to: url)
        XCTAssertNil(ReplayStorage.load(id: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "unreadable replay should be purged")
    }

    func testFutureVersionIsRefusedAndKept() {
        let id = UUID()
        let url = tempDir.appendingPathComponent("\(id.uuidString).replay.json")
        var replay = makeReplay(id: id, events: [])
        replay.version = ReplayFile.currentVersion + 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(replay)
        try! data.write(to: url)
        XCTAssertNil(ReplayStorage.load(id: id))
        // A future app version might understand it — leave it on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSavedReplaysFiltersBySong() {
        let a = makeReplay(id: UUID(), events: [])
        var b = makeReplay(id: UUID(), events: [])
        b.songID = otherSongID
        ReplayStorage.save(a)
        ReplayStorage.save(b)
        let forSong = ReplayStorage.savedReplays(songID: songID)
        XCTAssertEqual(forSong.map(\.id), [a.id])
        XCTAssertEqual(forSong.count, 1)
    }

    func testSavedReplaysNewestFirst() {
        let old = makeReplay(id: UUID(), events: [])
        var new = makeReplay(id: UUID(), events: [])
        new.createdAt = old.createdAt.addingTimeInterval(100)
        ReplayStorage.save(old)
        ReplayStorage.save(new)
        XCTAssertEqual(ReplayStorage.savedReplays(songID: songID).map(\.id), [new.id, old.id])
    }

    func testDeleteRemovesFile() {
        let replay = makeReplay(id: UUID(), events: [])
        ReplayStorage.save(replay)
        XCTAssertNotNil(ReplayStorage.load(id: replay.id))
        XCTAssertTrue(ReplayStorage.delete(id: replay.id))
        XCTAssertNil(ReplayStorage.load(id: replay.id))
    }

    func testPurgeInvalidRemovesOnlyCorrupt() {
        let good = makeReplay(id: UUID(), events: [])
        ReplayStorage.save(good)
        let badID = UUID()
        try! Data("garbage".utf8).write(to: tempDir.appendingPathComponent("\(badID.uuidString).replay.json"))
        let removed = ReplayStorage.purgeInvalid()
        XCTAssertEqual(removed, 1)
        XCTAssertNotNil(ReplayStorage.load(id: good.id))
    }

    // MARK: - Compactness

    func testCompactnessTypicalRun() {
        // A dense 300-note run with holds: events must stay small in memory
        // and the encoded file must be far smaller than raw input recording.
        var events: [ReplayEvent] = []
        for i in 0..<300 {
            events.append(event(.note, id: i, time: Double(i) * 0.1, judgment: .great, delta: -12, score: i * 400, combo: i + 1))
        }
        let replay = makeReplay(events: events)
        let data = try! JSONEncoder().encode(replay)
        XCTAssertLessThan(Double(data.count) / 1024.0, 60, "a 300-note replay must stay under 60 KB")
    }

    func testScrubReconsumeIsDeterministic() {
        // Simulating a seek: consuming events from position 0 up to any time
        // must always produce the same score/combo (the view re-consumes from
        // the start on every seek).
        let events = (0..<50).map { event(.note, id: $0, time: Double($0) * 1.0, score: $0 * 100, combo: $0 + 1) }
        let replay = makeReplay(events: events)
        func state(at t: Double) -> (score: Int, combo: Int) {
            var score = 0, combo = 0
            for e in replay.events where e.time <= t {
                score = e.score
                combo = e.combo
            }
            return (score, combo)
        }
        let a = state(at: 25.5)
        let b = state(at: 25.5)
        XCTAssertEqual(a.score, b.score)
        XCTAssertEqual(a.combo, b.combo)
        XCTAssertEqual(a.score, 2500)
        XCTAssertEqual(a.combo, 26)
    }
}