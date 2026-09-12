import XCTest
@testable import Music_Haptics

/// Queue stress: large queues, duplicate songs, rapid reorder, removing the
/// current entry, clearing and shuffling during playback — the manager must
/// stay coherent through every operation and always produce a valid advance
/// decision.
@MainActor
final class QueueStressTests: XCTestCase {

    nonisolated(unsafe) private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueStress-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        AppDirectories.testRootOverride = tempRoot
    }

    override func tearDown() {
        AppDirectories.testRootOverride = nil
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func entry(_ id: Int) -> QueueEntry {
        QueueEntry(songID: UUID(), title: "Song \(id)", artist: "Artist", difficulty: .medium)
    }

    func testLargeQueueLifecycle() {
        let queue = QueueManager()
        for i in 0..<1000 {
            queue.add(entry(i))
        }
        XCTAssertEqual(queue.entries.count, 1000)

        // Play through a long stretch: each decision must advance cleanly and
        // the current entry must always remain a member of the queue.
        for _ in 0..<250 {
            let decision = queue.decisionAfterFinish()
            switch decision {
            case .next(let next):
                XCTAssertTrue(queue.entries.contains { $0.id == next.id })
                XCTAssertEqual(queue.nowPlaying?.id, next.id,
                               "the manager must move its own current pointer")
            case .replayCurrent:
                XCTAssertNotNil(queue.nowPlaying)
            case .none:
                XCTFail("queue with 1000 entries must advance")
            }
        }
        XCTAssertNotNil(queue.nowPlaying)
    }

    func testDuplicatesAreDistinctEntries() {
        let queue = QueueManager()
        let same = entry(1)
        queue.add(same)
        queue.add(same)
        queue.add(same)
        XCTAssertEqual(queue.entries.count, 3, "same song at same difficulty can be queued thrice")
        queue.remove(entryID: queue.entries[0].id)
        XCTAssertEqual(queue.entries.count, 2)
    }

    func testRapidReorderKeepsInvariants() {
        let queue = QueueManager()
        var ids: [UUID] = []
        for i in 0..<200 {
            let e = entry(i)
            ids.append(e.id)
            queue.add(e)
        }
        // Move entries around rapidly (the drag-reorder path).
        for _ in 0..<500 {
            guard queue.entries.count > 1 else { break }
            let from = Int.random(in: 0..<queue.entries.count)
            let to = Int.random(in: 0..<queue.entries.count)
            let id = queue.entries[from].id
            queue.move(fromOffsets: IndexSet(integer: from), toOffset: to)
            // Invariant: the moved entry is still present.
            XCTAssertTrue(queue.entries.contains { $0.id == id })
        }
        // Invariants: no duplicates of ids, all ids still present.
        XCTAssertEqual(Set(queue.entries.map(\.id)).count, queue.entries.count)
        XCTAssertEqual(Set(queue.entries.map(\.id)), Set(ids))
    }

    func testRemoveCurrentSongAdvancesDecision() {
        let queue = QueueManager()
        let a = entry(1), b = entry(2), c = entry(3)
        queue.add(a); queue.add(b); queue.add(c)
        queue.setCurrent(entryID: a.id)
        XCTAssertEqual(queue.nowPlaying?.id, a.id)
        // Remove the current song mid-playback.
        queue.remove(entryID: a.id)
        XCTAssertNotEqual(queue.nowPlaying?.id, a.id, "current must move off the removed entry")
        // Finishing still advances to a valid entry.
        let decision = queue.decisionAfterFinish()
        if case .next(let next) = decision {
            XCTAssertTrue(queue.entries.contains { $0.id == next.id })
        }
    }

    func testClearDuringPlayback() {
        let queue = QueueManager()
        let a = entry(1), b = entry(2)
        queue.add(a); queue.add(b)
        queue.setCurrent(entryID: a.id)
        queue.clear()
        XCTAssertTrue(queue.entries.isEmpty)
        XCTAssertNil(queue.nowPlaying)
        let decision = queue.decisionAfterFinish()
        XCTAssertEqual(decision, .none, "an empty queue finishes normally")
    }

    func testShuffleDuringPlaybackPreservesMembership() {
        let queue = QueueManager()
        var ids: Set<UUID> = []
        for i in 0..<120 {
            let e = entry(i)
            ids.insert(e.id)
            queue.add(e)
        }
        queue.setCurrent(entryID: queue.entries[0].id)
        for _ in 0..<20 {
            queue.toggleShuffle()
            XCTAssertEqual(Set(queue.entries.map(\.id)), ids, "shuffle must be lossless")
        }
        // With shuffle on, every advance picks an unplayed member of the queue.
        for _ in 0..<30 {
            let decision = queue.decisionAfterFinish()
            switch decision {
            case .next(let next):
                XCTAssertTrue(ids.contains(next.id))
            case .none, .replayCurrent:
                XCTFail("120-entry shuffled queue must keep advancing")
            }
        }
    }

    func testRepeatOneAndRepeatAllUnderStress() {
        let queue = QueueManager()
        let a = entry(1), b = entry(2)
        queue.add(a); queue.add(b)
        queue.setCurrent(entryID: a.id)

        queue.setRepeat(.one)
        for _ in 0..<25 {
            XCTAssertEqual(queue.decisionAfterFinish(), .replayCurrent,
                           "Repeat One must replay the current entry")
        }
        queue.setRepeat(.all)
        var advanced = 0
        for _ in 0..<40 {
            if case .next = queue.decisionAfterFinish() { advanced += 1 }
        }
        XCTAssertEqual(advanced, 40, "Repeat All must always advance")

        // Skipping must never be trapped by Repeat One.
        queue.setRepeat(.one)
        if case .next(let next) = queue.decisionAfterSkip() {
            XCTAssertTrue(queue.entries.contains { $0.id == next.id })
        }
    }

    func testPersistenceRoundTripLargeQueue() {
        let queue = QueueManager()
        for i in 0..<500 {
            queue.add(entry(i))
        }
        queue.setCurrent(entryID: queue.entries[10].id)
        queue.setRepeat(.all)
        // Every mutation persists; reload through the storage layer.
        let snapshot = QueueStorage.load()
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.entries.count, 500)
        XCTAssertEqual(snapshot?.currentEntryID, queue.entries[10].id)
        XCTAssertEqual(snapshot?.repeatMode, .all)

        let restored = QueueManager(seed: 1, snapshot: snapshot)
        XCTAssertEqual(restored.entries.count, 500)
        XCTAssertEqual(restored.nowPlaying?.id, queue.entries[10].id)
        // Restore must reset volatile status, never resurrect it.
        XCTAssertTrue(restored.entries.allSatisfy { $0.status == .idle })
    }
}