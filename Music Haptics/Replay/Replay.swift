import Foundation

/// What a replay event represents on the chart timeline.
enum ReplayEventKind: String, Codable, Sendable, CaseIterable {
    /// A regular tap note was judged (head tap of a hold uses `.holdStart`).
    case note
    /// A hold's head was hit (judgment = head quality).
    case holdStart
    /// A hold was sustained to its tail (timingErrorMs = release vs. tail).
    case holdComplete
    /// A hold was released before its tail.
    case holdRelease
    /// A hold head was never touched and its window passed.
    case holdMiss
}

/// One compact gameplay event. Everything is relative to the CHART timeline
/// (the authoritative audio clock during the run), so replaying is
/// deterministic: events are re-injected at `time` as the clock advances.
struct ReplayEvent: Codable, Equatable, Sendable {
    let kind: ReplayEventKind
    let noteID: Int
    let lane: Int
    /// Seconds on the chart/audio timeline.
    let time: Double
    /// Judgment quality. nil only for `.holdComplete` (a bonus event, not a
    /// judgment); failed holds carry `.miss`; note/holdStart carry the real
    /// quality.
    let judgment: Judgment?
    /// Measured timing error in ms (tap + calibration − note time; vs. the
    /// tail for hold lifecycle events).
    let timingErrorMs: Double
    let score: Int
    let combo: Int
}

/// A saved replay: versioned envelope + events + the identity needed to
/// rebuild the session (song, difficulty, chart version).
struct ReplayFile: Codable, Identifiable, Equatable, Sendable {
    /// Bump when the event schema changes; older files are refused, never
    /// misread.
    static let currentVersion = 1

    var version: Int
    var id: UUID
    var songID: UUID
    var songTitle: String
    var difficulty: DifficultyLevel
    var chartVersion: Int
    /// The audio URL the run used (sandbox copy for imports, `ipod-library://`
    /// for library songs). Optional: if it no longer resolves, the replay can
    /// still be watched on a fallback clock.
    var audioURL: URL?
    var createdAt: Date
    var duration: Double
    var noteCount: Int
    /// Sorted deterministically (time, then noteID) at build time.
    var events: [ReplayEvent]

    var isCurrentVersion: Bool { version == Self.currentVersion }
}

/// Everything a finished run hands to the results screen so it can save a
/// replay (song identity + the engine's compact event recording).
struct ReplayContext {
    let songID: UUID
    let songTitle: String
    let difficulty: DifficultyLevel
    let chartVersion: Int
    let audioURL: URL?
    let duration: Double
    let noteCount: Int
    let events: [ReplayEvent]
}

/// Pure builder: turns engine-recorded events into a deterministic ReplayFile.
/// Sorting/normalization live here so the engine never worries about order.
enum ReplayBuilder {
    /// Builds a replay, normalizing event order deterministically. Events are
    /// sorted by (time, noteID, kind rank); duplicates are dropped by
    /// (time, noteID, kind) so re-recorded judgments can't corrupt playback.
    static func make(songID: UUID, songTitle: String, difficulty: DifficultyLevel,
                     chartVersion: Int, audioURL: URL?, duration: Double,
                     noteCount: Int, events: [ReplayEvent],
                     createdAt: Date = Date(), id: UUID = UUID()) -> ReplayFile {
        let kindRank: [ReplayEventKind: Int] = [
            .note: 0, .holdStart: 1, .holdComplete: 2, .holdRelease: 3, .holdMiss: 4,
        ]
        var seen = Set<String>()
        let sorted = events.sorted { a, b in
            if a.time != b.time { return a.time < b.time }
            if a.noteID != b.noteID { return a.noteID < b.noteID }
            return (kindRank[a.kind] ?? 0) < (kindRank[b.kind] ?? 0)
        }.filter { event in
            let key = "\(event.time)|\(event.noteID)|\(event.kind.rawValue)"
            return seen.insert(key).inserted
        }
        return ReplayFile(version: ReplayFile.currentVersion,
                          id: id,
                          songID: songID,
                          songTitle: songTitle,
                          difficulty: difficulty,
                          chartVersion: chartVersion,
                          audioURL: audioURL,
                          createdAt: createdAt,
                          duration: duration,
                          noteCount: noteCount,
                          events: sorted)
    }

    /// True when this replay belongs to the given chart (same song +
    /// difficulty + chart version). The chart must match exactly — a replay
    /// for an older chart version is never played on a newer one.
    static func matches(_ replay: ReplayFile, chart: Chart) -> Bool {
        replay.songID == chart.songID
            && replay.difficulty == chart.difficulty
            && replay.chartVersion == chart.chartVersion
    }
}