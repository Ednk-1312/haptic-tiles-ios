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
    /// A hold being sustained: the finger is down past its head.
    struct Active: Sendable {
        let index: Int        // scheduler index
        let noteID: Int
        let lane: Int
        let startTime: Double // audio time the head was hit
        let endTime: Double   // audio time of the tail
    }

    /// Lane → hold currently being sustained.
    private(set) var active: [Int: Active] = [:]
    /// Note id → explicit lifecycle state.
    private(set) var stateByNote: [Int: HoldState] = [:]

    // MARK: - Transitions

    /// The head was hit and the finger is down: notStarted → active.
    @discardableResult
    mutating func start(lane: Int, index: Int, noteID: Int,
                        startTime: Double, endTime: Double) -> Active? {
        guard endTime > startTime else { return nil }
        let hold = Active(index: index, noteID: noteID, lane: lane,
                          startTime: startTime, endTime: endTime)
        active[lane] = hold
        stateByNote[noteID] = .active
        return hold
    }

    /// The finger came up. A release at (or within `grace` of) the tail
    /// completes; anything earlier is a releasedEarly miss. Returns the hold
    /// and whether it completed — removes it from the active set either way.
    @discardableResult
    mutating func release(lane: Int, at time: Double, grace: Double = 0.06)
        -> (hold: Active, completed: Bool)? {
        guard let hold = active.removeValue(forKey: lane) else { return nil }
        let completed = time >= hold.endTime - grace
        stateByNote[hold.noteID] = completed ? .completed : .releasedEarly
        return (hold, completed)
    }

    /// The finger is still down and the tail has arrived on the audio clock.
    mutating func complete(lane: Int) -> Active? {
        guard let hold = active.removeValue(forKey: lane) else { return nil }
        stateByNote[hold.noteID] = .completed
        return hold
    }

    /// A hold head was never touched and its time window passed: → missed.
    mutating func markMissed(noteID: Int) {
        guard stateByNote[noteID] == nil else { return }
        stateByNote[noteID] = .missed
    }

    /// Pause / restart / song change / practice jump: drop every active hold
    /// AND every recorded state. No hold state may survive a transition —
    /// a later run must not see yesterday's holds.
    mutating func cancelAll() {
        active.removeAll()
        stateByNote.removeAll()
    }

    // MARK: - Queries

    func state(for noteID: Int) -> HoldState {
        stateByNote[noteID] ?? .notStarted
    }

    func isActive(lane: Int) -> Bool {
        active[lane] != nil
    }

    /// 0…1 fraction of the hold consumed at `time` (active holds only).
    func progress(lane: Int, at time: Double) -> Double? {
        guard let hold = active[lane] else { return nil }
        let span = hold.endTime - hold.startTime
        guard span > 0 else { return 1 }
        return min(1, max(0, (time - hold.startTime) / span))
    }

    func activeHold(lane: Int) -> Active? {
        active[lane]
    }

    /// Every note id that has reached a terminal state (diagnostics).
    var terminalNoteIDs: [Int] {
        stateByNote.filter { $0.value == .completed || $0.value == .missed || $0.value == .releasedEarly }
            .map(\.key)
    }
}