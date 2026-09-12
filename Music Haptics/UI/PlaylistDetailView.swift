import SwiftData
import SwiftUI

/// One playlist's songs: Play / Shuffle / Add to Queue, drag reorder, remove,
/// and an add-songs picker covering My Music + imported files.
struct PlaylistDetailView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var settings: SettingsStore
    @Query private var records: [SongRecord]

    let playlistID: UUID

    @State private var showAddSongs = false
    @State private var playingSession: GameSession?
    @State private var playingRecord: SongRecord?
    @State private var errorMessage: String?

    private var playlist: Playlist? {
        appState.playlists.playlist(id: playlistID)
    }

    private var songs: [SongRecord] {
        guard let playlist else { return [] }
        return playlist.songIDs.compactMap { id in records.first { $0.id == id } }
    }

    private var missing: Int {
        guard let playlist else { return 0 }
        return playlist.songIDs.count - songs.count
    }

    private var totalDuration: Double {
        songs.reduce(0) { $0 + max(0, $1.duration) }
    }

    var body: some View {
        Group {
            if let playlist {
                List {
                    header(playlist)

                    if songs.isEmpty {
                        Section {
                            Text("No songs yet. Tap + to add songs from My Music or your imported files.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section("Songs") {
                            ForEach(songs) { song in
                                playlistSongRow(song)
                            }
                            .onDelete { offsets in
                                let removed = songs[offsets.first ?? 0]
                                appState.playlists.removeSong(removed.id, from: playlistID)
                            }
                            .onMove { source, dest in
                                appState.playlists.moveSong(in: playlistID, fromOffsets: source, toOffset: dest)
                            }
                        }
                    }
                }
                .navigationTitle(playlist.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showAddSongs = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add songs")
                        if !songs.isEmpty {
                            EditButton()
                        }
                    }
                }
            } else {
                ContentUnavailableView("Playlist Not Found",
                                       systemImage: "music.note.list",
                                       description: Text("This playlist may have been deleted."))
            }
        }
        .sheet(isPresented: $showAddSongs) {
            AddSongsToPlaylistView(playlistID: playlistID, records: records)
        }
        .fullScreenCover(item: $playingSession) { session in
            if let record = playingRecord {
                GameView(session: session, song: record, settings: settings)
            }
        }
        .alert("Playlist", isPresented: Binding(get: { errorMessage != nil },
                                                set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func header(_ playlist: Playlist) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    PlaylistCollage(songs: Array(songs.prefix(4)))
                        .frame(width: 92, height: 92)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playlist.name)
                            .font(.title2.weight(.bold))
                            .lineLimit(2)
                        Text("\(songs.count) song\(songs.count == 1 ? "" : "s") · \(Format.duration(totalDuration))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if missing > 0 {
                            Text("\(missing) song\(missing == 1 ? "" : "s") unavailable")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    playButton("Play", systemImage: "play.fill", shuffled: false)
                    playButton("Shuffle", systemImage: "shuffle", shuffled: true)
                    Button {
                        let added = appState.addPlaylistToQueue(playlist)
                        if added > 0 {
                            errorMessage = "Added \(added) song\(added == 1 ? "" : "s") to the queue."
                        } else {
                            errorMessage = "Nothing to add — the playlist is empty."
                        }
                    } label: {
                        Label("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                    .disabled(songs.isEmpty)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func playButton(_ title: String, systemImage: String, shuffled: Bool) -> some View {
        Button {
            play(shuffled: shuffled)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
        }
        .disabled(songs.isEmpty)
    }

    /// Queues the whole playlist (in order, or deterministically shuffled) and
    /// opens the first song; the queue-aware GameView advances automatically.
    private func play(shuffled: Bool) {
        guard let playlist,
              let first = appState.queuePlaylist(playlist, shuffled: shuffled) else {
            errorMessage = "No playable songs — analyze a song first."
            return
        }
        guard let record = appState.record(id: first.songID) else { return }
        Task {
            let session: GameSession?
            do {
                session = try await appState.session(for: first)
            } catch is CancellationError {
                return   // superseded by a newer pipeline; playlist entry stays queued
            } catch {
                session = nil
            }
            if let session {
                playingRecord = record
                try? await Task.sleep(for: .milliseconds(200))
                playingSession = session
            } else {
                errorMessage = "\"\(first.title)\" can't be played right now — its audio is unavailable."
                appState.queue.remove(entryID: first.id)
            }
        }
    }

    private func playlistSongRow(_ song: SongRecord) -> some View {
        HStack(spacing: 12) {
            ArtworkView(data: song.artworkData)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(song.artist) · \(Format.duration(song.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            StatusBadge(state: song.analysisState)
        }
        .padding(.vertical, 2)
    }
}

/// Picker sheet: every app record (My Music library records + imported files)
/// not already in the playlist. Tapping a row adds it (and the row drops out).
private struct AddSongsToPlaylistView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let playlistID: UUID
    let records: [SongRecord]

    private var candidates: [SongRecord] {
        guard let playlist = appState.playlists.playlist(id: playlistID) else { return [] }
        return records
            .filter { !playlist.songIDs.contains($0.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView("All songs added",
                                           systemImage: "checkmark.circle",
                                           description: Text("Every song is already in this playlist."))
                } else {
                    List(candidates) { song in
                        Button {
                            appState.playlists.addSong(song.id, to: playlistID)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(data: song.artworkData)
                                    .frame(width: 46, height: 46)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(song.title)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text("\(song.artist) · \(Format.duration(song.duration))")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}