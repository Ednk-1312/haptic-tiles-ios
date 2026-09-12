import MediaPlayer
import SwiftData
import SwiftUI
import UIKit

/// The primary song-selection experience: browse/search the user's personal
/// Music library, choose a song, and it gets analyzed + charted.
struct MyMusicView: View {
    @EnvironmentObject private var mediaLibrary: MediaLibraryService
    @Environment(AppState.self) private var appState
    @Query(sort: \SongRecord.importDate, order: .reverse) private var records: [SongRecord]

    @State private var tab: MyMusicTab = .songs
    @State private var searchText = ""
    @State private var selectedSong: SongRecord?
    @State private var sortOption: LibrarySortOption = .title
    @State private var filters = LibraryFilters()

    private enum MyMusicTab: String, CaseIterable, Identifiable {
        case songs, albums, artists, playlists
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// Records keyed by media-library persistent ID, for status badges.
    private var recordByID: [UInt64: SongRecord] {
        var map: [UInt64: SongRecord] = [:]
        for record in records {
            if let id = record.mediaLibraryPersistentID { map[id] = record }
        }
        return map
    }

    /// Pure snapshots of the same records, for the deterministic sort/filter
    /// pipeline (no SwiftData objects cross into the logic layer).
    private var recordSnapshots: [UInt64: SongRecordSnapshot] {
        var map: [UInt64: SongRecordSnapshot] = [:]
        for record in records {
            guard let id = record.mediaLibraryPersistentID else { continue }
            map[id] = SongRecordSnapshot(persistentID: id,
                                         isChartReady: record.analysisState == .ready,
                                         difficultyLevel: record.chartDifficulty,
                                         difficultyScore: record.difficultyScore)
        }
        return map
    }

    /// Sorted + filtered songs per the current search/sort/filter state.
    private var visibleSongs: [LibrarySong] {
        MusicLibraryFiltering.apply(mediaLibrary.songs,
                                    searchText: searchText,
                                    sort: sortOption,
                                    filters: filters,
                                    records: recordSnapshots)
    }

    private func artwork(for song: LibrarySong) -> UIImage? {
        mediaLibrary.artworkImage(persistentID: song.persistentID,
                                  size: CGSize(width: 104, height: 104))
    }

    var body: some View {
        Group {
            switch mediaLibrary.authorizationStatus {
            case .notDetermined:
                notDeterminedView
            case .denied:
                deniedView
            case .restricted:
                restrictedView
            default:
                content
            }
        }
        .navigationTitle("My Music")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedSong) { SongDetailView(song: $0) }
    }

    // MARK: - Authorization states

    private var notDeterminedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Play your own music")
                .font(.title2.weight(.bold))
            Text("Haptic Piano analyzes songs from your Music library on this device and turns them into playable rhythm charts. Your music never leaves your device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button {
                Task { _ = await mediaLibrary.requestAccess() }
            } label: {
                Label("Allow Music Access", systemImage: "lock.open")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Music access is off")
                .font(.title2.weight(.bold))
            Text("Haptic Piano can't see your Music library without permission. You can enable it in Settings — or keep using Import from Files, which works without Music access.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button {
                openSettings()
            } label: {
                Label("Open Settings", systemImage: "arrow.up.right.square")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var restrictedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Music access is restricted")
                .font(.title2.weight(.bold))
            Text("This device restricts access to the Music library (for example, parental controls). You can still import audio files from Files.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Authorized content

    private var content: some View {
        VStack(spacing: 0) {
            Picker("Browse", selection: $tab) {
                ForEach(MyMusicTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch tab {
            case .songs: songsList
            case .albums: albumsList
            case .artists: artistsList
            case .playlists: playlistsList
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Songs, artists, albums")
        .task { mediaLibrary.refresh() }
        .refreshable { mediaLibrary.refresh() }
    }

    private func select(_ song: LibrarySong) {
        let artwork = mediaLibrary.artworkImage(persistentID: song.persistentID,
                                                size: CGSize(width: 300, height: 300))?
            .jpegData(compressionQuality: 0.8)
        selectedSong = appState.analyzeLibrarySong(song, artwork: artwork)
    }

    private var songsList: some View {
        let songs = visibleSongs
        return List {
            if songs.isEmpty {
                Text(emptyMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(songs) { song in
                    Button {
                        select(song)
                    } label: {
                        LibrarySongRow(song: song,
                                       artwork: artwork(for: song),
                                       record: recordByID[song.persistentID])
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top, spacing: 0) {
            browseControlBar
        }
    }

    private var emptyMessage: String {
        if !mediaLibrary.songs.isEmpty && filters.isActive {
            return "No songs match the current filters."
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matches for “\(searchText)”."
        }
        return "Your Music library is empty."
    }

    /// Sort + filter controls. Solid, compact surfaces — the library stays
    /// out of Liquid-Glass territory.
    private var browseControlBar: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Sort by", selection: $sortOption) {
                    ForEach(LibrarySortOption.allCases) { option in
                        Label(option.displayName, systemImage: option.icon).tag(option)
                    }
                }
            } label: {
                controlLabel("Sort: \(sortOption.displayName)", icon: "arrow.up.arrow.down")
            }

            Menu {
                Picker("Audio", selection: $filters.availability) {
                    ForEach(LibraryAvailabilityFilter.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                Picker("Analysis", selection: $filters.analysis) {
                    ForEach(LibraryAnalysisFilter.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                Divider()
                Text("Difficulty (★ score)")
                Picker("Difficulty range", selection: difficultyBinding) {
                    Text("Any").tag(Optional<ClosedRange<Int>>(nil))
                    ForEach(0...10, id: \.self) { n in
                        Text("★ \(n)").tag(Optional<ClosedRange<Int>>(n...n))
                    }
                    Text("★ 7–10").tag(Optional<ClosedRange<Int>>(7...10))
                }
            } label: {
                controlLabel(filtersLabel, icon: "line.3.horizontal.decrease")
                    .foregroundStyle(filters.isActive ? Color.accentColor : Color.primary)
            }

            Spacer(minLength: 0)

            if filters.isActive {
                Button {
                    filters = LibraryFilters()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filters")
            }

            Text("\(visibleSongs.count) songs")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private func controlLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var filtersLabel: String {
        var parts: [String] = []
        if filters.availability != .all { parts.append(filters.availability.displayName) }
        if filters.analysis != .all { parts.append(filters.analysis.displayName) }
        if let label = filters.difficultyFilterLabel { parts.append(label) }
        return parts.isEmpty ? "Filter" : parts.joined(separator: " · ")
    }

    private var difficultyBinding: Binding<ClosedRange<Int>?> {
        Binding(get: { filters.difficultyRange },
                set: { filters.difficultyRange = $0 })
    }

    private var albumsList: some View {
        let albums = MusicLibraryFiltering.searchAlbums(mediaLibrary.albums().map {
            MusicLibraryFiltering.AlbumGroupShell(title: $0.title, artist: $0.artist, songs: $0.songs)
        }, text: searchText)
        return List {
            if albums.isEmpty {
                Text("No albums match.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(albums) { album in
                    NavigationLink {
                        LibrarySongsList(title: album.title,
                                         songs: album.songs,
                                         recordByID: recordByID,
                                         onSelect: select,
                                         artworkProvider: artwork)
                    } label: {
                        HStack(spacing: 12) {
                            if let first = album.songs.first {
                                ArtworkView(image: artwork(for: first))
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(album.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text("\(album.artist) · \(album.songs.count) songs")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var artistsList: some View {
        let artists = MusicLibraryFiltering.searchArtists(mediaLibrary.artists().map {
            MusicLibraryFiltering.ArtistGroupShell(name: $0.name, songs: $0.songs)
        }, text: searchText)
        return List {
            if artists.isEmpty {
                Text("No artists match.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(artists) { artist in
                    NavigationLink {
                        LibrarySongsList(title: artist.name,
                                         songs: artist.songs,
                                         recordByID: recordByID,
                                         onSelect: select,
                                         artworkProvider: artwork)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                                .frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(artist.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text("\(artist.songs.count) songs")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var playlistsList: some View {
        let playlists = MusicLibraryFiltering.searchPlaylists(mediaLibrary.playlists, text: searchText)
        return List {
            if playlists.isEmpty {
                Text(searchText.isEmpty
                     ? "No playlists in your Music library."
                     : "No playlists match.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(playlists, id: \.name) { playlist in
                    NavigationLink {
                        LibrarySongsList(title: playlist.name,
                                         songs: playlist.songs,
                                         recordByID: recordByID,
                                         onSelect: select,
                                         artworkProvider: artwork)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "music.note.list")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                                .frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text("\(playlist.songs.count) songs")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

}

/// One song row in My Music, with analysis status when a record exists.
struct LibrarySongRow: View {
    let song: LibrarySong
    let artwork: UIImage?
    let record: SongRecord?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(image: artwork)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                statusRow
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts: [String] = []
        if song.artist != "Unknown Artist" { parts.append(song.artist) }
        if let album = song.albumTitle { parts.append(album) }
        parts.append(Format.duration(song.duration))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusRow: some View {
        if let record {
            HStack(spacing: 6) {
                StatusBadge(state: record.analysisState)
                if record.analysisState == .ready, let difficulty = record.chartDifficulty {
                    DifficultyBadge(difficulty: difficulty)
                }
            }
        } else if song.audioAccessState != .accessible {
            // Honest per-cause labels: DRM, not-downloaded and unknown are
            // separate states, never collapsed into one "DRM" badge.
            HStack(spacing: 4) {
                Image(systemName: stateIcon)
                    .font(.caption2)
                Text(stateText)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        } else {
            Text("Tap to analyze")
                .font(.caption)
                .foregroundStyle(.tint)
        }
    }

    private var stateIcon: String {
        switch song.audioAccessState {
        case .protected: return "lock.fill"
        case .cloudUnavailable: return "icloud.slash"
        case .unavailable: return "questionmark.circle"
        case .accessible: return ""
        }
    }

    private var stateText: String {
        switch song.audioAccessState {
        case .protected: return "DRM Protected"
        case .cloudUnavailable: return "Not Downloaded"
        case .unavailable: return "Audio Unavailable"
        case .accessible: return ""
        }
    }
}

/// Reusable list of library songs (album / artist / playlist drill-down).
struct LibrarySongsList: View {
    let title: String
    let songs: [LibrarySong]
    let recordByID: [UInt64: SongRecord]
    let onSelect: (LibrarySong) -> Void
    /// Artwork provider (routes through the service's cache).
    let artworkProvider: (LibrarySong) -> UIImage?

    var body: some View {
        List {
            ForEach(songs) { song in
                Button {
                    onSelect(song)
                } label: {
                    LibrarySongRow(song: song,
                                   artwork: artworkProvider(song),
                                   record: recordByID[song.persistentID])
                }
                .foregroundStyle(.primary)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}