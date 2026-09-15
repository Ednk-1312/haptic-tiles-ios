import Foundation

/// Lifecycle of one hold note. `notStarted` is the default (head not hit yet
/// and not yet missed); every other state is explicit so the UI and
/// diagnostics always know exactly where a hold is.
enum HoldState: String, Sendable, Equatable {
    case notStarted
    case active
    case completed
    case missed
    case releasedEarly

    var displayName: String {
        switch self {
        case .notStarted: return "Not Started"
        case .active: return "Active"
        case .completed: return "Completed"
        case .missed: return "Missed"
        case .releasedEarly: return "Released Early"
        }
    }
}

/// Tracks every hold's lifecycle for the engine. Pure value type — no audio,
/// no UI — so all states, transitions and progress math are deterministically
/// testable. One active hold per lane; `cancelAll` clears everything (pause,
/// restart, song change) so no stale hold state ever survives a transition.
struct HoldTracker: Sendable {
    /// A hold being sustained: the finger is down on the note.
    struct Active: Sendable {
        let index: Int
        let noteID: Int
        let lane: Int
        let startTime: Double
        let endTime: Double
    }

    /// Result of lifting a finger from a hold. Keeping the measured progress
    /// in the transition result is important: `release` removes the active
    /// entry, so asking the tracker for progress afterwards would otherwise
    /// always return nil/zero.
    struct ReleaseResult: Sendable {
        let hold: Active
        let completed: Bool
        let progress: Double
    }

    /// Release tolerance in the authoritative song timeline. This is a small
    /// usability grace at the musical tail, not an extension of the hold
    /// duration and not a change to note timing.
    static let releaseGrace: Double = 0.06

    private(set) var active: [Int: Active] = [:]
    private(set) var stateByNote: [Int: HoldState] = [:]
    private(set) var progressByNote: [Int: Double] = [:]

    // MARK: - Transitions

    /// Starts a hold only when its lane is free. A sustained finger cannot
    /// activate or replace a second hold further ahead in the same lane.
    @discardableResult
    mutating func start(lane: Int, index: Int, noteID: Int,
                        startTime: Double, endTime: Double) -> Active? {
        guard endTime > startTime, active[lane] == nil else { return nil }
        let hold = Active(index: index, noteID: noteID, lane: lane,
                          startTime: startTime, endTime: endTime)
        active[lane] = hold
        stateByNote[noteID] = .active
        progressByNote.removeValue(forKey: noteID)
        return hold
    }

    /// Releases the active hold and records its actual sustain fraction.
    @discardableResult
    mutating func release(lane: Int, at time: Double, grace: Double = HoldTracker.releaseGrace)
        -> ReleaseResult? {
        guard let hold = active.removeValue(forKey: lane) else { return nil }
        let sustained = progress(of: hold, at: time)
        let completed = time >= hold.endTime - grace
        let finalProgress = completed ? 1 : sustained
        stateByNote[hold.noteID] = completed ? .completed : .releasedEarly
        progressByNote[hold.noteID] = finalProgress
        return ReleaseResult(hold: hold, completed: completed, progress: finalProgress)
    }

    /// Completes the hold when the authoritative audio clock reaches its tail.
    mutating func complete(lane: Int) -> Active? {
        guard let hold = active.removeValue(forKey: lane) else { return nil }
        stateByNote[hold.noteID] = .completed
        progressByNote[hold.noteID] = 1
        return hold
    }

    /// Marks an untouched hold head as missed.
    mutating func markMissed(noteID: Int) {
        guard stateByNote[noteID] == nil else { return }
        stateByNote[noteID] = .missed
        progressByNote[noteID] = 0
    }

    /// Clears all state on pause/restart/song change.
    mutating func cancelAll() {
        active.removeAll()
        stateByNote.removeAll()
        progressByNote.removeAll()
    }

    // MARK: - Queries

    func state(for noteID: Int) -> HoldState {
        stateByNote[noteID] ?? .notStarted
    }

    func isActive(lane: Int) -> Bool {
        active[lane] != nil
    }

    func isActive(noteID: Int) -> Bool {
        active.values.contains { $0.noteID == noteID }
    }

    func activeHold(lane: Int) -> Active? {
        active[lane]
    }

    func activeHold(noteID: Int) -> Active? {
        active.values.first { $0.noteID == noteID }
    }

    /// 0…1 fraction of the active hold consumed at `time`.
    func progress(lane: Int, at time: Double) -> Double? {
        guard let hold = active[lane] else { return nil }
        return progress(of: hold, at: time)
    }

    /// Progress for an arbitrary active hold, based on authoritative time.
    func progress(of hold: Active, at time: Double) -> Double {
        let span = hold.endTime - hold.startTime
        guard span > 0 else { return 1 }
        return min(1, max(0, (time - hold.startTime) / span))
    }

    func recordedProgress(noteID: Int) -> Double? {
        progressByNote[noteID]
    }

    /// Every note id that has reached a terminal state (diagnostics).
    var terminalNoteIDs: [Int] {
        stateByNote
            .filter { $0.value == .completed || $0.value == .missed || $0.value == .releasedEarly }
            .map(\.key)
    }
}
