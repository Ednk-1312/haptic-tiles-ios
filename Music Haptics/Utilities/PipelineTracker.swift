import Foundation

/// A generation token bound to ONE song. Carries the song id so a token
/// captured for Song A can never pass validation against Song B — even when
/// two songs happen to share the same generation number (each song counts
/// its own runs from 1).
struct PipelineToken: Equatable, Sendable {
    let songID: UUID
    let generation: Int
}

/// Per-song pipeline generation tracker — the app's stale-task gate.
///
/// Every analysis / chart-generation / ensure-chart run captures a token; at
/// every mutation point it re-validates that the token is still the LATEST
/// run of ITS OWN song. A stale run (the song was re-analyzed, regenerated,
/// or its record was deleted while work was in flight) fails the check and
/// drops out without touching state.
///
/// Tokens are per song AND self-describing: work started for Song A can never
/// mutate Song B — mutations are keyed by song id and validated against the
/// token's own id plus B's counter. A user switching from A to B does not
/// invalidate A's run (it may still finish A's own record), but A's
/// completion can never write to B.
struct PipelineTracker: Sendable {
    private var counters: [UUID: Int] = [:]

    /// Starts a new run for `id` and returns its generation token.
    mutating func begin(for id: UUID) -> PipelineToken {
        let gen = (counters[id] ?? 0) + 1
        counters[id] = gen
        return PipelineToken(songID: id, generation: gen)
    }

    /// True only when `token` is the LATEST run for `id` — and the token was
    /// issued for `id` in the first place.
    ///
    /// Generation 0 means "no run has begun" (the value `current(for:)`
    /// reports for an unseen song). Such an observation token must validate
    /// while the counter is still absent or still zero — otherwise every
    /// ensure-chart call that runs before any pipeline of the session fails
    /// its currency check forever, exhausts its retries, and surfaces as a
    /// raw CancellationError (the "brief loading, then back home" bug).
    func isCurrent(_ token: PipelineToken, for id: UUID) -> Bool {
        guard token.songID == id else { return false }
        if token.generation == 0 {
            return (counters[id] ?? 0) == 0
        }
        return counters[id] == token.generation
    }

    /// Latest generation for `id` (0 when nothing has run). Used to build a
    /// read-only observation token before async work that must not outlive a
    /// newer run (e.g. `ensureChart`).
    func current(for id: UUID) -> Int {
        counters[id] ?? 0
    }

    /// Drops bookkeeping for removed songs (records deleted from the library).
    mutating func forget(for id: UUID) {
        counters[id] = nil
    }
}