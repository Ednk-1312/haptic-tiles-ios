import SwiftUI

/// Post-game results overlay.
struct ResultsView: View {
    let result: GameplayResult
    var milestones: [StatMilestone] = []
    /// Non-nil when this run can be saved as a replay (not practice/autoplay).
    var replayContext: ReplayContext?
    /// Per-run analytics (events + sections). Present for every real run.
    var analyticsInput: RunAnalyticsInput?
    let onRetry: () -> Void
    let onDone: () -> Void

    @State private var savedReplay: ReplayFile?
    @State private var showReplay = false
    @State private var showAnalytics = false
    @State private var saveFailed = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("Results")
                    .font(.title.bold())
                Text(result.songTitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                if !milestones.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(milestones, id: \.title) { milestone in
                            milestoneRow(milestone)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.yellow.opacity(0.35), lineWidth: 1))
                }

                VStack(spacing: 4) {
                    Text(Format.compact(result.score))
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text(String(format: "%.1f%% accuracy", result.accuracy * 100))
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("\(result.maxCombo) max combo")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Score \(result.score), accuracy \(String(format: "%.1f", result.accuracy * 100)) percent, \(result.maxCombo) max combo")

                HStack(spacing: 14) {
                    StatBox(value: result.perfectCount, label: "Perfect", color: .yellow)
                    StatBox(value: result.greatCount, label: "Great", color: .green)
                    StatBox(value: result.goodCount, label: "Good", color: .blue)
                    StatBox(value: result.missCount, label: "Miss", color: .red)
                }

                if result.holdsCompleted > 0 || result.holdsMissed > 0 {
                    HStack(spacing: 12) {
                        StatBox(value: result.holdsCompleted, label: "Holds Kept", color: .mint)
                        StatBox(value: result.holdsMissed, label: "Holds Dropped", color: .orange)
                    }
                }

                if let analyticsInput, !analyticsInput.events.isEmpty {
                    Button {
                        showAnalytics = true
                    } label: {
                        Label("Run Analytics", systemImage: "chart.bar.xaxis")
                    }
                    .buttonStyle(.bordered)
                    .font(.headline)
                }

                if let replayContext {
                    if savedReplay != nil {
                        HStack(spacing: 12) {
                            Button {
                                showReplay = true
                            } label: {
                                Label("View Replay", systemImage: "play.rectangle")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .font(.headline)
                    } else {
                        Button {
                            saveReplay(from: replayContext)
                        } label: {
                            Label("Save Replay", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .font(.headline)
                        .disabled(replayContext.events.isEmpty)
                    }
                }

                HStack(spacing: 12) {
                    Button("Retry") { onRetry() }
                        .buttonStyle(.borderedProminent)
                    Button("Done") { onDone() }
                        .buttonStyle(.bordered)
                }
                .font(.headline)

                if let savedReplay {
                    Text("Saved \(savedReplay.events.count) events · \(String(format: "%.0f KB", estimatedKB(savedReplay)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let replayContext, replayContext.events.isEmpty {
                    Text("No notes were judged — nothing to replay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .background(Color(red: 0.09, green: 0.09, blue: 0.14).opacity(0.97),
                        in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            .padding(24)
        }
        .foregroundStyle(.white)
        .sheet(isPresented: $showReplay) {
            if let savedReplay {
                NavigationStack {
                    ReplayView(replay: savedReplay)
                }
            }
        }
        .alert("Couldn't save replay", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The replay file couldn't be written. Check available storage and try again.")
        }
        .sheet(isPresented: $showAnalytics) {
            if let analyticsInput {
                NavigationStack {
                    RunAnalyticsView(analytics: analyticsInput.compute(),
                                     title: analyticsInput.title,
                                     difficulty: analyticsInput.difficulty)
                }
                .presentationDetents([.large])
            }
        }
    }

    private func saveReplay(from context: ReplayContext) {
        let replay = ReplayBuilder.make(songID: context.songID,
                                        songTitle: context.songTitle,
                                        difficulty: context.difficulty,
                                        chartVersion: context.chartVersion,
                                        audioURL: context.audioURL,
                                        duration: context.duration,
                                        noteCount: context.noteCount,
                                        events: context.events)
        if ReplayStorage.save(replay) {
            savedReplay = replay
        } else {
            saveFailed = true
        }
    }

    private func estimatedKB(_ replay: ReplayFile) -> Double {
        Double(replay.events.count) * 0.09
    }

    @ViewBuilder
    private func milestoneRow(_ milestone: StatMilestone) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trophy.fill")
                .foregroundStyle(.yellow)
            switch milestone {
            case .newHighScore(let old, let new):
                Text("\(milestone.title)")
                Text("\(Format.compact(old)) → \(Format.compact(new))")
            case .newBestAccuracy(let old, let new):
                Text("\(milestone.title)")
                Text(String(format: "%.1f%% → %.1f%%", old * 100, new * 100))
            case .newBestCombo(let old, let new):
                Text("\(milestone.title)")
                Text("\(old) → \(new)")
            case .newBestDifficulty(let old, let new):
                Text("\(milestone.title)")
                Text("\(old?.displayName ?? "None") → \(new.displayName)")
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
    }
}

private struct StatBox: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title3.weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 56)
        .padding(.vertical, 10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}