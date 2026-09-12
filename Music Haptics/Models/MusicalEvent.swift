import Foundation

/// A single detected beat.
struct Beat: Codable, Sendable, Equatable {
    var time: Double
    var strength: Double   // 0…1, relative prominence
    var isStrong: Bool     // accent-style beat (downbeat-ish)
}

/// A detected musical onset (attack).
struct OnsetEvent: Codable, Sendable, Equatable {
    var time: Double
    var strength: Float
    var confidence: Float
}

/// Approximate event classification. These are honest heuristics from spectral
/// band energy — not precise instrument identification.
enum MusicalEventType: String, Codable, Sendable {
    case kickLike
    case snareLike
    case percussive
    case melodic
    case beat
    case accent
}

/// Unified representation of a musically relevant moment.
struct MusicalEvent: Codable, Sendable, Equatable {
    var time: Double
    var strength: Double      // normalized onset strength
    var confidence: Double
    var type: MusicalEventType
    var lowEnergy: Double
    var midEnergy: Double
    var highEnergy: Double
    var isOnBeat: Bool
    var beatStrength: Double
    var sectionIndex: Int
    var importance: Double    // computed by the analyzer; drives chart selection
}

/// Broad song section with a heuristic label.
enum SectionLabel: String, Codable, Sendable {
    case intro, verse, chorus, bridge, breakdown, outro, generic

    var displayName: String { rawValue.capitalized }
}

struct SongSection: Codable, Sendable, Equatable {
    var index: Int
    var start: Double
    var end: Double
    var label: SectionLabel
    var energy: Double   // relative energy 0…1
}