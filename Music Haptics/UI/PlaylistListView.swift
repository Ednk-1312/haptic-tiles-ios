import SwiftData
import SwiftUI

/// Local playlists: create, rename, delete. Rows show a 4-up artwork collage,
/// song count and total duration, resolved live from song records (missing
/// songs are counted, never crash).
struct PlaylistListView: View {
    @Environment(AppState.self) private var appState
    @Query private var records: [SongRecord]

    @State private var renameTarget: Playlist?
    @State private var deleteTarget: Playlist?
    @State private var createName = ""

    var body: some View {
        Group {
            if appState.playlists.playlists.isEmpty {
                ContentUnavailableView("No Playlists",
                                       systemImage: "music.note.list",
                                       description: Text("Create a playlist to group songs for a session."))
            } else {
                List {
                    ForEach(appState.playlists.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlistID: playlist.id)
                        } label: {
                            PlaylistRow(playlist: playlist, records: records)
                        }
                        .contextMenu {
                            Button {
                                renameTarget = playlist
                                createName = playlist.name
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deleteTarget = playlist
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteTarget = playlist
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renameTarget = playlist
                                createName = playlist.name
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                createName = ""
                renameTarget = nil
                showCreate = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Create playlist")
        }
        .alert("New Playlist", isPresented: $showCreate) {
            TextField("Name", text: $createName)
            Button("Create") {
                appState.playlists.create(name: createName)
            }
            .disabled(createName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: Binding(get: { renameTarget != nil },
                                                       set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $createName)
            Button("Rename") {
                if let target = renameTarget {
                    appState.playlists.rename(playlistID: target.id, to: createName)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("Delete \"\(deleteTarget?.name ?? "")?\"",
                            isPresented: Binding(get: { deleteTarget != nil },
                                                 set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                if let target = deleteTarget {
                    appState.playlists.delete(playlistID: target.id)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("The songs stay in your library — only the playlist is removed.")
        }
    }

    @State private var showCreate = false
}

/// One playlist row: up-to-4-tile artwork collage, name, count + duration.
private struct PlaylistRow: View {
    let playlist: Playlist
    let records: [SongRecord]

    private var songs: [SongRecord] {
        playlist.songIDs.compactMap { id in records.first { $0.id == id } }
    }

    private var missing: Int {
        playlist.songIDs.count - songs.count
    }

    private var duration: Double {
        songs.reduce(0) { $0 + max(0, $1.duration) }
    }

    var body: some View {
        HStack(spacing: 14) {
            PlaylistCollage(songs: Array(songs.prefix(4)))
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let count = songs.count
        var text = "\(count) song\(count == 1 ? "" : "s") · \(Format.duration(duration))"
        if missing > 0 {
            text += " · \(missing) unavailable"
        }
        return text
    }
}

/// 2×2 artwork grid with a music-note placeholder for songs without artwork.
struct PlaylistCollage: View {
    let songs: [SongRecord]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [.pink, .purple],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if songs.isEmpty {
                Image(systemName: "music.note.list")
                    .font(.title3)
                    .foregroundStyle(.white)
            } else {
                VStack(spacing: 1) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 1) {
                            ForEach(0..<2, id: \.self) { col in
                                let index = row * 2 + col
                                Group {
                                    if index < songs.count {
                                        ArtworkView(data: songs[index].artworkData)
                                    } else {
                                        Color.black.opacity(0.25)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipped()
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}