import Foundation

enum ChartNoteType: String, Codable, Sendable {
    case tap
    case hold   // sustained note; duration > 0
}

/// One playable note. `lane` is 0…3 (four lanes).
struct ChartNote: Codable, Sendable, Identifiable, Equatable {
    var id: Int
    var time: Double
    var lane: Int
    var duration: Double      // 0 for taps; holds arrive later
    var type: ChartNoteType
    var strength: Double      // 0…1, drives haptic/visual intensity
}

/// A validated, playable chart for one song at one difficulty.
struct Chart: Codable, Sendable {
    var songID: UUID
    var difficulty: DifficultyLevel
    var chartVersion: Int
    var seed: UInt64
    var notes: [ChartNote]
    var generatedAt: Date
    var nps: Double
    var duration: Double
    var difficultyScore: Double
    var validationWarnings: [String]
    var generationDuration: Double

    // AI-assisted generation metadata (nil = deterministic-only generation).
    // Optional so charts persisted before AI support decode unchanged.
    var aiDifficultyScore: Double?
    var aiDifficultyConfidence: Double?
    var deterministicDifficultyScore: Double?
    var aiModelVersion: Int?

    /// Musical/playability quality score (0–10) used to choose among the
    /// deterministic candidate charts (v4+). Optional for decode compat.
    var qualityScore: Double?

    /// Notes dropped by the playability validator's repair pass (v4+).
    var repairCount: Int?

    /// Generation tier: 1 = full phrase-pattern pipeline, 2 = relaxed
    /// constraints retry, 3 = legacy per-cell selection, 4 = minimal
    /// deterministic grid. 1 when the field predates tiers (decode compat).
    var fallbackTier: Int?
    /// Notes are always stored sorted by time.
    var lastNoteTime: Double { notes.last?.time ?? 0 }

    /// Returns a sanitized copy: every note is finite, lane 0…3, time in
    /// [0, songDuration], non-negative duration, hold-consistent type, unique
    /// sequential ids, sorted by time. Notes that cannot be repaired (NaN /
    /// infinity / invalid lane / negative or beyond-song time) are DROPPED —
    /// malformed data must never reach gameplay. Chart-level fields are
    /// copied as-is (they are generator-computed and versioned).
    func sanitized(songDuration: Double) -> Chart {
        let maxTime = songDuration.isFinite && songDuration > 0 ? songDuration : .infinity
        var kept: [ChartNote] = []
        kept.reserveCapacity(notes.count)
        for note in notes {
            guard note.time.isFinite, note.duration.isFinite, note.strength.isFinite,
                  note.time >= 0, note.time <= maxTime,
                  note.duration >= 0, (0..<4).contains(note.lane) else { continue }
            var fixed = note
            if fixed.type == .hold && fixed.duration <= 0 { fixed.type = .tap }
            if fixed.type == .tap { fixed.duration = 0 }
            fixed.strength = min(1, max(0, fixed.strength))
            kept.append(fixed)
        }
        kept.sort { $0.time < $1.time }
        for i in kept.indices { kept[i].id = i }
        var copy = self
        copy.notes = kept
        copy.duration = maxTime.isFinite ? maxTime : copy.duration
        return copy
    }
}