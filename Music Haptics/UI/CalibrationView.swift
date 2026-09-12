import SwiftUI

/// Interactive timing calibration: a short metronome exercise where the user
/// taps along with the flashing cue. Several measurements are collected and a
/// robust (median) estimate is offered — never a single tap. This is an
/// interactive player-calibration tool, not a scientific latency measurement.
struct CalibrationView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var session = CalibrationSession()
    @State private var phase: Phase = .idle
    @State private var anchor: Double = 0
    @State private var firedCueCount = 0
    @State private var lastCueFlash = false
    @State private var manualAdjust: Double = 0

    @State private var haptics = HapticEngine()

    private enum Phase {
        case idle, running, done
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                signConventionCard

                switch phase {
                case .idle:
                    idleContent
                case .running:
                    runningContent
                case .done:
                    resultsContent
                }
            }
            .padding(16)
        }
        .navigationTitle("Calibration")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            #if DEBUG
            print("[Calibration] view appeared")
            #endif
            haptics.prepare()
        }
        .onDisappear { haptics.stopAll() }
        .task(id: phase) {
            guard phase == .running else { return }
            let cueTimes = session.cueTimes(anchor: anchor)
            let lastCue = cueTimes.last ?? anchor
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                // Fire every cue whose time has arrived.
                while firedCueCount < cueTimes.count, cueTimes[firedCueCount] <= now {
                    firedCueCount += 1
                    flashCue(isCountIn: firedCueCount <= session.config.countInBeats)
                }
                if now >= lastCue + session.config.interval * 0.6 {
                    finishExercise()
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        .onChange(of: lastCueFlash) { _, flash in
            // Flash decay timer.
            if flash {
                Task {
                    try? await Task.sleep(for: .milliseconds(140))
                    lastCueFlash = false
                }
            }
        }
    }

    // MARK: - Sign convention

    private var signConventionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("How it works", systemImage: "info.circle.fill")
                .font(.subheadline.weight(.bold))
            Text("Tap in time with the flashing cue. Each tap is compared to its cue: a late tap is positive error, an early tap is negative. The recommended offset is the reverse of your average error — so if you tap 40 ms late, the game is told to shift hits 40 ms earlier.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("This measures your perception, not laboratory-grade latency. It never changes chart timestamps — only the timing offset.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Idle

    private var idleContent: some View {
        VStack(spacing: 14) {
            Text("Tap along with \(CalibrationSession.Config().tapBeats) cues after a short count-in.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                startExercise()
            } label: {
                Label("Start Calibration", systemImage: "metronome")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            HStack(spacing: 8) {
                Text("Current offset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("±\(Int(settings.calibrationOffsetMs)) ms")
                    .font(.headline.monospacedDigit())
            }
        }
        .padding(.vertical, 20)
    }

    // MARK: - Running

    private var runningContent: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(lastCueFlash ? 0.85 : 0.18))
                    .frame(width: lastCueFlash ? 150 : 130, height: lastCueFlash ? 150 : 130)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: lastCueFlash)
                Circle()
                    .stroke(.white.opacity(0.5), lineWidth: 2)
                    .frame(width: 150, height: 150)
            }
            .frame(height: 170)
            .accessibilityElement()
            .accessibilityLabel("Timing cue")
            .accessibilityValue(lastCueFlash ? "Cue" : "Waiting")

            Text(lastCueFlash ? "TAP" : "…")
                .font(.title3.weight(.bold))
                .foregroundStyle(lastCueFlash ? .white : .secondary)

            Button {
                recordTap()
            } label: {
                Label("\(session.taps.count) taps recorded", systemImage: "hand.tap.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Results

    private var resultsContent: some View {
        VStack(spacing: 14) {
            Text("Results")
                .font(.title3.weight(.bold))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    statLabel("Valid taps")
                    Text("\(session.measurements.count)/\(session.config.tapBeats)")
                    statLabel("Rejected")
                    Text("\(session.rejectedTaps)")
                }
                GridRow {
                    statLabel("Mean |error|")
                    Text(String(format: "%.0f ms", session.meanAbsoluteErrorMs))
                    statLabel("Median error")
                    Text(medianErrorText)
                }
                GridRow {
                    statLabel("Current offset")
                    Text("±\(Int(settings.calibrationOffsetMs)) ms")
                    statLabel("Recommended")
                    Text(recommendedText)
                        .font(.headline)
                        .foregroundStyle(recommendedColor)
                }
            }
            .font(.subheadline.monospacedDigit())

            if let recommended = session.recommendedOffsetMs {
                Text("You tapped \(medianErrorText) relative to the cues, so the recommended offset is \(signed(recommended)) ms.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Not enough valid taps (\(session.config.minimumMeasurements) needed). Try again — tap closer to the flashes.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button("Discard") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Apply") {
                    if let recommended = session.recommendedOffsetMs {
                        settings.calibrationOffsetMs = recommended
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.recommendedOffsetMs == nil)
            }

            HStack {
                Text("Manual adjust")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("\(signed(manualAdjust)) ms",
                        value: $manualAdjust, in: -100...100, step: 5)
                Button("Apply") {
                    settings.calibrationOffsetMs = manualAdjust
                }
                .font(.caption.weight(.semibold))
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 14)
    }

    private func statLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private var medianErrorText: String {
        guard !session.measurements.isEmpty else { return "—" }
        let median = CalibrationSession.median(session.measurements)
        return String(format: "%@%.0f ms", median < 0 ? "" : "+", median * 1000)
    }

    private var recommendedText: String {
        guard let recommended = session.recommendedOffsetMs else { return "—" }
        return signed(recommended)
    }

    private var recommendedColor: Color {
        guard let recommended = session.recommendedOffsetMs else { return .secondary }
        return abs(recommended - settings.calibrationOffsetMs) <= 5 ? .green : .orange
    }

    private func signed(_ ms: Double) -> String {
        String(format: "%@%.0f", ms < 0 ? "−" : "+", abs(ms))
    }

    // MARK: - Exercise control

    private func startExercise() {
        anchor = ProcessInfo.processInfo.systemUptime
        firedCueCount = 0
        session = CalibrationSession()
        session.start(at: anchor)
        phase = .running
    }

    private func flashCue(isCountIn: Bool) {
        lastCueFlash = true
        if !isCountIn, settings.hapticsEnabled,
           let pattern = HapticPatternGenerator.beatPattern(strength: 0.7, isStrong: true,
                                                            profile: HapticProfileStore.profile(for: settings.hapticProfile),
                                                            strengthScale: settings.hapticStrength) {
            haptics.play(pattern)
        }
    }

    private func recordTap() {
        guard phase == .running else { return }
        session.record(tapAt: ProcessInfo.processInfo.systemUptime)
    }

    private func finishExercise() {
        phase = .done
        manualAdjust = settings.calibrationOffsetMs
        lastCueFlash = false
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement,
                                 argument: "Calibration finished\(session.recommendedOffsetMs != nil ? ". Review the results and apply or discard." : ". Not enough valid taps — try again.")")
        }
    }
}