import SwiftUI

/// Settings screen. All values live in SettingsStore (UserDefaults-backed).
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

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
                            value: $settings.holdCompleteBonus, in: SettingsStore.SettingsRange.holdCompleteBonus, step: 50)
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
        }
    }

    /// `step` defaults to nil (continuous). A fractional-range slider MUST
    /// NOT use an integer step: with the old `step: 1` default, the Note
    /// speed slider (1.0–2.6) could only ever produce 1.0 or 2.0, and Volume
    /// snapped between 0% and 100% with nothing in between.
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