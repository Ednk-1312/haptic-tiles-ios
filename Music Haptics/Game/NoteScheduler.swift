import Foundation

/// Tracks which chart notes are still playable and answers window queries.
/// All queries are binary-search based, so a 60 Hz game loop stays cheap.
///
/// An optional `timeWindow` (practice sections) makes notes OUTSIDE the
/// window nonexistent: they never miss, never match a tap, never render, and
/// are skipped by autoplay — so jumping into a section plays only that
/// section's notes with no stale state.
@MainActor
final class NoteScheduler {
    // Workaround for swiftlang/swift#87316 (see StatsManager).
    deinit {}
    private let notes: [ChartNote]
    private var states: [NoteHitState]
    private let timeWindow: ClosedRange<Double>?
    private var windowStart = 0   // first index that can still be relevant

    init(chart: Chart, timeWindow: ClosedRange<Double>? = nil) {
        self.notes = chart.notes.sorted { $0.time < $1.time }
        self.states = Array(repeating: NoteHitState(judgment: nil), count: notes.count)
        self.timeWindow = timeWindow
        if let lower = timeWindow?.lowerBound {
            // Skip past notes that predate the window so they can never miss.
            while windowStart < notes.count && notes[windowStart].time < lower {
                windowStart += 1
            }
        }
    }

    /// Whether a note index lies inside the practice window (if any).
    func isActive(_ index: Int) -> Bool {
        guard notes.indices.contains(index) else { return false }
        guard let w = timeWindow else { return true }
        return notes[index].time >= w.lowerBound && notes[index].time <= w.upperBound
    }

    var count: Int { notes.count }
    var sortedNotes: [ChartNote] { notes }

    /// Notes with `time` in the given range (for rendering). Intersected with
    /// the practice window so out-of-section notes never render.
    func notes(in range: ClosedRange<Double>) -> [(index: Int, note: ChartNote)] {
        let lower: Double
        let upper: Double
        if let w = timeWindow {
            lower = max(range.lowerBound, w.lowerBound)
            upper = min(range.upperBound, w.upperBound)
            guard lower <= upper else { return [] }
        } else {
            lower = range.lowerBound
            upper = range.upperBound
        }
        var result: [(Int, ChartNote)] = []
        var i = lowerBound(of: lower)
        while i < notes.count && notes[i].time <= upper {
            result.append((i, notes[i]))
            i += 1
        }
        return result
    }

    /// Nearest unjudged note in a lane within the window; nil if none.
    func nearest(in lane: Int, to time: Double, window: Double) -> (index: Int, note: ChartNote, offset: Double)? {
        var best: (index: Int, offset: Double)?
        var i = lowerBound(of: time - window)
        while i < notes.count && notes[i].time <= time + window {
            if isActive(i), notes[i].lane == lane, states[i].judgment == nil {
                let offset = notes[i].time - time
                if best == nil || abs(offset) < abs(best!.offset) {
                    best = (i, offset)
                }
            }
            i += 1
        }
        guard let best else { return nil }
        return (best.index, notes[best.index], best.offset)
    }

    /// Nearest unjudged note per lane within the window (spatial catch uses
    /// this to judge each lane's own candidate against its own tile position
    /// instead of a global time-first winner). Returns up to four entries,
    /// keyed by lane; empty when nothing is eligible.
    func nearestPerLane(to time: Double, window: Double) -> [Int: (index: Int, note: ChartNote, offset: Double)] {
        var best: [Int: (index: Int, note: ChartNote, offset: Double)] = [:]
        var i = lowerBound(of: time - window)
        while i < notes.count && notes[i].time <= time + window {
            if isActive(i), states[i].judgment == nil {
                let lane = notes[i].lane
                let offset = notes[i].time - time
                if best[lane] == nil || abs(offset) < abs(best[lane]!.offset) {
                    best[lane] = (i, notes[i], offset)
                }
            }
            i += 1
        }
        return best
    }

    /// Indices of notes that passed beyond the miss window unjudged.
    func pendingMisses(before time: Double, window: Double) -> [Int] {
        var result: [Int] = []
        var i = windowStart
        while i < notes.count && notes[i].time < time - window {
            if let w = timeWindow, notes[i].time > w.upperBound { break }
            if states[i].judgment == nil { result.append(i) }
            windowStart = i + 1
            i += 1
        }
        return result
    }

    /// First unjudged note at or after `time` (used by the timing diagnostics
    /// countdown: how long until the next note crosses the hit line).
    func nextUnjudged(after time: Double) -> (index: Int, note: ChartNote)? {
        var i = lowerBound(of: time)
        while i < notes.count {
            if isActive(i), states[i].judgment == nil { return (i, notes[i]) }
            i += 1
        }
        return nil
    }

    /// Marks a note judged (judgment time unknown — used by test/utility
    /// paths that only need the state transition).
    func mark(_ index: Int, judgment: Judgment) {
        mark(index, judgment: judgment, at: nil)
    }

    /// Marks a note judged with the audio-clock time of the judgment, so the
    /// renderer can play the brief hit effect from the exact moment it
    /// happened.
    func mark(_ index: Int, judgment: Judgment, at time: Double?) {
        guard notes.indices.contains(index) else { return }
        states[index].judgment = judgment
        states[index].judgedAt = time
    }

    func judgment(for index: Int) -> Judgment? {
        guard notes.indices.contains(index) else { return nil }
        return states[index].judgment
    }

    /// Audio-clock time the note was judged (nil when unjudged or marked
    /// without a time).
    func judgmentTime(for index: Int) -> Double? {
        guard notes.indices.contains(index) else { return nil }
        return states[index].judgedAt
    }

    private func lowerBound(of time: Double) -> Int {
        // Scan from 0, NOT from `windowStart`: windowStart advances past
        // expired notes in pendingMisses, so a query seeded from it could
        // never see a just-missed (or late-hit) note — the renderer needs
        // judged notes visible for their brief hit/miss effects. Binary
        // search is O(log n) regardless of the starting hint.
        var lo = 0, hi = notes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if notes[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}