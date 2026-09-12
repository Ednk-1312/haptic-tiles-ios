import SwiftUI

/// Song detail: metadata, analysis status, preview, start game, regenerate.
struct SongDetailView: View {
    let song: SongRecord

    @Environment(AppState.self) private var appState
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var previewPlayer = AudioPlayer()
    @State private var session: GameSession?
    @State private var isPreparingGame = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var probeReport: AudioProbeReport?
    @State private var isProbing = false
    @State private var selectedDifficulty: DifficultyLevel = .medium
    @State private var didSetDefaultDifficulty = false
    @State private var charts: [DifficultyLevel: Chart] = [:]
    @State private var showPracticeSetup = false
    @State private var practiceSections: [PracticeSection] = []
    @State private var lastResult: GameplayResult?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                statusCard
                statsCard
                difficultySelector
                actions
                #if DEBUG
                debugSection
                #endif
            }
            .padding(20)
        }
        .navigationTitle(song.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $session) { session in
            GameView(session: session, song: song, settings: settings)
        }
        .sheet(isPresented: $showPracticeSetup) {
            PracticeSetupView(sections: practiceSections) { config in
                startPractice(config)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $probeReport) { report in
            AudioProbeView(report: report)
        }
        .onAppear { reloadCharts() }
        .onChange(of: song.analysisState) { _, _ in reloadCharts() }
        .onChange(of: song.chartVersion) { _, _ in reloadCharts() }
        .onDisappear { previewPlayer.stop() }
        .confirmationDialog("Delete this song?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                appState.deleteSong(song)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(data: song.artworkData)
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                .accessibilityLabel("Album artwork for \(song.title)")
            Text(song.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(song.artist)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Format.duration(song.duration))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SourceBadge(kind: song.sourceKind)
                StatusBadge(state: song.analysisState)
            }
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if song.analysisState == .protected {
                Label(song.errorMessage ?? AppState.protectedAudioMessage, systemImage: "lock.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if song.analysisState == .failed, let message = song.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Button {
                        appState.reanalyze(song)
                    } label: {
                        Label("Retry Analysis", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            } else if song.analysisState == .ready {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    GridRow {
                        Text("Tempo").foregroundStyle(.secondary)
                        Text(song.tempoBPM.map { String(format: "%.0f BPM", $0) } ?? "—")
                        Text("Confidence").foregroundStyle(.secondary)
                        Text(song.tempoConfidence.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                    }
                    GridRow {
                        Text("Difficulty").foregroundStyle(.secondary)
                        Text(difficultyText)
                        Text("Chart version").foregroundStyle(.secondary)
                        Text(song.chartVersion.map(String.init) ?? "—")
                    }
                }
                .font(.subheadline)
            } else if song.analysisState == .analyzing || song.analysisState == .generatingChart {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(song.analysisState == .analyzing
                         ? "Analyzing audio on this device…"
                         : "Designing your chart…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Waiting for analysis to begin…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Statistics card

    @ViewBuilder
    private var statsCard: some View {
        if let stats = appState.stats.stats(for: song.id), stats.totalAttempts > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Statistics", systemImage: "chart.bar.fill")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    if let last = stats.lastPlayed {
                        Text("Last played \(last.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    GridRow {
                        Text("Attempts").foregroundStyle(.secondary)
                        Text("\(stats.totalAttempts)")
                        Text("Best score").foregroundStyle(.secondary)
                        Text(Format.compact(stats.highestScore))
                    }
                    GridRow {
                        Text("Accuracy").foregroundStyle(.secondary)
                        Text(String(format: "%.1f%%", stats.bestAccuracy * 100))
                        Text("Best combo").foregroundStyle(.secondary)
                        Text("\(stats.highestCombo)")
                    }
                    GridRow {
                        Text("Hardest cleared").foregroundStyle(.secondary)
                        Text(stats.bestDifficulty?.displayName ?? "—")
                        Text("Play time").foregroundStyle(.secondary)
                        Text(Format.duration(stats.totalPlayTime))
                    }
                }
                .font(.subheadline)
            }
            .padding(14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var difficultyText: String {
        if let score = song.difficultyScore, let level = song.chartDifficulty {
            return String(format: "%.1f / 10 · %@", score, level.displayName)
        }
        return "—"
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                togglePreview()
            } label: {
                Label(previewPlayer.state == .playing ? "Pause Preview" : "Preview",
                      systemImage: previewPlayer.state == .playing ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .disabled(song.analysisState == .failed || song.analysisState == .protected)

            Button {
                startGame()
            } label: {
                if isPreparingGame {
                    ProgressView().tint(.white)
                } else {
                    Label("Start Game", systemImage: "gamecontroller.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(song.analysisState != .ready || isPreparingGame)

            Button {
                openPracticeSetup()
            } label: {
                Label("Practice", systemImage: "figure.run")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .disabled(song.analysisState != .ready || isPreparingGame)

            HStack(spacing: 10) {
                Button {
                    appState.addToQueue(song, difficulty: selectedDifficulty, playNext: false)
                } label: {
                    Label("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)

                Button {
                    appState.addToQueue(song, difficulty: selectedDifficulty, playNext: true)
                } label: {
                    Label("Play Next", systemImage: "arrow.right.to.line")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
            .disabled(song.analysisState != .ready)

            if let result = lastResult {
                HStack(spacing: 8) {
                    Image(systemName: "rosette")
                        .foregroundStyle(.yellow)
                    Text(String(format: "Last: %@ · %.1f%% · %d max combo",
                                Format.compact(result.score), result.accuracy * 100, result.maxCombo))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if song.analysisState == .protected {
                Text(song.errorMessage ?? AppState.protectedAudioMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if song.sourceKind == .mediaLibrary {
                    Button {
                        dismiss()
                    } label: {
                        Label("Back to My Music — or import an accessible file with the + button",
                              systemImage: "folder")
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 10) {
            Menu {
                ForEach(ChartStorage.generatedDifficulties) { level in
                    Button(level.displayName) {
                        selectedDifficulty = level
                        appState.generateChart(for: song, analysis: nil, difficulty: level)
                    }
                }
            } label: {
                Label("Regenerate \(selectedDifficulty.displayName) Chart", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .disabled(song.analysisState == .protected)

                Button {
                    appState.reanalyze(song)
                } label: {
                    Label("Reanalyze", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(song.analysisState == .protected)
            }

            Button("Delete Song", role: .destructive) {
                showDeleteConfirm = true
            }
            .font(.subheadline)
        }
    }

    // MARK: - Difficulty selector

    /// Picker over all generated difficulty charts, showing each level's
    /// difficulty score, note count, notes/second and status. One shared
    /// analysis feeds every level; choosing a level only picks its cached
    /// chart (regenerating one never touches the others).
    @ViewBuilder
    private var difficultySelector: some View {
        if song.analysisState == .ready {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Difficulty").font(.headline)
                    Spacer()
                    NavigationLink {
                        ChartPreviewView(song: song, difficulty: selectedDifficulty)
                    } label: {
                        Label("Preview", systemImage: "eye.fill")
                    }
                    .font(.subheadline)

                    NavigationLink {
                        ChartEditorView(song: song, difficulty: selectedDifficulty)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .font(.subheadline)
                }

                Picker("Difficulty", selection: $selectedDifficulty) {
                    ForEach(ChartStorage.generatedDifficulties) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)

                if let chart = charts[selectedDifficulty] {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                        GridRow {
                            Text("Score").foregroundStyle(.secondary)
                            Text(String(format: "%.1f / 10", chart.difficultyScore))
                            Text("Notes").foregroundStyle(.secondary)
                            Text("\(chart.notes.count)")
                        }
                        GridRow {
                            Text("Notes/sec").foregroundStyle(.secondary)
                            Text(String(format: "%.1f", chart.nps))
                            Text("Status").foregroundStyle(.secondary)
                            Text("Ready")
                        }
                        GridRow {
                            Text("Target").foregroundStyle(.secondary)
                            Text(String(format: "≈%.1f notes/s", selectedDifficulty.targetNPS))
                            Text("Version").foregroundStyle(.secondary)
                            Text("v\(chart.chartVersion)")
                        }
                    }
                    .font(.subheadline)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Chart not ready for \(selectedDifficulty.displayName) yet — regenerate it below.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if selectedDifficulty == .extreme {
                    Text("Extreme is experimental — the playability validator still keeps it physically possible.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Refresh the cached per-difficulty charts (also used to re-read after a
    /// regeneration finishes).
    private func reloadCharts() {
        if !didSetDefaultDifficulty {
            didSetDefaultDifficulty = true
            selectedDifficulty = settings.preferredDifficulty
        }
        Task {
            charts = await appState.cachedCharts(for: song)
            lastResult = ResultsStorage.load(songID: song.id, difficulty: selectedDifficulty)
        }
    }

    // MARK: - Debug

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Developer").font(.headline)
            NavigationLink {
                ChartDebugView(song: song, difficulty: selectedDifficulty)
            } label: {
                Label("Chart Visualization", systemImage: "chart.bar.doc.horizontal")
            }
            .font(.subheadline)
            Button {
                runAudioDiagnostics()
            } label: {
                Label(isProbing ? "Diagnosing…" : "Audio Diagnostics", systemImage: "stethoscope")
            }
            .font(.subheadline)
            .disabled(isProbing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Runs the full MPMediaItem → AVAsset → AVAssetReader → AVAudioPlayer
    /// probe and shows the exact failure stage + NSError (also printed to the
    /// Xcode console). This is how we distinguish DRM from cloud-only from a
    /// genuinely broken URL instead of guessing.
    private func runAudioDiagnostics() {
        isProbing = true
        Task {
            defer { isProbing = false }
            if let id = song.mediaLibraryPersistentID {
                probeReport = await AudioProbe.report(persistentID: id)
            } else {
                probeReport = await AudioProbe.report(url: song.audioURL)
            }
        }
    }

    // MARK: - Actions

    private func togglePreview() {
        if previewPlayer.state == .playing {
            previewPlayer.pause()
        } else if previewPlayer.state == .paused {
            previewPlayer.resume()
        } else {
            Task {
                guard let url = await appState.resolveAudioURL(for: song) else {
                    errorMessage = AppState.protectedAudioMessage
                    showError = true
                    return
                }
                do {
                    try previewPlayer.load(url: url)
                    previewPlayer.play(from: 0)
                    autoStopPreview()
                } catch {
                    errorMessage = "Couldn't play this audio."
                    showError = true
                }
            }
        }
    }

    private func autoStopPreview() {
        Task {
            try? await Task.sleep(for: .seconds(30))
            if previewPlayer.state == .playing {
                previewPlayer.pause()
            }
        }
    }

    private func startGame() {
        Task {
            isPreparingGame = true
            defer { isPreparingGame = false }
            do {
                guard let url = await appState.resolveAudioURL(for: song) else {
                    throw AudioUnavailableError.protected
                }
                let chart = try await appState.ensureChart(for: song, difficulty: selectedDifficulty)
                let analysis = (try? ChartStorage.loadAnalysis(for: song.id))
                session = GameSession(chart: chart, analysis: analysis, audioURL: url, title: song.title)
            } catch is CancellationError {
                // The chart build was superseded by a newer analysis/chart
                // run for this song — benign, not an error; the user can
                // simply press Play again.
            } catch AudioUnavailableError.protected {
                errorMessage = AppState.unavailableMessage(for: song)
                showError = true
            } catch {
                errorMessage = UserFacingError.message(for: error,
                                                        fallback: "The song could not be prepared. Try again, or choose another difficulty.")
                showError = true
            }
        }
    }

    /// Loads the detected sections (for the practice sheet) and presents it.
    private func openPracticeSetup() {
        if let analysis = try? ChartStorage.loadAnalysis(for: song.id) {
            practiceSections = analysis.sections.map {
                PracticeSection(id: $0.index, label: $0.label.displayName,
                                start: $0.start, end: $0.end, energy: $0.energy)
            }
        } else {
            practiceSections = []
        }
        showPracticeSetup = true
    }

    /// Builds a practice session: the SAME cached chart and analysis as
    /// normal gameplay, wrapped in a PracticeConfig. Dismisses the setup
    /// sheet before presenting the game.
    private func startPractice(_ config: PracticeConfig) {
        showPracticeSetup = false
        Task {
            isPreparingGame = true
            defer { isPreparingGame = false }
            do {
                guard let url = await appState.resolveAudioURL(for: song) else {
                    throw AudioUnavailableError.protected
                }
                let chart = try await appState.ensureChart(for: song, difficulty: selectedDifficulty)
                let analysis = (try? ChartStorage.loadAnalysis(for: song.id))
                session = GameSession(chart: chart, analysis: analysis, audioURL: url,
                                      title: song.title, practice: config)
            } catch is CancellationError {
                // Superseded by a newer pipeline — benign; press Practice again.
            } catch AudioUnavailableError.protected {
                errorMessage = AppState.unavailableMessage(for: song)
                showError = true
            } catch {
                errorMessage = UserFacingError.message(for: error,
                                                        fallback: "The song could not be prepared. Try again, or choose another difficulty.")
                showError = true
            }
        }
    }
}

/// Developer sheet: full audio-resolution diagnostics for one song.
/// Shows every probed value and the exact NSError when a step fails.
private struct AudioProbeView: View {
    let report: AudioProbeReport

    var body: some View {
        NavigationStack {
            List(report.rows) { row in
                HStack(alignment: .top) {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.value)
                        .monospaced()
                        .multilineTextAlignment(.trailing)
                }
                .font(.caption)
            }
            .navigationTitle("Audio Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}