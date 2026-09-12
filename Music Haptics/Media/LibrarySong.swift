import Foundation

/// A lightweight, cached snapshot of one library song.
///
/// Kept UIKit/MediaPlayer-free so the search/sort/filter pipeline and its
/// tests run on any platform. Artwork access is handled by
/// MediaLibraryService, which retains the MPMediaItem alongside the snapshot.
struct LibrarySong: Identifiable {
    let persistentID: UInt64
    let title: String
    let artist: String
    let albumTitle: String?
    let duration: TimeInterval
    let genre: String?
    let libraryBPM: Int?
    let trackNumber: Int
    let trackCount: Int
    let isCloudOnly: Bool
    let hasProtectedAsset: Bool
    let assetURL: URL?
    let dateAdded: Date?
    let lastPlayedDate: Date?

    var id: UInt64 { persistentID }

    /// Why this item's audio is (or isn't) reachable. The MediaPlayer flags
    /// stay separate: DRM ≠ not-downloaded ≠ missing URL. `assetURL != nil`
    /// is the only real accessibility signal — a downloaded Apple Music item
    /// is a cloud item AND analyzable at the same time.
    var audioAccessState: AudioAccessState {
        if assetURL != nil { return .accessible }
        if hasProtectedAsset { return .protected }
        if isCloudOnly { return .cloudUnavailable }
        return .unavailable
    }

    /// True when this item's raw audio is reachable for analysis/playback.
    var isAudioAccessible: Bool { audioAccessState == .accessible }

    /// Snapshot init for tests and cache-only paths.
    init(persistentID: UInt64, title: String, artist: String, albumTitle: String?,
         duration: TimeInterval, genre: String? = nil, libraryBPM: Int? = nil,
         trackNumber: Int = 0, trackCount: Int = 0, isCloudOnly: Bool = false,
         hasProtectedAsset: Bool = false, assetURL: URL? = nil,
         dateAdded: Date? = nil, lastPlayedDate: Date? = nil) {
        self.persistentID = persistentID
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.duration = duration
        self.genre = genre
        self.libraryBPM = libraryBPM
        self.trackNumber = trackNumber
        self.trackCount = trackCount
        self.isCloudOnly = isCloudOnly
        self.hasProtectedAsset = hasProtectedAsset
        self.assetURL = assetURL
        self.dateAdded = dateAdded
        self.lastPlayedDate = lastPlayedDate
    }
}