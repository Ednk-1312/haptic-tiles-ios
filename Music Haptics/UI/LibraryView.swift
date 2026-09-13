import MediaPlayer
import SwiftData
import SwiftUI

/// Home screen: "My Music" (primary, via MediaPlayer) + "Imported Files"
/// (secondary, via the Files picker).
struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var mediaLibrary: MediaLibraryService
    @Query(sort: \SongRecord.importDate, order: .reverse) private var records: [SongRecord]

    @State private var showImport = false
    @State private var showSettings = false
    @State private var showQueue = false
    @State private var songToDelete: SongRecord?
    @State private var quickPlaySession: GameSession?
    @State private var quickPlayRecord: SongRecord?
    @State private var isPreparingQuickPlay = false
    @State private var homeErrorMessage: String?
    @State private var demoRecord: SongRecord?
    @State private var demoSession: GameSession?
    @State private var isPreparingDemo = false
    #if DEBUG
    /// `-demoPassive`: the demo song plays WITHOUT autoplay, so notes fall and
    /// miss — the Simulator visual-testing path for miss feedback.
    @State private var demoPassive = false
    @State private var demoPreviewRecord: SongRecord?
    @State private var demoCalibration = false
    @State private var demoReplay: ReplayFile?
    @State private var isDemoPreparing = false
    #endif

    /// File-imported songs only; library songs live in My Music.
    private var fileRecords: [SongRecord] {
        records.filter { $0.sourceKind == .file }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    homeStartCard
                }

                Section {
                    demoGrooveRow
                }

                Section {
                    NavigationLink {
                        MyMusicView()
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(LinearGradient(colors: [.pink, .purple],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                Image(systemName: "music.note.house.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("My Music")
                                    .font(.headline)
                                Text(librarySubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    NavigationLink {
                        StatsView()
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(LinearGradient(colors: [.orange, .red],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                Image(systemName: "chart.bar.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Statistics")
                                    .font(.headline)
                                Text(statsSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    NavigationLink {
                        PlaylistListView()
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(LinearGradient(colors: [.blue, .teal],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                Image(systemName: "music.note.list")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Playlists")
                                    .font(.headline)
                                Text(playlistSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Imported Files") {
                    if fileRecords.isEmpty {
                        Text("No files imported. Tap + to add MP3, M4A/AAC, WAV or AIFF from Files.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(fileRecords) { song in
                            NavigationLink {
                                SongDetailView(song: song)
                            } label: {
                                SongRow(song: song)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    songToDelete = song
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                #if DEBUG
                #if DEBUG
                Section("Developer") {
                    Button {
                        startDemoAutoplay()
                    } label: {
                        HStack {
                            Label(isDemoPreparing ? "Preparing demo song…" : "Demo Song · Autoplay",
                                  systemImage: "gamecontroller.fill")
                            if isDemoPreparing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isDemoPreparing)
                }
                #endif
                #endif
            }
            .navigationTitle("Haptic Piano")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showQueue = true
                    } label: {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .overlay(alignment: .topTrailing) {
                                if !appState.queue.entries.isEmpty {
                                    Text("\(appState.queue.entries.count)")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.orange, in: Capsule())
                                        .offset(x: 8, y: -6)
                                }
                            }
                    }
                    .accessibilityLabel("Queue")
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    Button {
                        showImport = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import a file")
                }
            }
        }
        .sheet(isPresented: $showImport) { ImportView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(item: $quickPlaySession) { session in
            if let record = quickPlayRecord {
                GameView(session: session, song: record, settings: settings)
            }
        }
        .alert("Couldn't start song", isPresented: Binding(get: { homeErrorMessage != nil },
                                                            set: { if !$0 { homeErrorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(homeErrorMessage ?? "Try opening the song and checking its audio status.")
        }
        .sheet(isPresented: $showQueue) { QueueView() }
        .fullScreenCover(item: $demoSession) { session in
            if let record = demoRecord {
                GameView(session: session, song: record, settings: settings)
            }
        }
        #if DEBUG
        .sheet(isPresented: $demoCalibration) {
            NavigationStack {
                CalibrationView()
            }
        }
        .fullScreenCover(item: $demoPreviewRecord) { record in
            NavigationStack {
                ChartPreviewView(song: record, difficulty: .hard)
            }
        }
        .fullScreenCover(item: $demoReplay) { replay in
            NavigationStack {
                ReplayView(replay: replay)
            }
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-demoAutoplay") {
                startDemoAutoplay()
            }
            if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-demoFile"),
               idx + 1 < ProcessInfo.processInfo.arguments.count {
                startDemoFileAutoplay(fileName: ProcessInfo.processInfo.arguments[idx + 1])
            }
            if ProcessInfo.processInfo.arguments.contains("-demoPassive") {
                startDemoPassive()
            }
            if ProcessInfo.processInfo.arguments.contains("-demoPreview") {
                startDemoPreview()
            }
            if ProcessInfo.processInfo.arguments.contains("-demoCalibration") {
                demoCalibration = true
            }
            if ProcessInfo.processInfo.arguments.contains("-demoReplay") {
                startDemoReplay()
            }
        }
        #endif
        .confirmationDialog("Delete this song and its chart?",
                            isPresented: Binding(get: { songToDelete != nil },
                                                 set: { if !$0 { songToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let song = songToDelete {
                    appState.deleteSong(song)
                }
                songToDelete = nil
            }
            Button("Cancel", role: .cancel) { songToDelete = nil }
        } message: {
            Text("The audio file, analysis and chart will be removed from this device.")
        }
    }

    /// The one-tap entry point for returning testers. It deliberately uses a
    /// real ready song and the same session path as SongDetailView, so this is
    /// convenience navigation rather than a second gameplay implementation.
    @ViewBuilder
    private var homeStartCard: some View {
        if let song = readyRecord {
            Button {
                startQuickPlay(song)
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(colors: [.pink, .orange],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                        Image(systemName: "play.fill")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isPreparingQuickPlay ? "Preparing…" : "Play")
                            .font(.headline)
                        Text("Continue with \(song.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if isPreparingQuickPlay {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.forward")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(isPreparingQuickPlay)
            .accessibilityLabel("Play \(song.title)")
            .accessibilityHint("Starts the most recently prepared song")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Start with a song", systemImage: "play.circle.fill")
                    .font(.headline)
                Text("Choose music from My Music or import an audio file. Once it is ready, Play appears here for one-tap access.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    MyMusicView()
                } label: {
                    Label("Browse My Music", systemImage: "music.note.house")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }
    }

    private var readyRecord: SongRecord? {
        records.first { $0.analysisState == .ready }
    }

    private var demoRecordForDisplay: SongRecord? {
        records.first { $0.fileName == DemoSongFactory.fileName }
    }

    @ViewBuilder
    private var demoGrooveRow: some View {
        Button {
            startDemoGroove()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.tertiarySystemBackground))
                    Image(systemName: isPreparingDemo ? "waveform" : "play.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isPreparingDemo ? "Preparing Demo Groove" : "Try Demo Groove")
                        .font(.headline)
                    Text(demoStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if isPreparingDemo {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.forward")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(isPreparingDemo)
        .accessibilityLabel(isPreparingDemo ? "Preparing Demo Groove" : "Play Demo Groove")
        .accessibilityHint("A short built-in song that works without Music access or importing a file")
    }

    private var demoStatusText: String {
        guard let record = demoRecordForDisplay else {
            return "A short built-in song — no import required"
        }
        let status = appState.pipelineStatus(for: record.id)
        if status.isActive { return status.message }
        if status.stage == .failed { return status.errorMessage ?? "Tap to retry preparation" }
        if record.analysisState == .ready { return "Ready to play · works offline" }
        return record.analysisState.displayName
    }

    private func startDemoGroove() {
        guard !isPreparingDemo else { return }
        isPreparingDemo = true
        homeErrorMessage = nil
        Task {
            defer { isPreparingDemo = false }
            do {
                let result = try await appState.prepareDemoSession()
                demoRecord = result.record
                demoSession = result.session
            } catch is CancellationError {
                // The user can tap Demo Groove again; no terminal state is shown.
            } catch {
                homeErrorMessage = UserFacingError.message(for: error,
                                                            fallback: "Demo Groove could not be prepared. Tap it again to retry.")
            }
        }
    }

    private func startQuickPlay(_ record: SongRecord) {
        guard !isPreparingQuickPlay else { return }
        isPreparingQuickPlay = true
        Task {
            defer { isPreparingQuickPlay = false }
            do {
                quickPlayRecord = record
                quickPlaySession = try await appState.prepareSession(for: record,
                                                                      difficulty: settings.preferredDifficulty)
            } catch is CancellationError {
                // A concurrent regeneration superseded this request. The song
                // remains intact and can be started again from its detail page.
            } catch AudioUnavailableError.protected {
                homeErrorMessage = AppState.unavailableMessage(for: record)
            } catch {
                homeErrorMessage = UserFacingError.message(for: error,
                                                            fallback: "The song could not be prepared. Open the song to review its audio status and try again.")
            }
        }
    }

    #if DEBUG
    /// Opens the chart preview for the demo song (once its chart exists) —
    /// the Simulator visual-testing path for the preview screen.
    private func startDemoPreview() {
        guard !isDemoPreparing else { return }
        isDemoPreparing = true
        Task {
            defer { isDemoPreparing = false }
            if let result = await appState.demoSession(), result.record.analysisState == .ready {
                demoPreviewRecord = result.record
            }
        }
    }

    /// Builds a synthetic perfect replay of the demo song's chart, saves it
    /// through the real storage, and opens the replay — the Simulator
    /// visual-testing path for the replay system.
    private func startDemoReplay() {
        guard !isDemoPreparing else { return }
        isDemoPreparing = true
        Task {
            defer { isDemoPreparing = false }
            guard let result = await appState.demoSession() else { return }
            let chart = result.session.chart
            var events: [ReplayEvent] = []
            var score = 0
            for (i, note) in chart.notes.enumerated() {
                score += 500
                events.append(ReplayEvent(kind: note.type == .hold ? .holdStart : .note,
                                          noteID: note.id, lane: note.lane, time: note.time,
                                          judgment: .perfect, timingErrorMs: 0,
                                          score: score, combo: i + 1))
                if note.type == .hold {
                    score += 250
                    events.append(ReplayEvent(kind: .holdComplete, noteID: note.id,
                                              lane: note.lane, time: note.time + note.duration,
                                              judgment: nil, timingErrorMs: 0,
                                              score: score, combo: i + 1))
                }
            }
            let replay = ReplayBuilder.make(songID: chart.songID,
                                            songTitle: result.record.title,
                                            difficulty: chart.difficulty,
                                            chartVersion: chart.chartVersion,
                                            audioURL: result.session.audioURL,
                                            duration: result.session.chart.duration,
                                            noteCount: chart.notes.count,
                                            events: events)
            if ReplayStorage.save(replay) {
                let analytics = RunAnalyticsCalculator.compute(events: replay.events,
                                                               sections: result.session.analysis?.sections ?? [],
                                                               duration: replay.duration)
                print("[Replay] saved demo replay: \(replay.events.count) events | analytics: \(analytics.judgedCount) judged, \(String(format: "%.1f%%", analytics.accuracy * 100)) acc, \(String(format: "%.0f", analytics.meanAbsErrorMs))ms |err|, \(analytics.timeline.count) buckets, \(analytics.sections.count) sections")
                demoReplay = replay
            } else {
                print("[Replay] failed to save demo replay")
            }
        }
    }

    /// Runs the demo song through the real pipeline and opens gameplay with
    /// autoplay OFF — every note misses, the Simulator visual-testing path
    /// for miss feedback.
    private func startDemoPassive() {
        guard !isDemoPreparing else { return }
        isDemoPreparing = true
        demoPassive = true
        Task {
            defer { isDemoPreparing = false }
            if let result = await appState.demoSession() {
                demoRecord = result.record
                demoSession = result.session
            }
        }
    }

    /// Runs the demo song through the real pipeline and opens gameplay with
    /// autoplay on — the Simulator visual-testing path.
    private func startDemoAutoplay() {
        guard !isDemoPreparing else { return }
        isDemoPreparing = true
        Task {
            defer { isDemoPreparing = false }
            do {
                let result = try await appState.prepareDemoSession()
                demoRecord = result.record
                demoSession = result.session
                #if DEBUG
                print("[Auto] demo session ready — presenting \(result.session.title)")
                #endif
            } catch {
                // The automation path must fail LOUDLY (same alert as the
                // manual button) — a silent bounce-back here cost a real
                // debugging session once already.
                #if DEBUG
                print("[Auto] demo failed: \(error)")
                #endif
                homeErrorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// `-demoFile <name>`: autoplays a REAL audio file from the app's
    /// Documents directory (see `AppState.fileDemoSession`).
    private func startDemoFileAutoplay(fileName: String) {
        guard !isDemoPreparing else { return }
        isDemoPreparing = true
        Task {
            defer { isDemoPreparing = false }
            if let result = await appState.fileDemoSession(fileName: fileName) {
                demoRecord = result.record
                demoSession = result.session
            }
        }
    }
    #endif

    private var statsSubtitle: String {
        let global = appState.stats.global
        if global.totalAttempts == 0 {
            return "Every play counts — stays on this device"
        }
        return "\(global.totalSongsPlayed) songs · \(global.totalAttempts) plays · best combo \(global.highestCombo)"
    }

    private var playlistSubtitle: String {
        let count = appState.playlists.playlists.count
        if count == 0 { return "Your local playlists" }
        let songs = appState.playlists.playlists.reduce(0) { $0 + $1.songIDs.count }
        return "\(count) playlist\(count == 1 ? "" : "s") · \(songs) song\(songs == 1 ? "" : "s") — stays on this device"
    }

    private var librarySubtitle: String {
        switch mediaLibrary.authorizationStatus {
        case .authorized:
            let count = mediaLibrary.songs.count
            return count > 0 ? "\(count) songs — pick one to analyze and play" : "Your Music library is empty"
        case .notDetermined:
            return "Browse your personal music library"
        default:
            return "Browse your personal music library"
        }
    }
}

/// One row in the Imported Files section.
private struct SongRow: View {
    let song: SongRecord

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(data: song.artworkData)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(song.artist) · \(Format.duration(song.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatusBadge(state: song.analysisState)
                    if song.analysisState == .ready, let difficulty = song.chartDifficulty {
                        DifficultyBadge(difficulty: difficulty)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}