import Foundation

/// A lightweight, platform-neutral snapshot of the app's local record for a
/// library song. The view maps SwiftData `SongRecord`s into this so the
/// filtering/sorting logic stays pure and testable (no SwiftData, no MediaPlayer).
struct SongRecordSnapshot: Equatable {
    let persistentID: UInt64
    /// Raw analysis state; `ready` means a playable chart exists.
    let isChartReady: Bool
    /// Highest generated difficulty tier, if any.
    let difficultyLevel: DifficultyLevel?
    /// Deterministic difficulty score (0…10), if any.
    let difficultyScore: Double?
}

/// Sort orders available for the My Music song list. Each option is
/// deterministic: ties are broken by localized title, then persistent ID.
enum LibrarySortOption: String, CaseIterable, Identifiable {
    case title
    case artist
    case album
    case duration
    case recentlyAdded
    case recentlyPlayed
    case difficulty

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .duration: return "Duration"
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        case .difficulty: return "Difficulty"
        }
    }

    var icon: String {
        switch self {
        case .title: return "textformat"
        case .artist: return "music.mic"
        case .album: return "square.stack"
        case .duration: return "clock"
        case .recentlyAdded: return "plus.circle"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .difficulty: return "gauge.with.dots.needle.50percent"
        }
    }
}

/// Analysis-progress filters for the song list.
enum LibraryAnalysisFilter: String, CaseIterable, Identifiable {
    case all
    case analyzed
    case notAnalyzed
    case chartReady

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All Songs"
        case .analyzed: return "Analyzed"
        case .notAnalyzed: return "Not Analyzed"
        case .chartReady: return "Chart Ready"
        }
    }
}

/// Audio-access filters. `protected` groups every reason audio is
/// unavailable (DRM, cloud-only, missing URL) — the per-cause detail still
/// shows on each row.
enum LibraryAvailabilityFilter: String, CaseIterable, Identifiable {
    case all
    case accessible
    case unavailable

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "Any Audio"
        case .accessible: return "Audio Available"
        case .unavailable: return "Audio Unavailable"
        }
    }
}

/// Combined filter state for the song list.
struct LibraryFilters: Equatable {
    var analysis: LibraryAnalysisFilter = .all
    var availability: LibraryAvailabilityFilter = .all
    /// Difficulty-score range (0…10); nil = no difficulty filter. Applies to
    /// the app's deterministic difficulty score of the song's best chart.
    var difficultyRange: ClosedRange<Int>?

    var isActive: Bool {
        analysis != .all || availability != .all || difficultyRange != nil
    }

    var difficultyFilterLabel: String? {
        guard let difficultyRange else { return nil }
        if difficultyRange.lowerBound == difficultyRange.upperBound {
            return "★ \(difficultyRange.lowerBound)"
        }
        return "★ \(difficultyRange.lowerBound)–\(difficultyRange.upperBound)"
    }
}

enum MusicLibraryFiltering {
    // MARK: - Search

    /// Local search over title, artist and album (case-insensitive,
    /// whitespace-trimmed). Empty query returns everything unsorted — the
    /// caller applies its own ordering.
    static func search(_ songs: [LibrarySong], text: String) -> [LibrarySong] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return songs }
        return songs.filter { song in
            song.title.localizedCaseInsensitiveContains(query)
                || song.artist.localizedCaseInsensitiveContains(query)
                || (song.albumTitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Album/artist group shells used by group search (platform-neutral).
    struct AlbumGroupShell: Identifiable {
        let title: String
        let artist: String
        let songs: [LibrarySong]
        var id: String { title + "|" + artist }
    }

    struct ArtistGroupShell: Identifiable {
        let name: String
        let songs: [LibrarySong]
        var id: String { name }
    }

    /// Search over album groups: matches the album title, artist, or any
    /// contained song's title/artist/album. Preserves group order.
    static func searchAlbums(_ groups: [AlbumGroupShell], text: String) -> [AlbumGroupShell] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter { group in
            group.title.localizedCaseInsensitiveContains(query)
                || group.artist.localizedCaseInsensitiveContains(query)
                || group.songs.contains(where: { songMatches($0, query) })
        }
    }

    /// Search over artist groups: matches the artist name or any contained
    /// song. Preserves group order.
    static func searchArtists(_ groups: [ArtistGroupShell], text: String) -> [ArtistGroupShell] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter { group in
            group.name.localizedCaseInsensitiveContains(query)
                || group.songs.contains(where: { songMatches($0, query) })
        }
    }

    /// Search over named playlist groups: matches the playlist name or any
    /// contained song. Preserves group order.
    static func searchPlaylists(_ playlists: [(name: String, songs: [LibrarySong])],
                                text: String) -> [(name: String, songs: [LibrarySong])] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return playlists }
        return playlists.filter { playlist in
            playlist.name.localizedCaseInsensitiveContains(query)
                || playlist.songs.contains(where: { songMatches($0, query) })
        }
    }

    private static func songMatches(_ song: LibrarySong, _ query: String) -> Bool {
        song.title.localizedCaseInsensitiveContains(query)
            || song.artist.localizedCaseInsensitiveContains(query)
            || (song.albumTitle?.localizedCaseInsensitiveContains(query) ?? false)
    }

    // MARK: - Filtering

    /// Applies analysis / availability / difficulty filters. Deterministic —
    /// input order is preserved within each filter.
    static func filter(_ songs: [LibrarySong],
                       analysis: LibraryAnalysisFilter,
                       availability: LibraryAvailabilityFilter,
                       difficultyRange: ClosedRange<Int>?,
                       records: [UInt64: SongRecordSnapshot]) -> [LibrarySong] {
        songs.filter { song in
            let record = records[song.persistentID]

            // Audio availability.
            switch availability {
            case .all: break
            case .accessible:
                guard song.isAudioAccessible else { return false }
            case .unavailable:
                guard !song.isAudioAccessible else { return false }
            }

            // Analysis progress.
            switch analysis {
            case .all: break
            case .analyzed:
                guard record != nil else { return false }
            case .notAnalyzed:
                guard record == nil else { return false }
            case .chartReady:
                guard let record, record.isChartReady else { return false }
            }

            // Difficulty score range (applied to the app's own score).
            if let difficultyRange {
                guard let record, let score = record.difficultyScore else { return false }
                let bucket = Int(score.rounded(.down))
                guard difficultyRange.contains(bucket) else { return false }
            }

            return true
        }
    }

    // MARK: - Sorting

    /// Sorts deterministically for the given option. Every comparator is
    /// strict and total: primary key, then localized title, then persistent
    /// ID — so identical input always yields identical output.
    static func sorted(_ songs: [LibrarySong],
                       by option: LibrarySortOption,
                       records: [UInt64: SongRecordSnapshot]) -> [LibrarySong] {
        songs.sorted { a, b in
            switch option {
            case .title:
                if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            case .artist:
                let aa = a.artist, bb = b.artist
                if aa != bb { return aa.localizedStandardCompare(bb) == .orderedAscending }
                if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            case .album:
                let aa = a.albumTitle ?? "", bb = b.albumTitle ?? ""
                if aa != bb { return aa.localizedStandardCompare(bb) == .orderedAscending }
                if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            case .duration:
                if a.duration != b.duration { return a.duration < b.duration }
                if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            case .recentlyAdded:
                let aa = a.dateAdded ?? .distantPast, bb = b.dateAdded ?? .distantPast
                if aa != bb { return aa > bb } // newest first; nil dates sink last
                if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            case .recentlyPlayed:
                let aa = a.lastPlayedDate ?? .distantPast, bb = b.lastPlayedDate ?? .distantPast
                if aa != bb { return aa > bb }
                if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            case .difficulty:
                let sa = records[a.persistentID]?.difficultyScore ?? -1
                let sb = records[b.persistentID]?.difficultyScore ?? -1
                if sa != sb { return sa > sb } // hardest first; unanalyzed sink last
                if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            }
            return a.persistentID < b.persistentID
        }
    }

    /// Full pipeline: search → filter → sort, in one deterministic pass.
    static func apply(_ songs: [LibrarySong],
                      searchText: String,
                      sort: LibrarySortOption,
                      filters: LibraryFilters,
                      records: [UInt64: SongRecordSnapshot]) -> [LibrarySong] {
        let searched = search(songs, text: searchText)
        let filtered = filter(searched,
                              analysis: filters.analysis,
                              availability: filters.availability,
                              difficultyRange: filters.difficultyRange,
                              records: records)
        return sorted(filtered, by: sort, records: records)
    }
}