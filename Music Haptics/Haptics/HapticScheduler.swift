import Foundation

/// Schedules rhythm haptics (beats, accents, section changes) on the audio
/// clock. Patterns are played at their EXACT chart time via the engine's
/// at-delay scheduling — never early, never late, best-effort. The profile
/// decides which categories exist and how strong they are; categories with
/// intensity 0 (e.g. Minimal) never produce patterns.
@MainActor
final class HapticScheduler {
    // Workaround for swiftlang/swift#87316 (see StatsManager).
    deinit {}
    private let haptics: HapticEngine
    private let profile: HapticProfile
    private let beats: [Beat]
    private let accents: [MusicalEvent]
    private let sections: [SongSection]
    private let strengthScale: Double

    private var nextBeatIndex = 0
    private var nextAccentIndex = 0
    private var nextSectionIndex = 0
    private var lastTime: Double = -1
    private var lookahead: Double

    init(haptics: HapticEngine, profile: HapticProfile, beats: [Beat],
         accents: [MusicalEvent], sections: [SongSection],
         strengthScale: Double = 1.0, lookahead: Double = 0.35) {
        self.haptics = haptics
        self.profile = profile
        self.beats = beats
        self.accents = accents
        self.sections = sections
        self.strengthScale = strengthScale
        self.lookahead = lookahead
    }

    func update(currentTime: Double) {
        // Detect seeks/jumps and resync.
        if lastTime < 0 || currentTime < lastTime - 0.05 || currentTime - lastTime > 1.5 {
            nextBeatIndex = 0
            nextAccentIndex = 0
            nextSectionIndex = 0
            while nextBeatIndex < beats.count && beats[nextBeatIndex].time < currentTime - 0.05 {
                nextBeatIndex += 1
            }
            while nextAccentIndex < accents.count && accents[nextAccentIndex].time < currentTime - 0.05 {
                nextAccentIndex += 1
            }
            while nextSectionIndex < sections.count && sections[nextSectionIndex].start < currentTime - 0.05 {
                nextSectionIndex += 1
            }
        }
        lastTime = currentTime

        // Beats: schedule each upcoming beat at its exact time.
        while nextBeatIndex < beats.count && beats[nextBeatIndex].time < currentTime + lookahead {
            let beat = beats[nextBeatIndex]
            if beat.time >= currentTime,
               let pattern = HapticPatternGenerator.beatPattern(strength: beat.strength,
                                                                isStrong: beat.isStrong,
                                                                profile: profile,
                                                                strengthScale: strengthScale) {
                haptics.play(pattern, atDelay: beat.time - currentTime)
            }
            nextBeatIndex += 1
        }

        // Accents: strong accents only (perceived emphasis), at exact times.
        while nextAccentIndex < accents.count && accents[nextAccentIndex].time < currentTime + lookahead {
            let accent = accents[nextAccentIndex]
            if accent.type == .accent, accent.strength > 0.4, accent.time >= currentTime,
               let pattern = HapticPatternGenerator.accentPattern(profile: profile,
                                                                  strengthScale: strengthScale) {
                haptics.play(pattern, atDelay: accent.time - currentTime)
            }
            nextAccentIndex += 1
        }

        // Section changes: one tick per boundary, scheduled at the boundary.
        while nextSectionIndex < sections.count && sections[nextSectionIndex].start < currentTime + lookahead {
            let section = sections[nextSectionIndex]
            if section.index > 0, section.start >= currentTime,
               let pattern = HapticPatternGenerator.sectionChangePattern(profile: profile,
                                                                         strengthScale: strengthScale) {
                haptics.play(pattern, atDelay: section.start - currentTime)
            }
            nextSectionIndex += 1
        }
    }

    func stop() {
        haptics.stopAll()
        lastTime = -1
    }

    func reset() {
        lastTime = -1
    }
}