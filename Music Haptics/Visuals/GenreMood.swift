import Foundation

/// A song's emotional/genre family, resolved from metadata (media-library
/// genre strings, or an online lookup). Maps to a cohesive color family the
/// gameplay background blends into its wash — cool tones for sad/emotional
/// songs, warm for upbeat ones, dark high-contrast for rock/hip-hop, vivid
/// neon for dance/electronic, soft muted for chill.
///
/// Pure value type: no UIKit, fully deterministic, unit-testable on every
/// platform. The background applies the same readability lifting it applies
/// to artwork-extracted colors, so dark moods can never bury the notes.
enum GenreMood: String, CaseIterable, Sendable, Equatable {
    case sad
    case happy
    case dance
    case rock
    case hipHop
    case electronic
    case chill
    case neutral

    // MARK: - Resolution

    /// Keyword mapping over free-form genre strings ("Hip-Hop/Rap",
    /// "Alt. Dance", "Alternative Folk"). Order matters: specific, energetic
    /// families are checked before broad ones so "Dance Pop" lands on dance,
    /// not pop→happy. Unknown/nil/empty → neutral.
    static func resolve(from genre: String?) -> GenreMood {
        guard let genre, !genre.trimmingCharacters(in: .whitespaces).isEmpty else { return .neutral }
        let g = genre.lowercased()

        // Dance/party before electronic and pop: "Dance/EDM", "Club".
        if containsAny(g, "dance", "party", "club", "disco", "house", "techno", "trance", "dubstep") { return .dance }
        // Electronic family.
        if containsAny(g, "electronic", "electronica", "edm", "electro", "synth", "idm", "drum & bass", "drum and bass") { return .electronic }
        // Rock/metal family.
        if containsAny(g, "rock", "metal", "punk", "grunge", "hardcore", "emo") { return .rock }
        // Hip-hop family.
        if containsAny(g, "hip-hop", "hip hop", "hiphop", "rap", "trap", "grime", "drill", "r&b", "rhythm & blues") { return .hipHop }
        // Chill/ambient family.
        if containsAny(g, "chill", "ambient", "lo-fi", "lofi", "lounge", "downtempo", "new age", "sleep", "meditation", "acoustic", "folk") { return .chill }
        // Sad/emotional family. Blues and classical read as cool/emotional.
        if containsAny(g, "sad", "blues", "classical", "classique", "orchestral", "piano", "ballad", "singer/songwriter") { return .sad }
        // Happy/upbeat family (pop last — "Dance Pop" already matched above).
        if containsAny(g, "happy", "pop", "upbeat", "funk", "soul", "reggae", "ska", "country") { return .happy }
        return .neutral
    }

    private static func containsAny(_ haystack: String, _ needles: String...) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    // MARK: - Palette

    /// Gradient top color (0…1 RGB, pre-lift — the background lifts luma for
    /// readability exactly as it does for artwork colors).
    var top: RGB {
        switch self {
        case .sad:        return RGB(0.14, 0.20, 0.46)   // deep indigo-blue
        case .happy:      return RGB(0.98, 0.55, 0.18)   // warm amber
        case .dance:      return RGB(0.55, 0.16, 0.85)   // vivid violet
        case .rock:       return RGB(0.42, 0.10, 0.10)   // dark crimson
        case .hipHop:     return RGB(0.16, 0.16, 0.20)   // near-black slate
        case .electronic: return RGB(0.08, 0.35, 0.62)   // neon deep cyan
        case .chill:      return RGB(0.22, 0.42, 0.40)   // soft sage-teal
        case .neutral:    return RGB(0.14, 0.20, 0.34)   // deep slate-blue
        }
    }

    /// Gradient bottom color.
    var bottom: RGB {
        switch self {
        case .sad:        return RGB(0.30, 0.14, 0.42)   // dusky violet
        case .happy:      return RGB(1.00, 0.78, 0.28)   // golden
        case .dance:      return RGB(0.92, 0.22, 0.62)   // hot magenta
        case .rock:       return RGB(0.72, 0.26, 0.08)   // burnt orange
        case .hipHop:     return RGB(0.30, 0.12, 0.34)   // dark plum
        case .electronic: return RGB(0.30, 0.12, 0.66)   // electric violet
        case .chill:      return RGB(0.40, 0.52, 0.46)   // muted sage
        case .neutral:    return RGB(0.30, 0.24, 0.44)   // muted violet-slate
        }
    }

    /// Accent for ambience glows — high contrast against the mood wash.
    var accent: RGB {
        switch self {
        case .sad:        return RGB(0.45, 0.66, 1.00)   // moonlight blue
        case .happy:      return RGB(1.00, 0.90, 0.55)   // sunlight
        case .dance:      return RGB(0.35, 1.00, 0.90)   // aqua neon
        case .rock:       return RGB(1.00, 0.45, 0.25)   // ember
        case .hipHop:     return RGB(1.00, 0.80, 0.35)   // gold chain
        case .electronic: return RGB(0.30, 0.95, 1.00)   // cyan neon
        case .chill:      return RGB(0.75, 0.90, 0.80)   // pale mint
        case .neutral:    return RGB(0.65, 0.75, 1.00)   // soft periwinkle
        }
    }

    /// How strongly the mood tints the reference wash (0…1). Bold moods
    /// (rock/hip-hop/dance) tint harder; gentle ones sit back. The reference
    /// blue→purple/pink field always remains present underneath.
    var tintStrength: Double {
        switch self {
        case .sad:        return 0.30
        case .happy:      return 0.26
        case .dance:      return 0.34
        case .rock:       return 0.36
        case .hipHop:     return 0.34
        case .electronic: return 0.32
        case .chill:      return 0.28
        case .neutral:    return 0.22
        }
    }
}
