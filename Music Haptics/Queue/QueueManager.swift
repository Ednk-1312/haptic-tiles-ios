import Foundation
import SwiftUI   // for IndexSet-based reordering

/// Repeat behavior for the queue.
enum QueueRepeatMode: String, Codable, Sendable, CaseIterable {
    case off
    case one
    case all

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .one: return "Repeat One"
        case .all: return "Repeat Queue"
        }
    }
}

/// One queued song. Each ENTRY has its own identity (`id`) — two entries may
/// point at the same song record (e.g. the same song at two difficulties) — so
/// all queue bookkeeping keys on `id`, never on `songID`.
struct QueueEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    /// Stable song record ID the entry plays.
    let songID: UUID
    /// Display metadata snapshot (the record may be re-fetched at play time).
    let title: String
    let artist: String
    /// Chart difficulty to play this entry at.
    var difficulty: DifficultyLevel?
    /// Background preparation state (pre-generation of chart/analysis).
    var status: QueueEntryStatus = .idle

    init(id: UUID = UUID(), songID: UUID, title: String, artist: String,
         difficulty: DifficultyLevel? = nil, status: QueueEntryStatus = .idle) {
        self.id = id
        self.songID = songID
        self.title = title
        self.artist = artist
        self.difficulty = difficulty
        self.status = status
    }

    /// User-facing "Up Next" helper.
    var displayName: String {
        if let difficulty {
            return "\(title) · \(difficulty.displayName)"
        }
        return title
    }

    /// Equality compares the song + difficulty + metadata, NOT the entry id:
    /// two entries for the same song at the same difficulty are "the same
    /// queue item" for decision comparisons, while all queue bookkeeping keys
    /// on the unique `id` (duplicates allowed).
    static func == (lhs: QueueEntry, rhs: QueueEntry) -> Bool {
        lhs.songID == rhs.songID
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.difficulty == rhs.difficulty
            && lhs.status == rhs.status
    }
}

enum QueueEntryStatus: String, Codable, Sendable {
    case idle
    case preparing
    case ready
    case error
}

/// What happens when the current song ends (or the player skips).
enum QueueAdvanceDecision: Sendable {
    case none                      // queue is empty / finished → show results
    case replayCurrent             // Repeat One
    case next(QueueEntry)          // play this entry
}

extension QueueAdvanceDecision: Equatable {
    static func == (lhs: QueueAdvanceDecision, rhs: QueueAdvanceDecision) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none), (.replayCurrent, .replayCurrent):
            return true
        case let (.next(a), .next(b)):
            return a == b
        default:
            return false
        }
    }
}

/// In-app queue: stable per-entry IDs, drag reorder, Play Next, shuffle,
/// repeat one/all, and automatic transition decisions. Pure state machine —
/// no audio, no SwiftData — so every behavior is deterministically testable.
///
/// Shuffle/random choices use an internal SplitMix64 (seeded at init), so a
/// queue session is fully reproducible given the seed.
@MainActor
@Observable
final class QueueManager {
    // Workaround for swiftlang/swift#87316 (see StatsManager).
    deinit {}
    private(set) var entries: [QueueEntry] = []
    /// Entry ID of the entry currently being played (nil = standalone play).
    private(set) var currentEntryID: UUID?
    private(set) var repeatMode: QueueRepeatMode = .off
    private(set) var shuffleEnabled = false
    /// Entries already played in this shuffle cycle (avoid repeats).
    private var playedIDs: Set<UUID> = []
    private var rng: SplitMix64
    /// Preparation token per ENTRY: bumping invalidates in-flight background
    /// preparation for that entry (removed / re-queued / advanced past).
    private var preparationToken: [UUID: Int] = [:]

    init(seed: UInt64? = nil, snapshot: QueueSnapshot? = nil) {
        rng = SplitMix64(state: seed ?? UInt64.random(in: .min ... .max))
        if let snapshot {
            restore(snapshot)
        }
    }

    // MARK: - Mutation (every mutation persists the queue)

    func add(_ entry: QueueEntry) {
        entries.append(entry)
        persist()
    }

    /// Appends several entries with a single persistence write (playlists).
    func add(_ newEntries: [QueueEntry]) {
        guard !newEntries.isEmpty else { return }
        entries.append(contentsOf: newEntries)
        persist()
    }

    /// Inserts right after the current entry (or at the front when nothing is
    /// playing) — "Play Next".
    func playNext(_ entry: QueueEntry) {
        if let currentEntryID, let idx = entries.firstIndex(where: { $0.id == currentEntryID }) {
            entries.insert(entry, at: min(idx + 1, entries.count))
        } else {
            entries.insert(entry, at: 0)
        }
        persist()
    }

    /// Removes ONE entry (identified by its own entry id).
    @discardableResult
    func remove(entryID: UUID) -> QueueEntry? {
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else { return nil }
        let removed = entries.remove(at: idx)
        playedIDs.remove(entryID)
        preparationToken[entryID] = (preparationToken[entryID] ?? 0) + 1
        if currentEntryID == entryID {
            currentEntryID = entries.indices.contains(idx) ? entries[idx].id : entries.last?.id
        }
        persist()
        return removed
    }

    /// Removes EVERY entry for a song record (song deleted from the app).
    func removeAll(songID: UUID) {
        let removedIDs = entries.filter { $0.songID == songID }.map(\.id)
        guard !removedIDs.isEmpty else { return }
        entries.removeAll { $0.songID == songID }
        for id in removedIDs {
            playedIDs.remove(id)
            preparationToken[id] = (preparationToken[id] ?? 0) + 1
        }
        if let currentEntryID, !entries.contains(where: { $0.id == currentEntryID }) {
            self.currentEntryID = entries.last?.id
        }
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        entries.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    func clear() {
        entries.removeAll()
        playedIDs.removeAll()
        currentEntryID = nil
        for id in preparationToken.keys {
            preparationToken[id] = (preparationToken[id] ?? 0) + 1
        }
        persist()
    }

    /// Marks an entry as the one currently playing.
    func setCurrent(entryID: UUID) {
        currentEntryID = entryID
        playedIDs.insert(entryID)
        persist()
    }

    func setRepeat(_ mode: QueueRepeatMode) {
        repeatMode = mode
        persist()
    }

    /// Toggles shuffle and resets the played-cycle so every entry can play
    /// before a repeat.
    func toggleShuffle() {
        shuffleEnabled.toggle()
        playedIDs.removeAll()
        if let currentEntryID { playedIDs.insert(currentEntryID) }
        persist()
    }

    /// Updates an entry's background-preparation status.
    func setStatus(_ status: QueueEntryStatus, for entryID: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[idx].status = status
    }

    var nowPlaying: QueueEntry? {
        currentEntryID.flatMap { id in entries.first { $0.id == id } }
    }

    var upNext: QueueEntry? {
        guard let now = nowPlaying, let idx = entries.firstIndex(where: { $0.id == now.id }) else {
            return entries.first
        }
        let nextIdx = idx + 1
        return entries.indices.contains(nextIdx) ? entries[nextIdx] : nil
    }

    /// Entry right after `entry` (for pre-generation of the next-next song).
    func upNext(for entry: QueueEntry) -> QueueEntry? {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return nil }
        let nextIdx = idx + 1
        return entries.indices.contains(nextIdx) ? entries[nextIdx] : nil
    }

    /// Decision when the current song NATURALLY FINISHES (Repeat One honored).
    func decisionAfterFinish() -> QueueAdvanceDecision {
        guard !entries.isEmpty else { return .none }
        if repeatMode == .one, nowPlaying != nil {
            return .replayCurrent
        }
        return nextDecision()
    }

    /// Decision when the player SKIPS (Repeat One does not trap the skip).
    func decisionAfterSkip() -> QueueAdvanceDecision {
        guard !entries.isEmpty else { return .none }
        return nextDecision()
    }

    /// Shared "what plays next" logic: shuffle picks a random unplayed entry;
    /// otherwise the next index after the current one (wrapping with Repeat
    /// All). Returns .none when the queue has no next playable entry.
    private func nextDecision() -> QueueAdvanceDecision {
        guard !entries.isEmpty else { return .none }
        if shuffleEnabled {
            let candidates = entries.filter { !playedIDs.contains($0.id) }
            if candidates.isEmpty {
                guard repeatMode == .all else { return .none }
                playedIDs.removeAll()
                if let currentEntryID { playedIDs.insert(currentEntryID) }
                return .next(randomEntry(from: entries))
            }
            let pick = randomEntry(from: candidates)
            playedIDs.insert(pick.id)
            currentEntryID = pick.id
            return .next(pick)
        }
        let currentIdx: Int
        if let currentEntryID, let idx = entries.firstIndex(where: { $0.id == currentEntryID }) {
            currentIdx = idx
        } else {
            currentIdx = -1   // nothing playing → start at the front
        }
        let nextIdx = currentIdx + 1
        if entries.indices.contains(nextIdx) {
            let next = entries[nextIdx]
            currentEntryID = next.id
            playedIDs.insert(next.id)
            return .next(next)
        }
        if repeatMode == .all {
            let first = entries[0]
            currentEntryID = first.id
            playedIDs.insert(first.id)
            return .next(first)
        }
        return .none
    }

    private func randomEntry(from list: [QueueEntry]) -> QueueEntry {
        let pick = Int(rng.next() % UInt64(list.count))
        return list[pick]
    }

    // MARK: - Preparation tokens (pre-generation cancellation)

    /// Token identifying the CURRENT preparation for an entry. Background
    /// tasks capture it and abandon their work (before mutating anything) once
    /// it no longer matches — i.e. the entry was removed or the queue advanced.
    /// Reading seeds the token so ANY later invalidation is observable.
    func preparationToken(for entryID: UUID) -> Int {
        if preparationToken[entryID] == nil {
            preparationToken[entryID] = 0
        }
        return preparationToken[entryID] ?? 0
    }

    func invalidatePreparation(entryID: UUID) {
        preparationToken[entryID] = (preparationToken[entryID] ?? 0) + 1
    }

    // MARK: - Persistence

    private func persist() {
        QueueStorage.save(snapshot())
    }

    func snapshot() -> QueueSnapshot {
        QueueSnapshot(entries: entries,
                      currentEntryID: currentEntryID,
                      repeatMode: repeatMode,
                      shuffleEnabled: shuffleEnabled)
    }

    private func restore(_ snapshot: QueueSnapshot) {
        entries = snapshot.entries.map {
            var entry = $0
            entry.status = .idle   // preparation status never survives relaunch
            return entry
        }
        currentEntryID = snapshot.currentEntryID
        repeatMode = snapshot.repeatMode
        shuffleEnabled = snapshot.shuffleEnabled
        if let currentEntryID { playedIDs.insert(currentEntryID) }
    }
}

/// Codable queue state for on-disk persistence. Entries whose song records no
/// longer exist are dropped by the app at restore time.
struct QueueSnapshot: Codable, Sendable {
    var entries: [QueueEntry]
    var currentEntryID: UUID?
    var repeatMode: QueueRepeatMode
    var shuffleEnabled: Bool
}

/// JSON persistence for the queue (application support, on-device).
enum QueueStorage {
    private static var url: URL {
        AppDirectories.documentsDirectory.appendingPathComponent("queue.json")
    }

    static func save(_ snapshot: QueueSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    static func load() -> QueueSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(QueueSnapshot.self, from: Data(contentsOf: url))
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}