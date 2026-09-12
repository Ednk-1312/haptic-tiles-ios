import Combine
import Foundation
import MediaPlayer
import UIKit

extension LibrarySong {
    /// Snapshot from a live MPMediaItem (artwork handled by the service's
    /// side table, so this stays in the UIKit/MediaPlayer file).
    static func snapshot(of mediaItem: MPMediaItem) -> LibrarySong {
        LibrarySong(persistentID: mediaItem.persistentID,
                    title: mediaItem.title ?? "Unknown Title",
                    artist: mediaItem.artist ?? "Unknown Artist",
                    albumTitle: mediaItem.albumTitle,
                    duration: mediaItem.playbackDuration,
                    genre: mediaItem.genre,
                    libraryBPM: mediaItem.beatsPerMinute > 0 ? mediaItem.beatsPerMinute : nil,
                    trackNumber: mediaItem.albumTrackNumber,
                    trackCount: mediaItem.albumTrackCount,
                    isCloudOnly: mediaItem.isCloudItem,
                    hasProtectedAsset: mediaItem.hasProtectedAsset,
                    assetURL: mediaItem.assetURL,
                    dateAdded: mediaItem.dateAdded,
                    lastPlayedDate: mediaItem.lastPlayedDate)
    }
}

/// Queries and caches the user's personal Music library.
///
/// The whole library is queried once per authorization/refresh and cached as
/// lightweight snapshots; search filters the cache locally, so typing never
/// re-queries MPMediaQuery.
@MainActor
final class MediaLibraryService: ObservableObject {
    // Workaround for swiftlang/swift#87316 (see StatsManager).
    deinit {}
    @Published private(set) var authorizationStatus: MPMediaLibraryAuthorizationStatus
    @Published private(set) var isLoading = false

    private var cachedSongs: [LibrarySong] = []
    private var cachedPlaylists: [(name: String, songs: [LibrarySong])] = []
    /// Retained MPMediaItems (artwork only), keyed by persistent ID.
    private var mediaItems: [UInt64: MPMediaItem] = [:]
    private let artworkCache = NSCache<NSString, UIImage>()

    init() {
        authorizationStatus = MPMediaLibrary.authorizationStatus()
    }

    // MARK: - Authorization

    /// Requests access; returns true when authorized. Refreshes on success.
    func requestAccess() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        authorizationStatus = status
        if status == .authorized {
            refresh()
        }
        return status == .authorized
    }

    // MARK: - Library snapshot

    /// Rebuilds the cached snapshot. The MediaPlayer queries run on a
    /// BACKGROUND queue: on a large personal library `MPMediaQuery.songs()`
    /// takes hundreds of milliseconds to seconds, and doing that synchronously
    /// on the main actor froze the UI on every My Music visit / pull-to-
    /// refresh — the classic "app hangs" symptom. Snapshots are lightweight
    /// value types, so only the final publish happens on the main thread.
    func refresh() {
        guard authorizationStatus == .authorized else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let songsQuery = MPMediaQuery.songs()
            let items = songsQuery.items ?? []
            let songs = items.map { LibrarySong.snapshot(of: $0) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            var media: [UInt64: MPMediaItem] = [:]
            media.reserveCapacity(items.count)
            for item in items { media[item.persistentID] = item }

            let playlistsQuery = MPMediaQuery.playlists()
            let playlists: [(name: String, songs: [LibrarySong])] = (playlistsQuery.collections ?? []).compactMap { collection in
                guard let playlist = collection as? MPMediaPlaylist else { return nil }
                let songs = playlist.items.map { LibrarySong.snapshot(of: $0) }
                // Playlist items may include songs missing from the songs query.
                for item in playlist.items where media[item.persistentID] == nil {
                    media[item.persistentID] = item
                }
                return (playlist.name ?? "Untitled Playlist", songs)
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.cachedSongs = songs
                    self.mediaItems = media
                    self.cachedPlaylists = playlists
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Queries (cache-backed)

    var songs: [LibrarySong] { cachedSongs }

    func search(_ text: String) -> [LibrarySong] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return cachedSongs }
        return cachedSongs.filter { song in
            song.title.localizedCaseInsensitiveContains(query)
                || song.artist.localizedCaseInsensitiveContains(query)
                || (song.albumTitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func song(persistentID: UInt64) -> LibrarySong? {
        cachedSongs.first { $0.persistentID == persistentID }
    }

    /// Playable asset URL for a persistent ID. Falls back to a fresh library
    /// lookup when the cached snapshot doesn't contain it (e.g. the app was
    /// relaunched and the snapshot is stale).
    func assetURL(persistentID: UInt64) -> URL? {
        if let cached = song(persistentID: persistentID) {
            return cached.isAudioAccessible ? cached.assetURL : nil
        }
        return MediaLibraryAudioSource(persistentID: persistentID).resolveAudioURL()
    }

    // MARK: - Grouping

    struct AlbumGroup: Identifiable {
        let id: String
        let title: String
        let artist: String
        let songs: [LibrarySong]
    }

    func albums() -> [AlbumGroup] {
        let grouped = Dictionary(grouping: cachedSongs, by: { "\($0.albumTitle ?? "Unknown Album")|\($0.artist)" })
        return grouped.values.map { songs in
            let key = "\(songs.first?.albumTitle ?? "Unknown Album")|\(songs.first?.artist ?? "")"
            let sorted = songs.sorted { ($0.trackNumber, $0.title) < ($1.trackNumber, $1.title) }
            return AlbumGroup(id: key,
                              title: sorted.first?.albumTitle ?? "Unknown Album",
                              artist: sorted.first?.artist ?? "",
                              songs: sorted)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    struct ArtistGroup: Identifiable {
        let id: String
        let name: String
        let songs: [LibrarySong]
    }

    func artists() -> [ArtistGroup] {
        let grouped = Dictionary(grouping: cachedSongs, by: { $0.artist })
        return grouped.values.map { songs in
            let name = songs.first?.artist ?? "Unknown Artist"
            return ArtistGroup(id: name, name: name, songs: songs.sorted { $0.title < $1.title })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var playlists: [(name: String, songs: [LibrarySong])] { cachedPlaylists }

    // MARK: - Artwork

    func artworkImage(persistentID: UInt64, size: CGSize) -> UIImage? {
        let key = "\(persistentID)-\(Int(size.width))" as NSString
        if let cached = artworkCache.object(forKey: key) { return cached }
        guard let item = mediaItems[persistentID],
              let image = item.artwork?.image(at: size) else { return nil }
        artworkCache.setObject(image, forKey: key)
        return image
    }
}