import XCTest
@testable import Music_Haptics

/// Deterministic local-playlist tests. PlaylistManager is a pure state
/// machine (JSON persistence, seeded shuffle), so everything is reproducible.
final class PlaylistTests: XCTestCase {
    override func setUpWithError() throws {
        PlaylistStorage.delete()
    }

    override func tearDownWithError() throws {
        PlaylistStorage.delete()
    }

    private func makeIDs(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    // MARK: - CRUD

    @MainActor
    func testCreateRenameDelete() {
        let manager = PlaylistManager()
        let playlist = manager.create(name: "  Workout  ")
        XCTAssertEqual(playlist.name, "Workout")           // trimmed
        XCTAssertEqual(manager.playlists.count, 1)

        manager.rename(playlistID: playlist.id, to: "Gym Mix")
        XCTAssertEqual(manager.playlists.first?.name, "Gym Mix")

        // Empty names are rejected.
        manager.rename(playlistID: playlist.id, to: "   ")
        XCTAssertEqual(manager.playlists.first?.name, "Gym Mix")

        XCTAssertNotNil(manager.delete(playlistID: playlist.id))
        XCTAssertTrue(manager.playlists.isEmpty)
        // Deleting a missing playlist is a safe no-op.
        XCTAssertNil(manager.delete(playlistID: UUID()))
    }

    // MARK: - Songs

    @MainActor
    func testAddRemoveReorderDedupe() {
        let manager = PlaylistManager()
        let playlist = manager.create(name: "Mix")
        let ids = makeIDs(4)

        for id in ids { manager.addSong(id, to: playlist.id) }
        // Duplicates within a playlist are a no-op.
        manager.addSong(ids[0], to: playlist.id)
        XCTAssertEqual(manager.playlists.first?.songIDs, ids)

        // A song can be in MULTIPLE playlists.
        let other = manager.create(name: "Other")
        manager.addSong(ids[0], to: other.id)
        manager.addSong(ids[1], to: other.id)
        XCTAssertEqual(manager.playlists.first { $0.id == other.id }?.songIDs, [ids[0], ids[1]])

        // Reorder: move index 0 to the end.
        manager.moveSong(in: playlist.id, fromOffsets: IndexSet(integer: 0), toOffset: 4)
        XCTAssertEqual(manager.playlists.first?.songIDs, [ids[1], ids[2], ids[3], ids[0]])

        manager.removeSong(ids[2], from: playlist.id)
        XCTAssertEqual(manager.playlists.first?.songIDs, [ids[1], ids[3], ids[0]])

        // removeSongFromAll touches every playlist at once.
        manager.removeSongFromAll(ids[1])
        XCTAssertEqual(manager.playlists.first?.songIDs, [ids[3], ids[0]])
        XCTAssertEqual(manager.playlists.first { $0.id == other.id }?.songIDs, [ids[0]])
    }

    @MainActor
    func testUnknownSongIDsAreStoredGracefully() {
        let manager = PlaylistManager()
        let playlist = manager.create(name: "Mix")
        // IDs that resolve to nothing are legal — resolution happens at the
        // app layer, and the manager must not crash or drop them.
        manager.addSong(UUID(), to: playlist.id)
        manager.addSong(UUID(), to: playlist.id)
        XCTAssertEqual(manager.playlists.first?.songIDs.count, 2)
        manager.removeSong(manager.playlists.first!.songIDs[0], from: playlist.id)
        XCTAssertEqual(manager.playlists.first?.songIDs.count, 1)
    }

    // MARK: - Play ordering

    @MainActor
    func testPlayOrderPreservesStoredOrder() {
        let manager = PlaylistManager()
        let ids = makeIDs(5)
        XCTAssertEqual(manager.playOrder(songIDs: ids, shuffled: false, seed: 0), ids)
        XCTAssertEqual(manager.playOrder(songIDs: [], shuffled: false, seed: 0), [])
    }

    @MainActor
    func testShuffleIsDeterministicAndLossless() {
        let manager = PlaylistManager()
        let ids = makeIDs(8)
        let a = manager.playOrder(songIDs: ids, shuffled: true, seed: 42)
        let b = manager.playOrder(songIDs: ids, shuffled: true, seed: 42)
        let c = manager.playOrder(songIDs: ids, shuffled: true, seed: 43)
        XCTAssertEqual(a, b)                                  // same seed → same order
        XCTAssertNotEqual(a, c)                               // different seed → different order
        XCTAssertEqual(Set(a), Set(ids))                      // every song exactly once
        XCTAssertEqual(Set(c), Set(ids))
    }

    // MARK: - Persistence

    @MainActor
    func testPersistenceRoundTrip() {
        let manager = PlaylistManager()
        let ids = makeIDs(3)
        let playlist = manager.create(name: "Saved")
        for id in ids { manager.addSong(id, to: playlist.id) }
        manager.rename(playlistID: playlist.id, to: "Saved v2")

        // A fresh manager restores from disk.
        let restored = PlaylistManager(snapshot: PlaylistStorage.load())
        XCTAssertEqual(restored.playlists.count, 1)
        XCTAssertEqual(restored.playlists.first?.name, "Saved v2")
        XCTAssertEqual(restored.playlists.first?.songIDs, ids)
    }

    @MainActor
    func testRestoreRepairsLegacyDupesAndNameless() {
        let ids = makeIDs(3)
        var duplicated = ids + [ids[1]]                        // hand-edited duplicate
        duplicated.append(contentsOf: [ids[0]])
        let legacy = PlaylistSnapshot(schemaVersion: 1, playlists: [
            Playlist(name: "  ", songIDs: ids),                // invalid: empty name
            Playlist(name: "Dupes", songIDs: duplicated),
        ])
        let manager = PlaylistManager(snapshot: legacy)
        XCTAssertEqual(manager.playlists.count, 1)             // nameless dropped
        XCTAssertEqual(manager.playlists.first?.name, "Dupes")
        XCTAssertEqual(manager.playlists.first?.songIDs, ids)  // deduped, order kept
    }

    @MainActor
    func testNewerSchemaIsRejected() {
        let future = PlaylistSnapshot(schemaVersion: 99, playlists: [
            Playlist(name: "Future"),
        ])
        let manager = PlaylistManager(snapshot: future)
        XCTAssertTrue(manager.playlists.isEmpty)               // never misread
    }

    @MainActor
    func testCorruptFileStartsEmpty() {
        let url = AppDirectories.documentsDirectory.appendingPathComponent("playlists.json")
        try? FileManager.default.createDirectory(at: AppDirectories.documentsDirectory,
                                                 withIntermediateDirectories: true)
        try? "not json {{{".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(PlaylistStorage.load())
        let manager = PlaylistManager(snapshot: PlaylistStorage.load())
        XCTAssertTrue(manager.playlists.isEmpty)
        // And a fresh mutation still persists cleanly over the bad file.
        _ = manager.create(name: "Recovered")
        let restored = PlaylistManager(snapshot: PlaylistStorage.load())
        XCTAssertEqual(restored.playlists.first?.name, "Recovered")
    }

    // MARK: - Queue integration (the app's playlist → queue flow)

    @MainActor
    func testQueueBuildFromPlaylistOrder() {
        // Mirrors AppState.queuePlaylist's core: resolve order → entries →
        // queue transitions follow the playlist order exactly.
        let manager = PlaylistManager()
        let ids = makeIDs(4)
        let playlist = manager.create(name: "Session")
        for id in ids { manager.addSong(id, to: playlist.id) }
        // `create` returns a snapshot; re-fetch the LIVE playlist (addSong
        // mutates the manager's stored copy) — same pattern the UI uses.
        let live = manager.playlist(id: playlist.id)!

        let ordered = manager.playOrder(songIDs: live.songIDs, shuffled: false, seed: 0)
        let entries = ordered.enumerated().map { i, id in
            QueueEntry(songID: id, title: "Song \(i)", artist: "Artist")
        }

        let queue = QueueManager(seed: 1)
        queue.add(entries)
        queue.setCurrent(entryID: queue.entries[0].id)
        XCTAssertEqual(queue.nowPlaying?.songID, ids[0])
        for i in 1..<ids.count {
            let decision = queue.decisionAfterFinish()
            guard case let .next(next) = decision else {
                XCTFail("expected next at step \(i)"); return
            }
            XCTAssertEqual(next.songID, ids[i])
        }
        XCTAssertEqual(queue.decisionAfterFinish(), .none)     // playlist exhausted
    }

    @MainActor
    func testShuffledQueuePlaysEverySongOnce() {
        let manager = PlaylistManager()
        let ids = makeIDs(6)
        let playlist = manager.create(name: "Shuffle")
        for id in ids { manager.addSong(id, to: playlist.id) }

        let live = manager.playlist(id: playlist.id)!
        let ordered = manager.playOrder(songIDs: live.songIDs, shuffled: true, seed: 7)
        XCTAssertEqual(Set(ordered), Set(ids))

        let queue = QueueManager(seed: 1)
        queue.add(ordered.map { QueueEntry(songID: $0, title: "Song", artist: "Artist") })
        queue.setCurrent(entryID: queue.entries[0].id)
        var played: [UUID] = [queue.nowPlaying!.songID]
        while case let .next(next) = queue.decisionAfterFinish() {
            played.append(next.songID)
        }
        XCTAssertEqual(Set(played), Set(ids))
        XCTAssertEqual(played.count, ids.count)
    }
}