import SwiftData
import SwiftUI

/// Developer-only diagnostics: analysis + chart stats for a chosen song.
/// Shown only in Debug builds (Developer section of Settings).
struct DiagnosticsView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var settings: SettingsStore
    @Query(sort: \SongRecord.importDate, order: .reverse) private var songs: [SongRecord]

    @State private var selectedSongID: UUID?
    @State private var analysis: AudioAnalysis?
    @State private var chart: Chart?
    @State private var allCharts: [DifficultyLevel: Chart] = [:]
    @State private var selectedDifficulty: DifficultyLevel = .medium
    @State private var liveTime: Double = 0
    @StateObject private var player = AudioPlayer()
    @State private var hapticSupport: Bool?
    @State private var aiDiagnostics: AISongDiagnostics?
    @State private var aiAvailability: (difficulty: Bool, event: Bool, pattern: Bool, error: String?)?
    @State private var exportResult: String?

    var body: some View {
        List {
            Section("Song") {
                Picker("Song", selection: $selectedSongID) {
                    Text("None").tag(UUID?.none)
                    ForEach(songs) { song in
                        Text(song.title).tag(Optional(song.id))
                    }
                }
                .onChange(of: selectedSongID) { _, _ in load() }
            }

            if !allCharts.isEmpty {
                Section("Multi-difficulty charts") {
                    Picker("Difficulty", selection: $selectedDifficulty) {
                        ForEach(ChartStorage.generatedDifficulties) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedDifficulty) { _, _ in loadChart() }
                    let ordered = ChartStorage.generatedDifficulties.compactMap { level in
                        allCharts[level].map { (level, $0) }
                    }
                    ForEach(ordered, id: \.0) { level, c in
                        row(level.displayName,
                            String(format: "%.1f / 10 · %d notes · %.1f NPS", c.difficultyScore, c.notes.count, c.nps))
                    }
                    let inversions = ChartMonotonicity.inversions(charts: allCharts)
                    if inversions.isEmpty {
                        row("Rating order", "monotonic ✓")
                    } else {
                        row("Rating order", "⚠︎ inversions")
                        ForEach(inversions, id: \.self) { inversion in
                            Text(inversion).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }

            if let analysis {
                Section("Analysis") {
                    row("Duration", Format.duration(analysis.duration))
                    row("Sample rate", String(format: "%.0f Hz", analysis.sampleRate))
                    row("BPM", analysis.tempoBPM.map { String(format: "%.1f", $0) } ?? "not detected")
                    row("BPM confidence", analysis.tempoConfidence.map { String(format: "%.2f", $0) } ?? "—")
                    row("Detected beats", "\(analysis.beats.count)")
                    row("Detected onsets", "\(analysis.onsets.count)")
                    row("Candidate events", "\(analysis.events.count)")
                    row("Sections", "\(analysis.sections.count)")
                    row("Average energy", String(format: "%.3f", analysis.averageEnergy))
                    row("Analysis wall time", String(format: "%.2fs", analysis.analysisDuration))
                }
            }

            if let chart {
                Section("Chart (\(chart.difficulty.displayName))") {
                    row("Difficulty", String(format: "%.1f / 10 · %@", chart.difficultyScore, chart.difficulty.displayName))
                    row("Generated notes", "\(chart.notes.count)")
                    row("Notes per second", String(format: "%.2f", chart.nps))
                    row("Chart version", "\(chart.chartVersion)")
                    row("Seed", "\(chart.seed)")
                    row("Generation time", String(format: "%.2fs", chart.generationDuration))
                    row("Validation warnings", "\(chart.validationWarnings.count)")
                    ForEach(chart.validationWarnings, id: \.self) { warning in
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            if let chart, let analysis {
                Section("Chart quality & patterns") {
                    let a = ChartAnalyticsBuilder.analyze(chart: chart, analysis: analysis)
                    row("Detected beats", "\(analysis.beats.count)")
                    row("Onset candidates", "\(a.eventCandidateCount)")
                    row("Onsets charted", "\(a.eventsCharted)")
                    row("Onsets skipped", "\(a.eventsSkipped)")
                    row("Beat-fill notes", "\(a.beatFillNoteCount)")
                    row("Final note count", "\(a.totalNoteCount)")
                    row("Notes/second (span)", String(format: "%.2f", a.notesPerSecond))
                    row("Sustained NPS", String(format: "%.2f", a.sustainedNPS))
                    row("Simultaneous max", "\(a.maxSimultaneous)")
                    row("Chord groups", "\(a.chordGroups)")
                    row("Lane same/1/2/3", "\(a.sameLaneSteps) / \(a.jump1Steps) / \(a.jump2Steps) / \(a.jump3Steps)")
                    row("Alternations", "\(a.alternationCount)")
                    row("Extreme-bounce run", "\(a.maxExtremeBounceRun)")
                    row("Lane share %", a.laneShares.map { String(format: "%.0f%%", $0 * 100) }.joined(separator: " / "))
                    row("Lane counts", a.laneCounts.map(String.init).joined(separator: " / "))
                    row("Lane idle (s)", a.laneIdleWindows.map { String(format: "%.1f", $0) }.joined(separator: " / "))
                    row("One-sided chart", a.isSuspiciouslyOneSided ? "⚠︎ yes" : "no")
                }

                Section("Chart v4 — musical patterns") {
                    let a = ChartAnalyticsBuilder.analyze(chart: chart, analysis: analysis)
                    row("Quality score", chart.qualityScore.map { String(format: "%.2f / 10", $0) } ?? "—")
                    row("Template counts", a.templateCounts.isEmpty ? "(beat-less song)"
                        : RhythmTemplate.allCases.compactMap { t in
                            a.templateCounts[t.rawValue].map { "\(t.rawValue)×\($0)" }
                        }.joined(separator: " · "))
                    row("Repeated-pattern rate", String(format: "%.0f%%", a.repeatedPatternRate * 100))
                    row("Rest frequency", String(format: "%.0f%%", a.restFrequency * 100))
                    row("Mean phrase length", String(format: "%.2fs", a.meanPhraseLength))
                    row("Chord frequency", String(format: "%.0f%%", a.chordFrequency * 100))
                    row("Holds", "\(a.holdCount) (\(String(format: "%.0f%%", a.holdFrequency * 100)))")
                    row("Difficulty variance", String(format: "%.2f", a.difficultyVariance))
                    row("Validator repairs", "\(a.repairCount)")
                    ForEach(a.sectionDensity, id: \.start) { s in
                        row("\(s.label) @ \(String(format: "%.0fs", s.start))",
                            "\(s.notes) notes · \(String(format: "%.1f", s.nps)) NPS · E\(String(format: "%.2f", s.energy))")
                    }
                }
            }

            if let aiDiag = aiDiagnostics {
                Section("AI — on-device Core ML") {
                    row("Backend", "Core ML (local, no network)")
                    row("Models", aiAvailability.map { ($0.difficulty ? "difficulty ✓" : "difficulty ✗") + " · " + ($0.event ? "event ✓" : "event ✗") + " · " + ($0.pattern ? "pattern ✓" : "pattern ✗") } ?? "loading…")
                    if let error = aiAvailability?.error, error.contains("not bundled") || error.contains("load failed") {
                        Text("AI unavailable: \(error) — deterministic fallback active.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    row("Model version", "v\(aiDiag.modelVersion) · feature schema \(aiDiag.featureSchemaVersion)")
                    row("Training data", AIModelCatalog.trainingDataVersion)
                    if let d = aiDiag.difficulty {
                        row("Deterministic difficulty", String(format: "%.2f", d.deterministicScore))
                        row("AI difficulty", d.aiScore.map { String(format: "%.2f", $0) } ?? "unavailable")
                        row("AI confidence", d.aiConfidence.map { String(format: "%.2f (heuristic)", $0) } ?? "—")
                        row("Final difficulty", String(format: "%.2f", d.finalScore))
                        row("Difficulty used AI", d.usedAI ? "yes" : "no (deterministic)")
                        if let ms = d.inferenceMs { row("Inference time", String(format: "%.2f ms", ms)) }
                    }
                    row("Events ranked", "\(aiDiag.eventCount)")
                    row("Avg event score", String(format: "%.3f", aiDiag.averageEventScore))
                    row("Avg confidence", String(format: "%.3f", aiDiag.averageConfidence))
                    row("Fallback count", "\(aiDiag.fallbackCount)")
                    if let ms = aiDiag.eventInferenceMs {
                        row("Event inference time", String(format: "%.2f ms for %d events", ms, aiDiag.eventCount))
                    }
                    Toggle("AI assisted charts", isOn: Binding(get: { settings.aiEnabled },
                                                               set: { settings.aiEnabled = $0 }))
                    Button("Export AI data (JSONL)") {
                        // Decode + JSONL write of every diagnostics file off the
                        // main actor; result hops back for display only.
                        Task {
                            let url = await Task.detached(priority: .userInitiated) {
                                AIDiagnosticsStore().exportAll()
                            }.value
                            if let url {
                                exportResult = url.path
                            } else {
                                exportResult = "No AI diagnostics recorded yet."
                            }
                        }
                    }
                    if let exportResult {
                        Text(exportResult).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }

                Section("Event ranking — why the AI chose (first 40)") {
                    ForEach(aiDiag.events.prefix(40), id: \.time) { event in
                        HStack {
                            Text(String(format: "%5.2fs", event.time)).monospacedDigit()
                            Text(event.selected ? "●" : "○").foregroundStyle(event.selected ? .green : .gray)
                            Spacer()
                            Text(String(format: "DSP %.2f", event.dspImportance)).font(.caption2).foregroundStyle(.secondary)
                            Text(event.aiImportance.map { String(format: "AI %.2f", $0) } ?? "AI —").font(.caption2)
                                .foregroundStyle(event.usedAI ? .purple : .secondary)
                            Text(String(format: "→ %.2f", event.finalImportance)).font(.caption2).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }

                Section("Pattern ranking — why the AI picked a phrase's pattern") {
                    row("Phrases ranked", "\(aiDiag.patternCount)")
                    row("Deterministic fallbacks", "\(aiDiag.patternFallbackCount)")
                    if let ms = aiDiag.patternInferenceMs {
                        row("Pattern inference time", String(format: "%.2f ms for %d phrases", ms, aiDiag.patternCount))
                    }
                    if aiDiag.patterns.isEmpty {
                        Text("No pattern rankings recorded (beat-less song or model unavailable).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(aiDiag.patterns.prefix(30), id: \.phraseStart) { pattern in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(String(format: "%5.2fs", pattern.phraseStart)).monospacedDigit()
                                Text("\(pattern.template.rawValue) · \(pattern.motif.rawValue)").font(.caption2)
                                Spacer()
                                Text(pattern.usedAI ? "AI pick" : "deterministic")
                                    .font(.caption2)
                                    .foregroundStyle(pattern.usedAI ? .purple : .secondary)
                                Text(pattern.aiConfidence.map { String(format: "Δ%.2f", $0) } ?? "—")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                ForEach(Array(pattern.candidates.enumerated()), id: \.offset) { ci, candidate in
                                    Text("\(ci == pattern.chosenIndex ? "▶" : "") \(candidate.template.rawValue)")
                                        .font(.caption2)
                                        .foregroundStyle(ci == pattern.chosenIndex ? .green : .secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section("Live") {
                row("Playback time", Format.duration(liveTime))
                row("Latency offset", "\(Int(settings.calibrationOffsetMs)) ms")
                row("Haptic hardware", hapticSupport == nil ? "checking…" : (hapticSupport! ? "available" : "unavailable (simulator?)"))
                if player.state == .playing || player.state == .paused {
                    Button("Stop Preview") { player.stop() }
                } else {
                    Button("Play Preview") {
                        if let id = selectedSongID, let song = songs.first(where: { $0.id == id }) {
                            try? player.load(url: song.audioURL)
                            player.play(from: 0)
                        }
                    }
                    .disabled(selectedSongID == nil)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .task {
            if selectedSongID == nil { selectedSongID = songs.first?.id }
            hapticSupport = HapticEngine().isSupported
            let result = await appState.ai.availability()
            aiAvailability = result
        }
        .onDisappear { player.stop() }
        .onChange(of: selectedSongID) { _, _ in load() }
        .task {
            while !Task.isCancelled {
                liveTime = player.currentTime
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func load() {
        guard let id = selectedSongID else {
            analysis = nil
            chart = nil
            allCharts = [:]
            return
        }
        let difficulty = selectedDifficulty
        Task {
            let loaded = try? await Task.detached {
                let charts = try ChartStorage.loadCharts(for: id)
                let chart = try ChartStorage.loadChart(for: id, difficulty: difficulty)
                return (try ChartStorage.loadAnalysis(for: id), chart, charts)
            }.value
            analysis = loaded?.0
            chart = loaded?.1
            allCharts = loaded?.2 ?? [:]
            if allCharts[selectedDifficulty] == nil {
                selectedDifficulty = ChartStorage.generatedDifficulties.first { allCharts[$0] != nil } ?? .medium
            }
            aiDiagnostics = appState.ai.diagnostics(for: id)
        }
    }

    /// Reload only the selected difficulty's chart (used by the picker).
    private func loadChart() {
        guard let id = selectedSongID else { return }
        let difficulty = selectedDifficulty
        Task {
            chart = try? await Task.detached {
                try ChartStorage.loadChart(for: id, difficulty: difficulty)
            }.value
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}