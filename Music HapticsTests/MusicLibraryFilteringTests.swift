import XCTest
@testable import Music_Haptics

/// Deterministic tests for the cached-library search / sort / filter pipeline.
/// Uses snapshot `LibrarySong`s (no MPMediaItem needed).
final class MusicLibraryFilteringTests: XCTestCase {

    // MARK: - Fixtures

    private func song(_ id: UInt64, _ title: String, artist: String = "Artist A",
                      album: String? = "Album X", duration: TimeInterval = 200,
                      accessible: Bool = true, dateAdded: Date? = nil,
                      lastPlayed: Date? = nil) -> LibrarySong {
        LibrarySong(persistentID: id, title: title, artist: artist, albumTitle: album,
                    duration: duration, isCloudOnly: !accessible && dateAdded == nil,
                    hasProtectedAsset: !accessible, assetURL: accessible ? URL(string: "ipod-library://item/item\(id).mp3") : nil,
                    dateAdded: dateAdded, lastPlayedDate: lastPlayed)
    }

    private func record(_ id: UInt64, ready: Bool = true, level: DifficultyLevel = .medium,
                        score: Double = 5.0) -> SongRecordSnapshot {
        SongRecordSnapshot(persistentID: id, isChartReady: ready,
                           difficultyLevel: level, difficultyScore: score)
    }

    private let d1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let d2 = Date(timeIntervalSince1970: 1_700_100_000)
    private let d3 = Date(timeIntervalSince1970: 1_700_200_000)

    private var songs: [LibrarySong] {
        [
            song(1, "Zebra", artist: "Miles", album: "Vol 2", duration: 300, accessible: false, dateAdded: d1),
            song(2, "Alpha", artist: "Aaron", album: "Vol 1", duration: 100, dateAdded: d3),
            song(3, "Midnight", artist: "Zoe", album: "Vol 1", duration: 200, dateAdded: d2, lastPlayed: d1),
            song(4, "Delta", artist: "Miles", album: "Vol 2", duration: 150, lastPlayed: d3),
        ]
    }

    private var records: [UInt64: SongRecordSnapshot] {
        [1: record(1, ready: false, score: 2.0),
         2: record(2, ready: true, score: 8.4),
         3: record(3, ready: true, score: 5.0)]
    }

    // MARK: - Search

    func testSearchMatchesTitle() {
        XCTAssertEqual(MusicLibraryFiltering.search(songs, text: "mid").map(\.title), ["Midnight"])
    }

    func testSearchMatchesArtistAndAlbum() {
        XCTAssertEqual(MusicLibraryFiltering.search(songs, text: "Miles").map(\.title).sorted(), ["Delta", "Zebra"])
        XCTAssertEqual(MusicLibraryFiltering.search(songs, text: "vol 2").map(\.title).sorted(), ["Delta", "Zebra"])
    }

    func testSearchIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(MusicLibraryFiltering.search(songs, text: "  ALPHA ").map(\.title), ["Alpha"])
    }

    func testEmptySearchReturnsAllInOriginalOrder() {
        XCTAssertEqual(MusicLibraryFiltering.search(songs, text: "   ").count, 4)
        XCTAssertEqual(MusicLibraryFiltering.search(songs, text: "").map(\.persistentID), [1, 2, 3, 4])
    }

    // MARK: - Group search

    func testAlbumSearchMatchesAlbumTitleAndMemberSong() {
        let groups = [
            MusicLibraryFiltering.AlbumGroupShell(title: "Greatest Hits", artist: "X", songs: [song(10, "Bohemian")]),
            MusicLibraryFiltering.AlbumGroupShell(title: "Live", artist: "Y", songs: [song(11, "Rhapsody")]),
        ]
        XCTAssertEqual(MusicLibraryFiltering.searchAlbums(groups, text: "rhap").map(\.title), ["Live"])
        XCTAssertEqual(MusicLibraryFiltering.searchAlbums(groups, text: "greatest").map(\.title), ["Greatest Hits"])
        XCTAssertEqual(MusicLibraryFiltering.searchAlbums(groups, text: "zzz").count, 0)
    }

    func testArtistSearchMatchesNameAndMemberSong() {
        let groups = [
            MusicLibraryFiltering.ArtistGroupShell(name: "Adele", songs: [song(10, "Hello")]),
            MusicLibraryFiltering.ArtistGroupShell(name: "Beyonce", songs: [song(11, "Halo")]),
        ]
        XCTAssertEqual(MusicLibraryFiltering.searchArtists(groups, text: "halo").map(\.name), ["Beyonce"])
        XCTAssertEqual(MusicLibraryFiltering.searchArtists(groups, text: "ADELE").map(\.name), ["Adele"])
    }

    // MARK: - Filters

    func testAvailabilityFilter() {
        var f = LibraryFilters()
        f.availability = .accessible
        XCTAssertEqual(MusicLibraryFiltering.filter(songs, analysis: .all, availability: .accessible,
                                                    difficultyRange: nil, records: records).map(\.persistentID), [2, 3, 4])
        f.availability = .unavailable
        XCTAssertEqual(MusicLibraryFiltering.filter(songs, analysis: .all, availability: .unavailable,
                                                    difficultyRange: nil, records: records).map(\.persistentID), [1])
    }

    func testAnalysisFilter() {
        XCTAssertEqual(MusicLibraryFiltering.filter(songs, analysis: .analyzed, availability: .all,
                                                    difficultyRange: nil, records: records).map(\.persistentID), [1, 2, 3])
        XCTAssertEqual(MusicLibraryFiltering.filter(songs, analysis: .notAnalyzed, availability: .all,
                                                    difficultyRange: nil, records: records).map(\.persistentID), [4])
        XCTAssertEqual(MusicLibraryFiltering.filter(songs, analysis: .chartReady, availability: .all,
                                                    difficultyRange: nil, records: records).map(\.persistentID), [2, 3])
    }

    func testDifficultyRangeFilter() {
        XCTAssertEqual(MusicLibraryFiltering.filter(songs, analysis: .all, availability: .all,
                                                    difficultyRange: 8...10, records: records).map(\.persistentID), [2])
        // 5.0 floors to 5 — included in 5...5; the unanalyzed song 4 has no score.
        XCTAssertEqual(MusicLibraryFiltering.filter(songs, analysis: .all, availability: .all,
                                                    difficultyRange: 5...5, records: records).map(\.persistentID), [3])
        XCTAssertEqual(MusicLibraryFiltering.filter(songs, analysis: .all, availability: .all,
                                                    difficultyRange: 9...10, records: records).count, 0)
    }

    func testCombinedFilters() {
        var f = LibraryFilters()
        f.availability = .accessible
        f.analysis = .chartReady
        f.difficultyRange = 5...10
        let result = MusicLibraryFiltering.apply(songs, searchText: "", sort: .title,
                                                 filters: f, records: records)
        XCTAssertEqual(result.map(\.persistentID), [2, 3]) // accessible + ready + score ≥ 5
    }

    // MARK: - Sorting

    func testSortByTitleAndArtistAndAlbum() {
        XCTAssertEqual(MusicLibraryFiltering.sorted(songs, by: .title, records: records).map(\.title),
                       ["Alpha", "Delta", "Midnight", "Zebra"])
        XCTAssertEqual(MusicLibraryFiltering.sorted(songs, by: .artist, records: records).map(\.artist),
                       ["Aaron", "Miles", "Miles", "Zoe"])
        XCTAssertEqual(MusicLibraryFiltering.sorted(songs, by: .album, records: records).map(\.albumTitle),
                       ["Vol 1", "Vol 1", "Vol 2", "Vol 2"])
    }

    func testSortByDurationAscending() {
        XCTAssertEqual(MusicLibraryFiltering.sorted(songs, by: .duration, records: records).map(\.persistentID),
                       [2, 4, 3, 1])
    }

    func testSortByRecentlyAddedNewestFirstWithNilsLast() {
        XCTAssertEqual(MusicLibraryFiltering.sorted(songs, by: .recentlyAdded, records: records).map(\.persistentID),
                       [2, 3, 1, 4])
    }

    func testSortByRecentlyPlayed() {
        // Songs 1 and 2 were never played — nil sinks last, tie-broken by title.
        XCTAssertEqual(MusicLibraryFiltering.sorted(songs, by: .recentlyPlayed, records: records).map(\.persistentID),
                       [4, 3, 2, 1])
    }

    func testSortByDifficultyHardestFirstUnanalyzedLast() {
        XCTAssertEqual(MusicLibraryFiltering.sorted(songs, by: .difficulty, records: records).map(\.persistentID),
                       [2, 3, 1, 4])
    }

    func testSortIsStableOnTies() {
        let ties = [song(5, "Same", artist: "A"), song(6, "Same", artist: "B"), song(7, "Same", artist: "C")]
        XCTAssertEqual(MusicLibraryFiltering.sorted(ties, by: .title, records: [:]).map(\.persistentID),
                       [5, 6, 7])
    }

    // MARK: - Determinism

    func testPipelineIsDeterministic() {
        var f = LibraryFilters()
        f.analysis = .analyzed
        let a = MusicLibraryFiltering.apply(songs, searchText: "a", sort: .difficulty, filters: f, records: records)
        let b = MusicLibraryFiltering.apply(songs, searchText: "a", sort: .difficulty, filters: f, records: records)
        XCTAssertEqual(a.map(\.persistentID), b.map(\.persistentID))
    }

    func testEmptyInputs() {
        XCTAssertTrue(MusicLibraryFiltering.apply([], searchText: "x", sort: .title,
                                                  filters: LibraryFilters(), records: [:]).isEmpty)
    }

    /// A large cache (10k songs) must filter+sort correctly — the exact path
    /// the UI runs on every keystroke.
    func testLargeLibraryPerformancePath() {
        var big: [LibrarySong] = []
        var recs: [UInt64: SongRecordSnapshot] = [:]
        for i in 0..<10_000 {
            let id = UInt64(i)
            big.append(song(id, String(format: "Song %04d", 9_999 - i),
                            artist: "Artist \(i % 50)", album: "Album \(i % 20)",
                            duration: Double(60 + i % 300), accessible: i % 3 != 0))
            if i % 2 == 0 {
                recs[id] = record(id, ready: i % 4 == 0, score: Double(i % 11))
            }
        }
        var f = LibraryFilters()
        f.availability = .accessible
        f.analysis = .chartReady
        f.difficultyRange = 8...10
        let result = MusicLibraryFiltering.apply(big, searchText: "Song 0", sort: .duration, filters: f, records: recs)
        XCTAssertFalse(result.isEmpty)
        // Sorted ascending by duration.
        for i in 1..<result.count {
            XCTAssertLessThanOrEqual(result[i - 1].duration, result[i].duration)
        }
        // All results match the filters.
        for s in result {
            XCTAssertTrue(s.isAudioAccessible)
            XCTAssertTrue(recs[s.persistentID]!.isChartReady)
        }
    }
}