import SwiftUI

/// Local statistics: global aggregates on top, then each played song with a
/// per-difficulty breakdown. Statistics never leave the device.
struct StatsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let global = appState.stats.global
        List {
            Section("Overall") {
                HStack(spacing: 10) {
                    globalCard(global.totalSongsPlayed, label: "Songs Played", icon: "music.note")
                    globalCard(global.totalAttempts, label: "Attempts", icon: "play.circle")
                }
                HStack(spacing: 10) {
                    globalCard(global.totalNotesHit, label: "Notes Hit", icon: "checkmark.circle")
                    globalCard(global.totalNotesJudged - global.totalNotesHit, label: "Notes Missed", icon: "xmark.circle")
                }
                HStack(spacing: 10) {
                    globalCard(Int((global.overallAccuracy * 100).rounded()), label: "Accuracy %", icon: "scope")
                    globalCard(global.highestCombo, label: "Best Combo", icon: "flame")
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Hardest Chart", systemImage: "bolt.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(global.hardestChartCleared?.displayName ?? "—")
                            .font(.title3.weight(.bold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Play Time", systemImage: "clock.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(Format.duration(global.totalGameplayTime))
                            .font(.title3.weight(.bold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            Section("By Song") {
                if appState.stats.playedSongs.isEmpty {
                    Text("Play a song to start building your statistics.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.stats.playedSongs, id: \.songID) { song in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(song.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(song.totalAttempts) attempt\(song.totalAttempts == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(songSummary(song))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(song.perDifficulty.sorted { $0.difficulty < $1.difficulty }, id: \.difficulty) { tier in
                                HStack(spacing: 6) {
                                    Text(tier.difficulty.displayName)
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.white.opacity(0.10), in: Capsule())
                                    Text("\(tier.attempts) plays · best \(Format.compact(tier.highestScore))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1f%%", tier.bestAccuracy * 100))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func globalCard(_ value: Int, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.weight(.bold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func songSummary(_ song: SongStats) -> String {
        var parts: [String] = []
        parts.append("best \(Format.compact(song.highestScore))")
        parts.append(String(format: "%.1f%% acc", song.overallAccuracy * 100))
        if let best = song.bestDifficulty {
            parts.append("hardest \(best.displayName)")
        }
        if song.lastPlayed != nil {
            parts.append(Format.duration(song.totalPlayTime))
        }
        return parts.joined(separator: " · ")
    }
}