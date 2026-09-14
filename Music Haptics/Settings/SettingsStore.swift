import Combine
import Foundation
import SwiftUI

/// How much juice the gameplay visuals use.
enum VisualEffectLevel: String, CaseIterable, Identifiable, Sendable {
    case full, reduced, off
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .full: return "Full"
        case .reduced: return "Reduced"
        case .off: return "Off"
        }
    }
}

/// User preferences. Persisted to UserDefaults; injected into views and the
/// game engine via @EnvironmentObject.
@MainActor
final class SettingsStore: ObservableObject {
    // Workaround for swiftlang/swift#87316 (see StatsManager).
    deinit {}
    // Gameplay
    @Published var preferredDifficulty: DifficultyLevel { didSet { save() } }
    @Published var noteApproachTime: Double { didSet { save() } }        // seconds, note travel time
    @Published var visualEffects: VisualEffectLevel { didSet { save() } }
    @Published var dynamicSpeedEnabled: Bool { didSet { save() } }
    @Published var dynamicSpeedIntensity: DynamicSpeedIntensity { didSet { save() } }
    @Published var calibrationOffsetMs: Double { didSet { save() } }     // -100…+100
    @Published var perfectWindowMs: Double { didSet { save() } }
    @Published var greatWindowMs: Double { didSet { save() } }
    @Published var goodWindowMs: Double { didSet { save() } }

    // Hold scoring
    @Published var holdCompleteBonus: Int { didSet { save() } }        // 0…2000, bonus for sustaining a hold to its tail

    // Haptics
    @Published var hapticsEnabled: Bool { didSet { save() } }
    @Published var hapticStrength: Double { didSet { save() } }          // 0.3…1.0
    @Published var reducedHaptics: Bool { didSet { save() } }
    @Published var rhythmHapticsEnabled: Bool { didSet { save() } }      // feel-the-beat
    @Published var hapticProfileRaw: String { didSet { save() } }        // HapticProfileID raw

    // Audio
    @Published var volume: Double { didSet { save() } }                  // 0…1
    @Published var gameSoundsEnabled: Bool { didSet { save() } }         // reserved (SFX later)

    /// Active haptic profile (validated against known IDs; unknown raw values
    /// fall back to Musical so a corrupt/legacy store can never crash).
    var hapticProfile: HapticProfileID {
        get { HapticProfileID(rawValue: hapticProfileRaw) ?? .musical }
        set { hapticProfileRaw = newValue.rawValue }
    }

    // Chart generation
    @Published var chartDensityMultiplier: Double { didSet { save() } }  // 0.6…1.4
    @Published var autoDifficulty: Bool { didSet { save() } }
    @Published var experimentalAIMode: Bool { didSet { save() } }        // reserved

    // On-device AI (optional system Foundation Models tier; never required for play)
    @Published var onDeviceAIEnabled: Bool { didSet { save() } }
    // Existing bundled Core ML chart-generation controls (developer-configurable)
    @Published var aiEnabled: Bool { didSet { save() } }
    @Published var aiDifficultyWeight: Double { didSet { save() } }      // 0…1, 0.3 = deterministic dominant
    @Published var aiEventWeight: Double { didSet { save() } }           // 0…1
    @Published var aiMinEventConfidence: Double { didSet { save() } }    // 0…1 floor

    // Appearance
    @Published var colorSchemeRaw: String { didSet { save() } }          // "system"/"light"/"dark"

    // Playfield placement (normalized 0…1 rect; full screen by default).
    // Set via the "Fit Playfield to Screen" tool so the four lanes line up
    // with any physical screen. Persisted as four doubles.
    @Published var playfieldFitX: Double { didSet { save() } }
    @Published var playfieldFitY: Double { didSet { save() } }
    @Published var playfieldFitW: Double { didSet { save() } }
    @Published var playfieldFitH: Double { didSet { save() } }

    /// Current playfield placement (clamped; corrupt persisted values can
    /// never produce an off-screen playfield).
    var playfieldFit: PlayfieldFit {
        get {
            PlayfieldFit(x: playfieldFitX, y: playfieldFitY,
                         width: playfieldFitW, height: playfieldFitH).clamped()
        }
        set {
            let fit = newValue.clamped()
            playfieldFitX = fit.x
            playfieldFitY = fit.y
            playfieldFitW = fit.width
            playfieldFitH = fit.height
        }
    }

    /// Valid ranges for every slider-bound setting. SettingsView's Sliders
    /// MUST use these same constants. A persisted value outside its range
    /// would trap SwiftUI at first render (crash on opening Settings) — so
    /// every Double read from UserDefaults is clamped here before it can
    /// ever reach a Slider binding.
    enum SettingsRange {
        static let noteApproachTime: ClosedRange<Double> = 1.0...2.6
        static let calibrationOffsetMs: ClosedRange<Double> = -100...100
        static let perfectWindowMs: ClosedRange<Double> = 30...90
        static let greatWindowMs: ClosedRange<Double> = 60...140
        static let goodWindowMs: ClosedRange<Double> = 120...240
        static let holdCompleteBonus: ClosedRange<Int> = 0...2000
        static let hapticStrength: ClosedRange<Double> = 0.3...1.0
        static let volume: ClosedRange<Double> = 0...1
        static let chartDensityMultiplier: ClosedRange<Double> = 0.6...1.4
        static let aiDifficultyWeight: ClosedRange<Double> = 0...1
        static let aiEventWeight: ClosedRange<Double> = 0...1
        static let aiMinEventConfidence: ClosedRange<Double> = 0...1
    }

    init() {
        let d = UserDefaults.standard
        preferredDifficulty = DifficultyLevel(rawValue: d.string(forKey: Keys.preferredDifficulty) ?? "") ?? .medium
        noteApproachTime = Self.clamp(d.object(forKey: Keys.noteApproachTime) as? Double ?? 1.8,
                                      to: SettingsRange.noteApproachTime)
        visualEffects = VisualEffectLevel(rawValue: d.string(forKey: Keys.visualEffects) ?? "") ?? .full
        dynamicSpeedEnabled = d.object(forKey: Keys.dynamicSpeedEnabled) as? Bool ?? true
        dynamicSpeedIntensity = DynamicSpeedIntensity(rawValue: d.string(forKey: Keys.dynamicSpeedIntensity) ?? "") ?? .standard
        calibrationOffsetMs = Self.clamp(d.object(forKey: Keys.calibration) as? Double ?? 0,
                                         to: SettingsRange.calibrationOffsetMs)
        perfectWindowMs = Self.clamp(d.object(forKey: Keys.perfectWindow) as? Double ?? 70,
                                     to: SettingsRange.perfectWindowMs)
        greatWindowMs = Self.clamp(d.object(forKey: Keys.greatWindow) as? Double ?? 130,
                                   to: SettingsRange.greatWindowMs)
        goodWindowMs = Self.clamp(d.object(forKey: Keys.goodWindow) as? Double ?? 200,
                                  to: SettingsRange.goodWindowMs)
        holdCompleteBonus = min(max(d.object(forKey: Keys.holdCompleteBonus) as? Int ?? 500,
                                    SettingsRange.holdCompleteBonus.lowerBound),
                                SettingsRange.holdCompleteBonus.upperBound)
        hapticsEnabled = d.object(forKey: Keys.hapticsEnabled) as? Bool ?? true
        hapticStrength = Self.clamp(d.object(forKey: Keys.hapticStrength) as? Double ?? 1.0,
                                    to: SettingsRange.hapticStrength)
        reducedHaptics = d.object(forKey: Keys.reducedHaptics) as? Bool ?? false
        rhythmHapticsEnabled = d.object(forKey: Keys.rhythmHaptics) as? Bool ?? true
        hapticProfileRaw = d.string(forKey: Keys.hapticProfile) ?? HapticProfileID.musical.rawValue
        volume = Self.clamp(d.object(forKey: Keys.volume) as? Double ?? 0.9,
                            to: SettingsRange.volume)
        gameSoundsEnabled = d.object(forKey: Keys.gameSounds) as? Bool ?? false
        chartDensityMultiplier = Self.clamp(d.object(forKey: Keys.chartDensity) as? Double ?? 1.0,
                                            to: SettingsRange.chartDensityMultiplier)
        autoDifficulty = d.object(forKey: Keys.autoDifficulty) as? Bool ?? true
        experimentalAIMode = d.object(forKey: Keys.aiMode) as? Bool ?? false
        onDeviceAIEnabled = d.object(forKey: Keys.onDeviceAIEnabled) as? Bool ?? false
        let defaultConfig = AIFusionConfig.default
        aiEnabled = d.object(forKey: Keys.aiEnabled) as? Bool ?? defaultConfig.enabled
        aiDifficultyWeight = Self.clamp(d.object(forKey: Keys.aiDifficultyWeight) as? Double ?? defaultConfig.difficultyAIWeight,
                                        to: SettingsRange.aiDifficultyWeight)
        aiEventWeight = Self.clamp(d.object(forKey: Keys.aiEventWeight) as? Double ?? defaultConfig.eventAIWeight,
                                   to: SettingsRange.aiEventWeight)
        aiMinEventConfidence = Self.clamp(d.object(forKey: Keys.aiMinEventConfidence) as? Double ?? defaultConfig.minEventConfidence,
                                          to: SettingsRange.aiMinEventConfidence)
        colorSchemeRaw = d.string(forKey: Keys.colorScheme) ?? "system"
        playfieldFitX = d.object(forKey: Keys.playfieldFitX) as? Double ?? 0
        playfieldFitY = d.object(forKey: Keys.playfieldFitY) as? Double ?? 0
        playfieldFitW = d.object(forKey: Keys.playfieldFitW) as? Double ?? 1
        playfieldFitH = d.object(forKey: Keys.playfieldFitH) as? Double ?? 1

        // One-time migration (build 4+): clear any persisted playfield-fit
        // rect. The Fit tool is gone — gameplay always derives the four lanes
        // from the actual measured container (W/4), so a stale narrow rect
        // saved by an older build can no longer render as a thin centered
        // playfield on any device.
        let fitResetBuild = d.integer(forKey: Keys.playfieldFitResetBuild)
        if fitResetBuild < Self.currentFitResetBuild {
            playfieldFitX = 0; playfieldFitY = 0; playfieldFitW = 1; playfieldFitH = 1
            d.set(Self.currentFitResetBuild, forKey: Keys.playfieldFitResetBuild)
            save()
        }
    }

    /// Clamps a persisted value into its valid range. Legacy installs (this
    /// app has been installed-over since the prototype) can carry values
    /// written by older builds with different ranges — those values would
    /// crash SwiftUI's Slider the moment Settings opens.
    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Build at which the old Fit-rect feature was removed and persisted
    /// values were cleared. Gameplay no longer reads these keys at all; this
    /// only scrubs leftover data from older installs.
    private static let currentFitResetBuild = 4

    func resetPlayfieldFit() {
        playfieldFitX = 0; playfieldFitY = 0; playfieldFitW = 1; playfieldFitH = 1
    }

    var colorScheme: ColorScheme? {
        switch colorSchemeRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private enum Keys {
        static let preferredDifficulty = "settings.preferredDifficulty"
        static let noteApproachTime = "settings.noteApproachTime"
        static let visualEffects = "settings.visualEffects"
        static let dynamicSpeedEnabled = "settings.dynamicSpeedEnabled"
        static let dynamicSpeedIntensity = "settings.dynamicSpeedIntensity"
        static let calibration = "settings.calibrationOffsetMs"
        static let perfectWindow = "settings.perfectWindowMs"
        static let greatWindow = "settings.greatWindowMs"
        static let goodWindow = "settings.goodWindowMs"
        static let holdCompleteBonus = "settings.holdCompleteBonus"
        static let hapticsEnabled = "settings.hapticsEnabled"
        static let hapticStrength = "settings.hapticStrength"
        static let reducedHaptics = "settings.reducedHaptics"
        static let rhythmHaptics = "settings.rhythmHaptics"
        static let hapticProfile = "settings.hapticProfile"
        static let volume = "settings.volume"
        static let gameSounds = "settings.gameSounds"
        static let chartDensity = "settings.chartDensityMultiplier"
        static let autoDifficulty = "settings.autoDifficulty"
        static let aiMode = "settings.experimentalAI"
        static let onDeviceAIEnabled = "settings.onDeviceAIEnabled"
        static let aiEnabled = "settings.aiEnabled"
        static let aiDifficultyWeight = "settings.aiDifficultyWeight"
        static let aiEventWeight = "settings.aiEventWeight"
        static let aiMinEventConfidence = "settings.aiMinEventConfidence"
        static let colorScheme = "settings.colorScheme"
        static let playfieldFitX = "settings.playfieldFitX"
        static let playfieldFitY = "settings.playfieldFitY"
        static let playfieldFitW = "settings.playfieldFitW"
        static let playfieldFitH = "settings.playfieldFitH"
        static let playfieldFitResetBuild = "settings.playfieldFitResetBuild"
    }

    /// Fusion policy derived from the persisted settings.
    var aiFusionConfig: AIFusionConfig {
        AIFusionConfig(enabled: aiEnabled,
                       difficultyAIWeight: aiDifficultyWeight,
                       eventAIWeight: aiEventWeight,
                       minEventConfidence: aiMinEventConfidence)
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(preferredDifficulty.rawValue, forKey: Keys.preferredDifficulty)
        d.set(noteApproachTime, forKey: Keys.noteApproachTime)
        d.set(visualEffects.rawValue, forKey: Keys.visualEffects)
        d.set(dynamicSpeedEnabled, forKey: Keys.dynamicSpeedEnabled)
        d.set(dynamicSpeedIntensity.rawValue, forKey: Keys.dynamicSpeedIntensity)
        d.set(calibrationOffsetMs, forKey: Keys.calibration)
        d.set(perfectWindowMs, forKey: Keys.perfectWindow)
        d.set(greatWindowMs, forKey: Keys.greatWindow)
        d.set(goodWindowMs, forKey: Keys.goodWindow)
        d.set(hapticsEnabled, forKey: Keys.hapticsEnabled)
        d.set(hapticStrength, forKey: Keys.hapticStrength)
        d.set(reducedHaptics, forKey: Keys.reducedHaptics)
        d.set(rhythmHapticsEnabled, forKey: Keys.rhythmHaptics)
        d.set(hapticProfileRaw, forKey: Keys.hapticProfile)
        d.set(volume, forKey: Keys.volume)
        d.set(gameSoundsEnabled, forKey: Keys.gameSounds)
        d.set(chartDensityMultiplier, forKey: Keys.chartDensity)
        d.set(autoDifficulty, forKey: Keys.autoDifficulty)
        d.set(experimentalAIMode, forKey: Keys.aiMode)
        d.set(onDeviceAIEnabled, forKey: Keys.onDeviceAIEnabled)
        d.set(aiEnabled, forKey: Keys.aiEnabled)
        d.set(aiDifficultyWeight, forKey: Keys.aiDifficultyWeight)
        d.set(aiEventWeight, forKey: Keys.aiEventWeight)
        d.set(aiMinEventConfidence, forKey: Keys.aiMinEventConfidence)
        d.set(colorSchemeRaw, forKey: Keys.colorScheme)
        d.set(playfieldFitX, forKey: Keys.playfieldFitX)
        d.set(playfieldFitY, forKey: Keys.playfieldFitY)
        d.set(playfieldFitW, forKey: Keys.playfieldFitW)
        d.set(playfieldFitH, forKey: Keys.playfieldFitH)
    }
}