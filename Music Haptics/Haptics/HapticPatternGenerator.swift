import CoreHaptics
import Foundation

/// Haptic profiles the user can choose from. Each profile defines how strong
/// and how present every category of feedback is — note hits, Perfects,
/// holds, chords, beats, accents and section changes — so the feel of the
/// game can be tuned without touching gameplay.
enum HapticProfileID: String, Codable, CaseIterable, Identifiable, Sendable {
    case minimal
    case musical
    case strong
    case beatFocused

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .musical: return "Musical"
        case .strong: return "Strong"
        case .beatFocused: return "Beat Focused"
        }
    }

    var blurb: String {
        switch self {
        case .minimal: return "Quiet taps only — no beats, accents or section ticks."
        case .musical: return "Balanced taps with subtle beat, accent and section feedback."
        case .strong: return "Firm everything — crisp double-tap Perfects, bold beats."
        case .beatFocused: return "Light taps, prominent rhythm — beats and accents lead."
        }
    }
}

/// Intensity/sharpness pair for one haptic kind. Init takes Doubles so
/// profile definitions read naturally.
struct NoteHaptics: Equatable, Sendable {
    let intensity: Float
    let sharpness: Float

    init(_ intensity: Double, _ sharpness: Double) {
        self.intensity = Float(intensity)
        self.sharpness = Float(sharpness)
    }
}

/// The concrete parameters of one profile. All values are pre-baked (no
/// runtime randomness), so identical settings always produce identical haptics.
struct HapticProfile: Equatable, Sendable {
    let id: HapticProfileID

    /// Per-judgment intensity/sharpness for note hits.
    let note: [Judgment: NoteHaptics]
    /// Perfects get a crisp double-tap (minimal/beat-focused stay single).
    let perfectDoubleTap: Bool
    let holdStart: NoteHaptics
    let holdEnd: NoteHaptics
    /// Chord voices get a single firmer pulse (first voice only).
    let chord: NoteHaptics
    /// Beat feedback intensities; 0 = profile has no beat haptics.
    let beatWeak: Float
    let beatStrong: Float
    /// Strong-accent tick; 0 = none.
    let accent: Float
    /// Section-change tick; 0 = none.
    let sectionChange: Float
    /// Minimum gap between haptic events (ms) — the global anti-stack guard.
    let minIntervalMs: Double

    func noteParameters(for judgment: Judgment) -> NoteHaptics {
        note[judgment] ?? NoteHaptics(0.2, 0.3)
    }
}

enum HapticProfileStore {
    static func profile(for id: HapticProfileID) -> HapticProfile {
        switch id {
        case .minimal:
            return HapticProfile(
                id: .minimal,
                note: [.perfect: NoteHaptics(0.30, 0.6), .great: NoteHaptics(0.22, 0.45), .good: NoteHaptics(0.15, 0.3), .miss: NoteHaptics(0.06, 0.15)],
                perfectDoubleTap: false,
                holdStart: NoteHaptics(0.18, 0.35), holdEnd: NoteHaptics(0.35, 0.55),
                chord: NoteHaptics(0.28, 0.5),
                beatWeak: 0, beatStrong: 0,
                accent: 0, sectionChange: 0,
                minIntervalMs: 70)
        case .musical:
            return HapticProfile(
                id: .musical,
                note: [.perfect: NoteHaptics(0.65, 0.8), .great: NoteHaptics(0.45, 0.6), .good: NoteHaptics(0.28, 0.35), .miss: NoteHaptics(0.10, 0.2)],
                perfectDoubleTap: true,
                holdStart: NoteHaptics(0.30, 0.45), holdEnd: NoteHaptics(0.55, 0.7),
                chord: NoteHaptics(0.6, 0.65),
                beatWeak: 0.16, beatStrong: 0.32,
                accent: 0.25, sectionChange: 0.2,
                minIntervalMs: 35)
        case .strong:
            return HapticProfile(
                id: .strong,
                note: [.perfect: NoteHaptics(1.0, 0.9), .great: NoteHaptics(0.75, 0.7), .good: NoteHaptics(0.45, 0.45), .miss: NoteHaptics(0.15, 0.25)],
                perfectDoubleTap: true,
                holdStart: NoteHaptics(0.5, 0.6), holdEnd: NoteHaptics(0.85, 0.8),
                chord: NoteHaptics(0.95, 0.75),
                beatWeak: 0.3, beatStrong: 0.5,
                accent: 0.45, sectionChange: 0.35,
                minIntervalMs: 25)
        case .beatFocused:
            return HapticProfile(
                id: .beatFocused,
                note: [.perfect: NoteHaptics(0.45, 0.7), .great: NoteHaptics(0.32, 0.5), .good: NoteHaptics(0.2, 0.3), .miss: NoteHaptics(0.08, 0.15)],
                perfectDoubleTap: false,
                holdStart: NoteHaptics(0.25, 0.4), holdEnd: NoteHaptics(0.5, 0.65),
                chord: NoteHaptics(0.45, 0.6),
                beatWeak: 0.38, beatStrong: 0.68,
                accent: 0.5, sectionChange: 0.3,
                minIntervalMs: 30)
        }
    }
}

/// Builds haptic patterns for gameplay events. Pure logic — unit-testable.
/// Every function returns nil when the master switch is off or the profile
/// disables that category (intensity 0), so nothing here can ever generate an
/// unwanted event.
enum HapticPatternGenerator {

    /// Pattern for a hit. Perfects may get a crisp double-tap per profile;
    /// misses are a soft tick (suppressed entirely in reduced mode).
    static func pattern(for judgment: Judgment, noteStrength: Double,
                        profile: HapticProfile,
                        enabled: Bool, strengthScale: Double, reduced: Bool) -> CHHapticPattern? {
        guard enabled else { return nil }
        if judgment == .miss && reduced { return nil }
        let haptics = profile.noteParameters(for: judgment)
        var scale = strengthScale * (reduced ? 0.4 : 1.0)
        if judgment == .miss { scale *= 0.5 }
        let intensity = min(1, max(0, haptics.intensity * Float(scale) * Float(0.5 + 0.5 * noteStrength)))
        let sharpness = haptics.sharpness

        var events: [CHHapticEvent] = []
        events.append(CHHapticEvent(eventType: .hapticTransient,
                                    parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                                 CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)],
                                    relativeTime: 0))
        if judgment == .perfect && profile.perfectDoubleTap {
            events.append(CHHapticEvent(eventType: .hapticTransient,
                                        parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity * 0.8),
                                                     CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)],
                                        relativeTime: 0.035))
        }
        return try? CHHapticPattern(events: events, parameters: [])
    }

    /// Chord hits: one firm pulse on the first voice (never per-voice).
    static func chordPattern(profile: HapticProfile,
                             enabled: Bool, strengthScale: Double, reduced: Bool) -> CHHapticPattern? {
        guard enabled else { return nil }
        let scale = Float(strengthScale * (reduced ? 0.4 : 1.0))
        let intensity = min(1, max(0, profile.chord.intensity * scale))
        let event = CHHapticEvent(eventType: .hapticTransient,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                               CHHapticEventParameter(parameterID: .hapticSharpness, value: profile.chord.sharpness)],
                                  relativeTime: 0)
        return try? CHHapticPattern(events: [event], parameters: [])
    }

    /// Light tick when a hold head is hit and sustaining begins.
    static func holdStartPattern(profile: HapticProfile,
                                 enabled: Bool, strengthScale: Double) -> CHHapticPattern? {
        guard enabled else { return nil }
        let intensity = Float(min(0.9, Double(profile.holdStart.intensity) * strengthScale))
        let event = CHHapticEvent(eventType: .hapticTransient,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                               CHHapticEventParameter(parameterID: .hapticSharpness, value: profile.holdStart.sharpness)],
                                  relativeTime: 0)
        return try? CHHapticPattern(events: [event], parameters: [])
    }

    /// Firm double-pulse when a hold is sustained all the way to its tail.
    static func holdEndPattern(profile: HapticProfile,
                               enabled: Bool, strengthScale: Double) -> CHHapticPattern? {
        guard enabled else { return nil }
        let intensity = Float(min(1.0, Double(profile.holdEnd.intensity) * strengthScale))
        let events = [
            CHHapticEvent(eventType: .hapticTransient,
                          parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                       CHHapticEventParameter(parameterID: .hapticSharpness, value: profile.holdEnd.sharpness)],
                          relativeTime: 0),
            CHHapticEvent(eventType: .hapticTransient,
                          parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity * 0.7),
                                       CHHapticEventParameter(parameterID: .hapticSharpness, value: profile.holdEnd.sharpness * 0.9)],
                          relativeTime: 0.04),
        ]
        return try? CHHapticPattern(events: events, parameters: [])
    }

    /// Pulse for a musical beat. Returns nil when the profile disables beat
    /// haptics (beat intensities of 0) or the master switch is off.
    static func beatPattern(strength: Double, isStrong: Bool,
                            profile: HapticProfile, strengthScale: Double) -> CHHapticPattern? {
        let base = isStrong ? profile.beatStrong : profile.beatWeak
        guard base > 0 else { return nil }
        let intensity = Float(min(1.0, max(0.05, strength * Double(base) * strengthScale)))
        let event = CHHapticEvent(eventType: .hapticTransient,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                               CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
                                  relativeTime: 0)
        return try? CHHapticPattern(events: [event], parameters: [])
    }

    /// Tick on a strong musical accent. nil when the profile disables it.
    static func accentPattern(profile: HapticProfile, strengthScale: Double) -> CHHapticPattern? {
        guard profile.accent > 0 else { return nil }
        let intensity = Float(min(1.0, Double(profile.accent) * strengthScale))
        let event = CHHapticEvent(eventType: .hapticTransient,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                               CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.55)],
                                  relativeTime: 0)
        return try? CHHapticPattern(events: [event], parameters: [])
    }

    /// Tick when the music crosses into a new section. nil when disabled.
    static func sectionChangePattern(profile: HapticProfile, strengthScale: Double) -> CHHapticPattern? {
        guard profile.sectionChange > 0 else { return nil }
        let intensity = Float(min(1.0, Double(profile.sectionChange) * strengthScale))
        let event = CHHapticEvent(eventType: .hapticTransient,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                               CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)],
                                  relativeTime: 0)
        return try? CHHapticPattern(events: [event], parameters: [])
    }
}

/// Pure anti-stack guard: a haptic may only fire when the minimum interval
/// since the last one has elapsed. Shared by note haptics and the scheduler,
/// so profiles keep the device from buzzing on dense passages.
struct HapticCooldown: Sendable {
    let minIntervalMs: Double
    private(set) var lastFireUptime: Double = -1_000

    init(minIntervalMs: Double) {
        self.minIntervalMs = max(0, minIntervalMs)
    }

    /// True when a fire at `nowUptime` is allowed; advances the last-fire time
    /// only when allowed (callers pass a monotonic uptime clock).
    mutating func allowFire(at nowUptime: Double) -> Bool {
        guard nowUptime - lastFireUptime >= minIntervalMs / 1000 else { return false }
        lastFireUptime = nowUptime
        return true
    }

    mutating func reset() {
        lastFireUptime = -1_000
    }
}