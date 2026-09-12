import XCTest
@testable import Music_Haptics

/// Deterministic in-app queue tests. QueueManager is a pure state machine
/// (seeded RNG, JSON persistence), so every behavior is reproducible.
final class QueueTests: XCTestCase {
    private var songIDs: [UUID] = []

    override func setUpWithError() throws {
        songIDs = (0..<6).map { _ in UUID() }
        QueueStorage.delete()
    }

    override func tearDownWithError() throws {
        QueueStorage.delete()
    }

    private func entry(_ i: Int, difficulty: DifficultyLevel = .medium) -> QueueEntry {
        QueueEntry(songID: songIDs[i], title: "Song \(i)", artist: "Artist",
                   difficulty: difficulty)
    }

    // MARK: - Add / remove / reorder

    @MainActor
    func testAddAppendAndRemove() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        queue.add(entry(1))
        queue.add(entry(2))
        XCTAssertEqual(queue.entries.map(\.songID), [songIDs[0], songIDs[1], songIDs[2]])
        XCTAssertNil(queue.nowPlaying)
        XCTAssertEqual(queue.upNext?.songID, songIDs[0])

        let removed = queue.remove(entryID: queue.entries[1].id)
        XCTAssertEqual(removed?.songID, songIDs[1])
        XCTAssertEqual(queue.entries.map(\.songID), [songIDs[0], songIDs[2]])
        // Removing a missing id is a safe no-op.
        XCTAssertNil(queue.remove(entryID: UUID()))
    }

    @MainActor
    func testPlayNextInsertsAfterCurrent() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        queue.add(entry(2))
        queue.setCurrent(entryID: queue.entries[0].id)
        queue.playNext(entry(1))
        XCTAssertEqual(queue.entries.map(\.songID), [songIDs[0], songIDs[1], songIDs[2]])
        XCTAssertEqual(queue.upNext?.songID, songIDs[1])
    }

    @MainActor
    func testPlayNextWithNothingPlayingInsertsAtFront() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(1))
        queue.add(entry(2))
        queue.playNext(entry(0))
        XCTAssertEqual(queue.entries.map(\.songID), [songIDs[0], songIDs[1], songIDs[2]])
    }

    @MainActor
    func testReorderViaMove() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        queue.add(entry(1))
        queue.add(entry(2))
        queue.add(entry(3))
        queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        XCTAssertEqual(queue.entries.map(\.songID), [songIDs[1], songIDs[2], songIDs[3], songIDs[0]])
        queue.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(queue.entries.map(\.songID), [songIDs[0], songIDs[1], songIDs[2], songIDs[3]])
    }

    @MainActor
    func testClearEmptiesEverything() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        queue.add(entry(1))
        queue.setCurrent(entryID: queue.entries[0].id)
        queue.clear()
        XCTAssertTrue(queue.entries.isEmpty)
        XCTAssertNil(queue.nowPlaying)
        XCTAssertEqual(queue.decisionAfterFinish(), .none)
        XCTAssertEqual(queue.decisionAfterSkip(), .none)
    }

    @MainActor
    func testDuplicatesAreAllowedAndRemovedIndividually() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        queue.add(entry(0))   // same song twice
        queue.add(entry(1))
        XCTAssertEqual(queue.entries.count, 3)
        XCTAssertEqual(queue.remove(entryID: queue.entries[0].id)?.songID, songIDs[0])
        XCTAssertEqual(queue.entries.map(\.songID), [songIDs[0], songIDs[1]])
        // removeAll removes every entry for a deleted song.
        queue.removeAll(songID: songIDs[0])
        XCTAssertEqual(queue.entries.map(\.songID), [songIDs[1]])
        queue.clear()
        XCTAssertTrue(queue.entries.isEmpty)
    }

    // MARK: - Transition decisions

    @MainActor
    func testFinishAdvancesThroughQueueAndStops() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        queue.add(entry(1))
        queue.add(entry(2))
        queue.setCurrent(entryID: queue.entries[0].id)

        XCTAssertEqual(queue.decisionAfterFinish(), .next(entry(1)))
        queue.setCurrent(entryID: queue.entries[1].id)
        XCTAssertEqual(queue.decisionAfterFinish(), .next(entry(2)))
        queue.setCurrent(entryID: queue.entries[2].id)
        XCTAssertEqual(queue.decisionAfterFinish(), .none)
    }

    @MainActor
    func testFinishWithNothingPlayingStartsAtFront() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        queue.add(entry(1))
        XCTAssertEqual(queue.decisionAfterFinish(), .next(entry(0)))
    }

    @MainActor
    func testRepeatOneReplaysCurrent() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        queue.add(entry(1))
        queue.setCurrent(entryID: queue.entries[0].id)
        queue.setRepeat(.one)
        XCTAssertEqual(queue.decisionAfterFinish(), .replayCurrent)
        // Skip must NOT trap on Repeat One.
        XCTAssertEqual(queue.decisionAfterSkip(), .next(entry(1)))
    }

    @MainActor
    func testRepeatAllWrapsAtEnd() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        queue.add(entry(1))
        queue.setCurrent(entryID: queue.entries[1].id)
        queue.setRepeat(.all)
        XCTAssertEqual(queue.decisionAfterFinish(), .next(entry(0)))
    }

    @MainActor
    func testEmptyQueueDecisions() {
        let queue = QueueManager(seed: 1)
        XCTAssertEqual(queue.decisionAfterFinish(), .none)
        XCTAssertEqual(queue.decisionAfterSkip(), .none)
    }

    @MainActor
    func testRemoveCurrentShiftsToNeighbor() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        queue.add(entry(1))
        queue.add(entry(2))
        queue.setCurrent(entryID: queue.entries[1].id)
        _ = queue.remove(entryID: queue.entries[1].id)
        XCTAssertEqual(queue.nowPlaying?.songID, songIDs[2])
        _ = queue.remove(entryID: queue.nowPlaying!.id)
        XCTAssertEqual(queue.nowPlaying?.songID, songIDs[0])
    }

    // MARK: - Shuffle (seeded → deterministic)

    @MainActor
    func testShufflePlaysEveryEntryBeforeRepeating() {
        let queue = QueueManager(seed: 0x5EED)
        for i in 0..<4 { queue.add(entry(i)) }
        queue.toggleShuffle()
        XCTAssertTrue(queue.shuffleEnabled)

        var played: [UUID] = []
        for _ in 0..<4 {
            let decision = queue.decisionAfterFinish()
            guard case .next(let next) = decision else {
                return XCTFail("expected next decision")
            }
            played.append(next.songID)
            queue.setCurrent(entryID: next.id)
        }
        XCTAssertEqual(Set(played).count, 4, "shuffle must not repeat before all entries played")
        XCTAssertEqual(Set(played), Set(songIDs.prefix(4)))
        // All played + repeat off → none.
        XCTAssertEqual(queue.decisionAfterFinish(), .none)
    }

    @MainActor
    func testShuffleIsDeterministicForSeed() {
        func run(seed: UInt64) -> [UUID] {
            let queue = QueueManager(seed: seed)
            for i in 0..<4 { queue.add(entry(i)) }
            queue.toggleShuffle()
            var result: [UUID] = []
            for _ in 0..<4 {
                if case .next(let next) = queue.decisionAfterFinish() {
                    result.append(next.songID)
                    queue.setCurrent(entryID: next.id)
                }
            }
            return result
        }
        XCTAssertEqual(run(seed: 3), run(seed: 3))
        // Different seeds produce a different full order (verified for 3 vs 11).
        XCTAssertNotEqual(run(seed: 3), run(seed: 11), "expected the two seeds to order differently")
    }

    @MainActor
    func testShuffleRepeatAllReshufflesWhenExhausted() {
        let queue = QueueManager(seed: 42)
        for i in 0..<3 { queue.add(entry(i)) }
        queue.toggleShuffle()
        queue.setRepeat(.all)
        var played: [UUID] = []
        for _ in 0..<6 {
            if case .next(let next) = queue.decisionAfterFinish() {
                played.append(next.songID)
                queue.setCurrent(entryID: next.id)
            }
        }
        XCTAssertEqual(played.count, 6)
        XCTAssertEqual(Set(played.prefix(3)).count, 3)
        XCTAssertEqual(Set(played.suffix(3)).count, 3)
    }

    // MARK: - Preparation tokens (pre-generation cancellation)

    @MainActor
    func testPreparationTokensInvalidateOnRemovalAndClear() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        let id0 = queue.entries[0].id
        let token = queue.preparationToken(for: id0)
        // Stable while the entry sits in the queue.
        XCTAssertEqual(queue.preparationToken(for: id0), token)
        _ = queue.remove(entryID: id0)
        XCTAssertNotEqual(queue.preparationToken(for: id0), token)

        queue.add(entry(1))
        let id1 = queue.entries[0].id
        let token2 = queue.preparationToken(for: id1)
        queue.clear()
        XCTAssertNotEqual(queue.preparationToken(for: id1), token2)
    }

    @MainActor
    func testInvalidatePreparationExplicitly() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        let id = queue.entries[0].id
        let token = queue.preparationToken(for: id)
        queue.invalidatePreparation(entryID: id)
        XCTAssertNotEqual(queue.preparationToken(for: id), token)
    }

    // MARK: - Persistence

    @MainActor
    func testMutationsPersistAndRestore() {
        let queue = QueueManager(seed: 5)
        queue.add(entry(0))
        queue.add(entry(1))
        let currentID = queue.entries[0].id
        queue.setCurrent(entryID: currentID)
        queue.setRepeat(.all)
        queue.toggleShuffle()
        queue.setStatus(.ready, for: queue.entries[1].id)

        let restored = QueueManager(seed: 5, snapshot: QueueStorage.load())
        XCTAssertEqual(restored.entries.map(\.songID), [songIDs[0], songIDs[1]])
        XCTAssertEqual(restored.currentEntryID, currentID)
        XCTAssertEqual(restored.repeatMode, .all)
        XCTAssertTrue(restored.shuffleEnabled)
        // Preparation status never survives a relaunch.
        XCTAssertEqual(restored.entries[1].status, .idle)
    }

    @MainActor
    func testPersistenceRoundTripThroughAllMutations() {
        let queue = QueueManager(seed: 9)
        queue.add(entry(0))
        queue.add(entry(1))
        queue.add(entry(2))
        queue.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        queue.setRepeat(.one)
        let snapshot = queue.snapshot()
        let round = QueueManager(seed: 9, snapshot: snapshot)
        XCTAssertEqual(round.entries.map(\.songID), [songIDs[2], songIDs[0], songIDs[1]])
        XCTAssertEqual(round.repeatMode, .one)
    }

    @MainActor
    func testDeletedSongRestoreKeepsValidEntriesAndRepairsCurrent() {
        // A snapshot containing an entry whose song no longer exists (the app
        // drops it at restore; the queue itself must not crash and must fall
        // back to a valid current).
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        queue.add(entry(1))
        let currentID = queue.entries[0].id
        queue.setCurrent(entryID: currentID)
        // Simulate: entry 0's record was deleted → dropped from the snapshot.
        var snapshot = queue.snapshot()
        snapshot.entries = [snapshot.entries[1]]
        snapshot.currentEntryID = currentID   // now dangling
        let restored = QueueManager(seed: 1, snapshot: snapshot)
        XCTAssertEqual(restored.entries.map(\.songID), [songIDs[1]])
        // Dangling current is tolerated (nowPlaying == nil → queue starts at front).
        XCTAssertNil(restored.nowPlaying)
        XCTAssertEqual(restored.decisionAfterFinish(), .next(entry(1)))
    }

    /// Regression: the same song queued twice (different difficulties) shares
    /// a songID — decisions must key on the ENTRY identity, never on songID,
    /// or the queue loops on the first duplicate forever.
    @MainActor
    func testSameSongAtTwoDifficultiesAdvancesCorrectly() {
        let queue = QueueManager(seed: 1)
        let easy = QueueEntry(songID: songIDs[0], title: "Song", artist: "A", difficulty: .easy)
        let expert = QueueEntry(songID: songIDs[0], title: "Song", artist: "A", difficulty: .expert)
        queue.add(easy)
        queue.add(expert)
        queue.setCurrent(entryID: easy.id)

        // Easy finishes → expert (NOT easy again).
        XCTAssertEqual(queue.decisionAfterFinish(), .next(expert))
        queue.setCurrent(entryID: expert.id)
        // Expert finishes → end of queue → none (NOT expert again).
        XCTAssertEqual(queue.decisionAfterFinish(), .none)
        // Repeat All wraps back to EASY (first entry), not to itself.
        queue.setRepeat(.all)
        XCTAssertEqual(queue.decisionAfterFinish(), .next(easy))
    }

    // MARK: - Status transitions

    @MainActor
    func testStatusUpdatesOnlyForExistingEntries() {
        let queue = QueueManager(seed: 1)
        queue.add(entry(0))
        let id = queue.entries[0].id
        queue.setStatus(.preparing, for: id)
        XCTAssertEqual(queue.entries[0].status, .preparing)
        queue.setStatus(.ready, for: id)
        XCTAssertEqual(queue.entries[0].status, .ready)
        queue.setStatus(.error, for: UUID())   // unknown → no-op
        XCTAssertEqual(queue.entries[0].status, .ready)
    }
}