import Foundation
import Observation
import SwiftUI   // for IndexSet-based reordering

/// One local playlist. Stores only stable song IDs (never file paths or
/// fragile URLs), so a song may appear in several playlists and entries
/// whose song later disappears are handled gracefully at resolution time.
struct Playlist: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    /// Ordered stable song-record IDs (deduplicated within the playlist).
    var songIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, songIDs: [UUID] = [],
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.songIDs = songIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Local playlists: create/rename/delete, add/remove/reorder songs, and
/// deterministic shuffle ordering. Pure state machine with JSON persistence
/// (`playlists.json`) — no accounts, no cloud, no network. Every mutation
/// persists atomically; corrupt or missing files restore to an empty state
/// instead of crashing.
@MainActor
@Observable
final class PlaylistManager {
    // Workaround for swiftlang/swift#87316 (see StatsManager).
    deinit {}
    private(set) var playlists: [Playlist] = []

    init(snapshot: PlaylistSnapshot? = nil) {
        if let snapshot {
            restore(snapshot)
        }
    }

    // MARK: - Playlist CRUD (every mutation persists)

    @discardableResult
    func create(name: String) -> Playlist {
        let playlist = Playlist(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        playlists.append(playlist)
        persist()
        return playlist
    }

    /// Renames a playlist. Empty names are rejected (no-op).
    func rename(playlistID: UUID, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].name = name
        playlists[idx].updatedAt = Date()
        persist()
    }

    @discardableResult
    func delete(playlistID: UUID) -> Playlist? {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return nil }
        let removed = playlists.remove(at: idx)
        persist()
        return removed
    }

    func playlist(id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    // MARK: - Songs

    /// Adds a song to a playlist. Duplicates within the same playlist are a
    /// no-op (a song may still appear in MANY playlists).
    func addSong(_ songID: UUID, to playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[idx].songIDs.contains(songID) else { return }
        playlists[idx].songIDs.append(songID)
        playlists[idx].updatedAt = Date()
        persist()
    }

    /// Removes one song from one playlist.
    func removeSong(_ songID: UUID, from playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }),
              playlists[idx].songIDs.contains(songID) else { return }
        playlists[idx].songIDs.removeAll { $0 == songID }
        playlists[idx].updatedAt = Date()
        persist()
    }

    /// Removes a song from every playlist (used when the app deletes the
    /// song record itself — never leaves dangling entries).
    func removeSongFromAll(_ songID: UUID) {
        var changed = false
        for idx in playlists.indices where playlists[idx].songIDs.contains(songID) {
            playlists[idx].songIDs.removeAll { $0 == songID }
            playlists[idx].updatedAt = Date()
            changed = true
        }
        if changed { persist() }
    }

    /// Drag-reorder within a playlist.
    func moveSong(in playlistID: UUID, fromOffsets: IndexSet, toOffset: Int) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].songIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        playlists[idx].updatedAt = Date()
        persist()
    }

    // MARK: - Play ordering

    /// Playback order for a playlist: the stored order, or a deterministic
    /// seeded shuffle when `shuffled` is true. Both preserve every song
    /// exactly once. Resolution of missing songs happens at the app layer.
    func playOrder(songIDs: [UUID], shuffled: Bool, seed: UInt64) -> [UUID] {
        guard shuffled else { return songIDs }
        var rng = SplitMix64(state: seed)
        return songIDs.shuffled(using: &rng)
    }

    // MARK: - Persistence

    func snapshot() -> PlaylistSnapshot {
        PlaylistSnapshot(schemaVersion: PlaylistSnapshot.currentSchemaVersion,
                         playlists: playlists)
    }

    private func restore(_ snapshot: PlaylistSnapshot) {
        // Schema guard: never interpret data written by a newer version.
        guard snapshot.schemaVersion <= PlaylistSnapshot.currentSchemaVersion else { return }
        playlists = snapshot.playlists
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }   // nameless playlists are invalid
            .map { playlist in
                var fixed = playlist
                // Deduplicate defensively (old files / hand-edited storage).
                var seen = Set<UUID>()
                fixed.songIDs.removeAll { !seen.insert($0).inserted }
                return fixed
            }
    }

    private func persist() {
        PlaylistStorage.save(snapshot())
    }
}

/// Codable on-disk state for local playlists. Versioned so incompatible
/// schema changes can be detected instead of misread.
struct PlaylistSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var playlists: [Playlist]
}

/// JSON persistence (application support directory, on-device only).
enum PlaylistStorage {
    private static var url: URL {
        AppDirectories.documentsDirectory.appendingPathComponent("playlists.json")
    }

    static func save(_ snapshot: PlaylistSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    /// nil on missing/corrupt/incompatible data — callers start empty.
    static func load() -> PlaylistSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(PlaylistSnapshot.self, from: data),
              snapshot.schemaVersion <= PlaylistSnapshot.currentSchemaVersion else {
            return nil
        }
        return snapshot
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}