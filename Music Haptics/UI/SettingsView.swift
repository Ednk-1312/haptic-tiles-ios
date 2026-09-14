import SwiftUI

/// Settings screen. All values live in SettingsStore (UserDefaults-backed).
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var aiAvailability: OnDeviceAIAvailability = .checking
    @State private var showAISetup = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Gameplay") {
                    Picker("Preferred difficulty", selection: $settings.preferredDifficulty) {
                        ForEach(DifficultyLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    sliderRow(title: "Note speed",
                              value: $settings.noteApproachTime,
                              range: SettingsStore.SettingsRange.noteApproachTime,
                              step: 0.1,
                              display: String(format: "%.1fs", settings.noteApproachTime))
                    Toggle("Dynamic Speed", isOn: $settings.dynamicSpeedEnabled)
                        .accessibilityHint("Adjusts visual tile travel to broad song intensity changes without changing timing or scoring.")
                    Picker("Dynamic speed response", selection: $settings.dynamicSpeedIntensity) {
                        ForEach(DynamicSpeedIntensity.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .disabled(!settings.dynamicSpeedEnabled)
                    Text(settings.dynamicSpeedEnabled
                         ? settings.dynamicSpeedIntensity.description
                         : "Dynamic speed response is disabled while Dynamic Speed is off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sliderRow(title: "Timing offset",
                              value: $settings.calibrationOffsetMs,
                              range: SettingsStore.SettingsRange.calibrationOffsetMs,
                              step: 5,
                              display: "\(Int(settings.calibrationOffsetMs)) ms")
                    Text("Use this when the music and your taps feel out of sync. A tap-along calibration is available below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Negative moves the timing window earlier; positive moves it later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        CalibrationView()
                    } label: {
                        Label("Calibrate by tapping", systemImage: "hand.tap.fill")
                    }
                    Stepper("Hold completion bonus: \(settings.holdCompleteBonus) pts",
                            value: $settings.holdCompleteBonus,
                            in: SettingsStore.SettingsRange.holdCompleteBonus,
                            step: 50)
                    sliderRow(title: "Perfect timing window",
                              value: $settings.perfectWindowMs,
                              range: SettingsStore.SettingsRange.perfectWindowMs,
                              step: 5,
                              display: "±\(Int(settings.perfectWindowMs)) ms")
                    sliderRow(title: "Great timing window",
                              value: $settings.greatWindowMs,
                              range: SettingsStore.SettingsRange.greatWindowMs,
                              step: 5,
                              display: "±\(Int(settings.greatWindowMs)) ms")
                    sliderRow(title: "Good timing window",
                              value: $settings.goodWindowMs,
                              range: SettingsStore.SettingsRange.goodWindowMs,
                              step: 5,
                              display: "±\(Int(settings.goodWindowMs)) ms")
                    Picker("Visual effects", selection: $settings.visualEffects) {
                        ForEach(VisualEffectLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                }

                Section("On-Device AI") {
                    HStack {
                        Label("On-Device AI", systemImage: "cpu")
                            .font(.headline)
                        Spacer()
                        Text(settings.onDeviceAIEnabled ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }
                    Text("Uses Apple's on-device intelligence for enhanced gameplay analysis and personalization. Processing stays on your iPhone. It is optional and never required to play.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: aiAvailability.supportsEnhancedTier
                              ? "checkmark.circle.fill" : "info.circle.fill")
                            .foregroundStyle(aiAvailability.supportsEnhancedTier ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(aiAvailability.title)
                                .font(.subheadline.weight(.semibold))
                            Text(aiAvailability.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if aiAvailability == .enhancedAvailable {
                        if settings.onDeviceAIEnabled {
                            Button("Disable On-Device AI", role: .destructive) {
                                settings.onDeviceAIEnabled = false
                                appState.gameplayIntelligence.settingsAllowsAnalysis = false
                            }
                        } else {
                            Button {
                                Task {
                                    let current = await appState.gameplayIntelligence.refresh()
                                    aiAvailability = current
                                    if current == .enhancedAvailable {
                                        showAISetup = true
                                    }
                                }
                            } label: {
                                Label("Set Up On-Device AI", systemImage: "sparkles")
                            }
                        }
                    } else {
                        Button("Refresh Availability") {
                            Task {
                                aiAvailability = await appState.gameplayIntelligence.refresh()
                            }
                        }
                        .disabled(aiAvailability == .checking)
                    }

                    if let recommendation = appState.gameplayIntelligence.latestRecommendation {
                        Divider()
                        Label("Local recommendation", systemImage: "lightbulb.fill")
                            .font(.subheadline.weight(.semibold))
                        Text(recommendation.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Apply recommendation") {
                            settings.preferredDifficulty = recommendation.recommendedDifficulty
                            settings.dynamicSpeedEnabled = recommendation.dynamicSpeedEnabled
                            settings.dynamicSpeedIntensity = recommendation.dynamicSpeedIntensity
                        }
                        .buttonStyle(.bordered)
                        Text("Recommendations never change scoring or timing automatically.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Local recommendations appear after at least three recorded attempts. They are optional and never change scoring automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Haptics") {
                    Toggle("Enable haptics", isOn: $settings.hapticsEnabled)
                    Toggle("Reduced haptics", isOn: $settings.reducedHaptics)
                    Picker("Profile", selection: $settings.hapticProfile) {
                        ForEach(HapticProfileID.allCases) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    Text(HapticProfileStore.profile(for: settings.hapticProfile).id.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sliderRow(title: "Haptic strength",
                              value: $settings.hapticStrength,
                              range: SettingsStore.SettingsRange.hapticStrength,
                              step: 0.05,
                              display: "\(Int(settings.hapticStrength * 100))%")
                    Toggle("Feel the beat (rhythm haptics)", isOn: $settings.rhythmHapticsEnabled)
                    Text("Profiles tune note hits, Perfects, holds, chords, beats, accents and section changes. Haptics require a physical iPhone; the simulator can't vibrate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Song analysis") {
                    sliderRow(title: "Chart density",
                              value: $settings.chartDensityMultiplier,
                              range: SettingsStore.SettingsRange.chartDensityMultiplier,
                              step: 0.1,
                              display: "\(Int(settings.chartDensityMultiplier * 100))%")
                    Toggle("Auto difficulty", isOn: $settings.autoDifficulty)
                    Text("Charts are generated on this device from the song's beat, onset, tempo, and section analysis. Changing density affects newly generated charts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Audio") {
                    sliderRow(title: "Volume",
                              value: $settings.volume,
                              range: SettingsStore.SettingsRange.volume,
                              step: 0.05,
                              display: "\(Int(settings.volume * 100))%")
                    Text("Song volume applies when gameplay starts. Your phone's hardware volume and Silent Mode can also affect playback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $settings.colorSchemeRaw) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(AppInfo.versionString)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                #if DEBUG
                Section("Developer") {
                    NavigationLink("Diagnostics") {
                        DiagnosticsView()
                    }
                    Text("Debug tools only appear in Debug builds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                aiAvailability = await appState.gameplayIntelligence.refresh()
            }
            .sheet(isPresented: $showAISetup) {
                OnDeviceAISetupView {
                    settings.onDeviceAIEnabled = true
                    appState.gameplayIntelligence.settingsAllowsAnalysis = true
                    showAISetup = false
                }
            }
        }
    }

    /// All slider ranges are validated in SettingsStore before reaching SwiftUI.
    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double? = nil, display: String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(display)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.subheadline)
            Group {
                if let step {
                    Slider(value: value, in: range, step: step)
                } else {
                    Slider(value: value, in: range)
                }
            }
            .accessibilityLabel(title)
            .accessibilityValue(display)
        }
        .padding(.vertical, 2)
    }
}

/// Honest confirmation step shown only after the current system availability
/// check reports that Foundation Models is ready. No app-owned model is downloaded.
private struct OnDeviceAISetupView: View {
    let onEnable: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label("Optional on-device intelligence", systemImage: "cpu")
                    .font(.title2.weight(.bold))
                Text("Haptic Tiles can use Apple's system Foundation Model before a song starts and after results are shown. It can enrich song-structure analysis and offer explainable gameplay recommendations.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Processing stays on your iPhone.", systemImage: "lock.fill")
                    Label("It never changes scoring, timing windows, or note timestamps.", systemImage: "checkmark.circle")
                    Label("It is not required to play.", systemImage: "gamecontroller")
                }
                .font(.subheadline)
                Text("Battery & performance")
                    .font(.headline)
                Text("On-Device AI may use additional processing and memory during analysis. Your iPhone may use more battery or become warmer during longer analysis tasks. Haptic Tiles limits AI work during active gameplay to keep gameplay responsive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Enable On-Device AI") { onEnable() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                Button("Not Now") { dismiss() }
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("On-Device AI")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
