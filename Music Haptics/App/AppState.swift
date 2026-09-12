import Foundation
import Observation
import SwiftData
import UIKit

/// App-wide state: the import → analyze → chart pipeline and error surfacing.
/// Bounded-concurrency gate for background queue pre-generation. A restored
/// queue of hundreds of entries must never spawn hundreds of simultaneous
/// analysis pipelines — gameplay always wins the CPU/memory budget.
private actor PreparationLimiter {
    static let shared = PreparationLimiter()
    private var available = 3
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}

@MainActor
@Observable
final class AppState {
    // Workaround for swiftlang/swift#87316 (see StatsManager).
    deinit {}
    private let context: ModelContext
    let settings: SettingsStore
    let mediaLibrary: MediaLibraryService
    let ai: AISystem
    /// In-app play queue with automatic song transitions.
    let queue: QueueManager
    /// Local playlists (on-device only — no accounts, no cloud).
    let playlists: PlaylistManager
    /// Local statistics (per song + difficulty, personal records, globals).
    let stats: StatsManager

    var isImporting = false
    var importErrorMessage: String?

    /// Per-song pipeline generation tracker. Every analysis/chart-generation
    /// run captures a token; in-flight tasks verify they are still the LATEST
    /// generation before touching state, so a stale task (reanalyzed, deleted
    /// or replaced while running) can never overwrite newer state — and work
    /// for one song can never mutate another song's record.
    private var pipelineTracker = PipelineTracker()

    /// In-flight pipeline task per song. Re-running the pipeline for a song
    /// (re-analyze, regenerate, difficulty change) cancels the previous task
    /// so superseded work STOPS instead of running to completion — the
    /// generation gate already prevents it from landing, this reclaims the
    /// CPU. Different songs keep independent tasks (background pre-generation
    /// stays possible).
    private var pipelineTasks: [UUID: Task<Void, Never>] = [:]
    /// Per-song run serial for task-identity cleanup (Task is a struct, so
    /// identity is tracked by serial instead of `===`).
    private var pipelineTaskIDs: [UUID: Int] = [:]

    private func startPipelineTask(for songID: UUID, _ body: @escaping @MainActor () async -> Void) {
        pipelineTasks[songID]?.cancel()
        let runID = (pipelineTaskIDs[songID] ?? 0) + 1
        pipelineTaskIDs[songID] = runID
        let task = Task { @MainActor [weak self] in
            await body()
            // Clear only if we are still the newest task (a newer run
            // replaced us while we finished — its handle must survive).
            if let self, self.pipelineTaskIDs[songID] == runID {
                self.pipelineTasks[songID] = nil
            }
        }
        pipelineTasks[songID] = task
    }

    private func beginPipeline(for songID: UUID) -> PipelineToken {
        pipelineTracker.begin(for: songID)
    }

    /// True when `token` is the latest pipeline run for `songID` AND the song
    /// record still exists — the two preconditions for safe mutation. The
    /// token carries its own song id, so it can never validate against a
    /// different song.
    private func isCurrent(_ token: PipelineToken, for songID: UUID) -> Bool {
        pipelineTracker.isCurrent(token, for: songID) && fetchRecord(songID) != nil
    }

    /// Latest pipeline generation for `songID` (0 = none) — captured as a
    /// read-only token before async work that must not outlive a newer run.
    private func currentGeneration(for songID: UUID) -> Int {
        pipelineTracker.current(for: songID)
    }

    /// Shown when a Music-library song's audio is protected/unavailable.
    static let protectedAudioMessage = "This song is in your Music library, but iOS does not provide this app with access to its audio for analysis."

    init(container: ModelContainer, settings: SettingsStore, mediaLibrary: MediaLibraryService,
         ai: AISystem? = nil) {
        self.context = container.mainContext
        self.settings = settings
        self.mediaLibrary = mediaLibrary
        self.ai = ai ?? AISystem()
        self.queue = QueueManager(snapshot: Self.validatedSnapshot(context: container.mainContext))
        self.playlists = PlaylistManager(snapshot: PlaylistStorage.load())
        self.stats = StatsManager(snapshot: StatsStorage.load())
        recoverInterruptedPipelines()
    }

    /// A previous launch can die mid-pipeline (termination, crash, update),
    /// leaving records stuck in `.analyzing` / `.generatingChart` forever —
    /// no state transition ever fires again, so the song shows "Analyzing…"
    /// permanently with no recovery path. On launch, re-run the pipeline for
    /// any record in those states. Generation-gated and idempotent: a stale
    /// in-flight run (shouldn't exist across processes, but defensively) is
    /// superseded, never duplicated.
    private func recoverInterruptedPipelines() {
        let stuckStates = [AnalysisState.analyzing.rawValue, AnalysisState.generatingChart.rawValue]
        let predicate = #Predicate<SongRecord> { stuckStates.contains($0.analysisStateRaw) }
        let records = (try? context.fetch(FetchDescriptor<SongRecord>(predicate: predicate))) ?? []
        guard !records.isEmpty else { return }
        #if DEBUG
        print("[Recovery] re-running pipeline for \(records.count) interrupted song(s)")
        #endif
        for record in records {
            runPipeline(for: record)
        }
    }

    /// Restores the persisted queue, dropping entries whose song records no
    /// longer exist (deleted songs must never crash or wedge the queue).
    private static func validatedSnapshot(context: ModelContext) -> QueueSnapshot? {
        guard var snapshot = QueueStorage.load() else { return nil }
        var valid: [QueueEntry] = []
        for entry in snapshot.entries {
            var descriptor = FetchDescriptor<SongRecord>(predicate: #Predicate { $0.id == entry.songID })
            descriptor.fetchLimit = 1
            if (try? context.fetch(descriptor).first) != nil {
                valid.append(entry)
            }
        }
        let dropped = snapshot.entries.count - valid.count
        if dropped > 0 {
            snapshot.entries = valid
            if let current = snapshot.currentEntryID, !valid.contains(where: { $0.id == current }) {
                snapshot.currentEntryID = valid.first?.id
            }
        }
        return snapshot
    }

    // MARK: - Import

    /// Imports a user-picked file: copies it, records metadata, then starts
    /// analysis + chart generation off the main thread.
    func importSong(from url: URL) async {
        importErrorMessage = nil
        isImporting = true
        defer { isImporting = false }
        do {
            let imported = try await AudioImporter.importFile(from: url)
            let destURL = AppDirectories.songsDirectory.appendingPathComponent(imported.fileName)
            let metadata = await AudioMetadataLoader.load(from: destURL)
            let record = SongRecord(
                title: metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? url.deletingPathExtension().lastPathComponent,
                artist: metadata.artist ?? "Unknown Artist",
                fileName: imported.fileName,
                duration: metadata.duration > 0 ? metadata.duration : imported.duration,
                artworkData: metadata.artworkData
            )
            context.insert(record)
            try context.save()
            runPipeline(for: record)
        } catch {
            importErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't import this file. It may be DRM-protected or in an unsupported format."
        }
    }

    // MARK: - My Music

    /// Returns the cached record for a Music-library song, if any.
    func record(forMediaLibraryID id: UInt64) -> SongRecord? {
        let libraryID = Int64(bitPattern: id)
        let predicate = #Predicate<SongRecord> { $0.mediaLibraryID == libraryID }
        var descriptor = FetchDescriptor<SongRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Creates (or returns the cached) record for a library song and starts
    /// the analyze → chart pipeline. The persistent media-library ID is the
    /// cache key, so reopening the app reuses the record instead of treating
    /// the song as new. Library audio is never copied into the sandbox.
    @discardableResult
    func analyzeLibrarySong(_ song: LibrarySong, artwork: Data? = nil) -> SongRecord {
        if let existing = record(forMediaLibraryID: song.persistentID) {
            return existing
        }
        let record = SongRecord(title: song.title,
                                artist: song.artist,
                                fileName: "",   // unused for library sources
                                duration: song.duration,
                                artworkData: artwork)
        record.sourceKind = .mediaLibrary
        record.mediaLibraryPersistentID = song.persistentID
        record.albumTitle = song.albumTitle
        record.genre = song.genre
        record.libraryBPM = song.libraryBPM
        context.insert(record)
        try? context.save()
        runPipeline(for: record)
        return record
    }

    // MARK: - Audio resolution

    /// Resolves playable audio for a record: the sandbox copy for files, or
    /// the Music-library asset for library songs. Returns nil only when the
    /// MediaPlayer flags say the audio genuinely can't be reached (DRM, cloud
    /// item without a download, or no asset URL at all). A URL that exists but
    /// later fails to decode is NOT filtered here — the analyzer reports the
    /// exact failure (reader creation, sample read, format…) instead of us
    /// mislabeling decode errors as "protected". The DSP pipeline, playback
    /// and the game clock all use the returned URL — one audio timeline for
    /// every source.
    func resolveAudioURL(for record: SongRecord) async -> URL? {
        switch record.sourceKind {
        case .file:
            let url = record.audioURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .mediaLibrary:
            guard let id = record.mediaLibraryPersistentID else { return nil }
            return mediaLibrary.assetURL(persistentID: id)
        }
    }

    // MARK: - Analysis + chart pipeline

    /// Background pipeline: resolve audio → analyze → save → generate chart → save.
    /// Each run gets a generation id; stale runs (song reanalyzed, deleted or
    /// replaced mid-flight) stop before mutating anything.
    func runPipeline(for record: SongRecord) {
        record.analysisState = .analyzing
        record.errorMessage = nil
        try? context.save()
        let songID = record.id
        let generation = beginPipeline(for: songID)

        startPipelineTask(for: songID) { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard let url = await self.resolveAudioURL(for: record) else {
                    if self.isCurrent(generation, for: songID) {
                        self.markAudioUnavailable(songID: songID)
                    }
                    return
                }
                let analysis = try await AudioAnalyzer().analyze(url: url)
                // A superseded run must not write ANY files: saving its
                // analysis would clobber the newer run's file, and deleting
                // charts would destroy charts the newer run already generated.
                guard self.isCurrent(generation, for: songID) else { return }
                try await Task.detached { try ChartStorage.saveAnalysis(analysis, for: songID) }.value
                // New analysis invalidates every cached difficulty chart.
                await Task.detached { ChartStorage.deleteAllCharts(for: songID) }.value
                guard self.isCurrent(generation, for: songID),
                      let record = self.fetchRecord(songID) else { return }
                record.tempoBPM = analysis.tempoBPM
                record.tempoConfidence = analysis.tempoConfidence
                let summaryDifficulty = self.settings.autoDifficulty ? DifficultyLevel.medium : self.settings.preferredDifficulty
                // ONE shared analysis → every difficulty's chart (Easy … Extreme).
                self.generateAllCharts(for: record, analysis: analysis,
                                       summaryDifficulty: summaryDifficulty,
                                       generation: generation)
            } catch {
                if self.isCurrent(generation, for: songID) {
                    self.failPipeline(songID: songID,
                                      message: (error as? LocalizedError)?.errorDescription ?? "Analysis failed.",
                                      error: error,
                                      probeAudio: true)
                }
            }
        }
    }

    private func markAudioUnavailable(songID: UUID) {
        guard let record = fetchRecord(songID) else { return }
        if record.sourceKind == .file {
            record.analysisState = .failed
            record.errorMessage = "The imported audio file is no longer available. Re-import the file to play this song."
        } else {
            record.analysisState = .protected
            record.errorMessage = Self.unavailableMessage(for: record)
        }
        #if DEBUG
        if let id = record.mediaLibraryPersistentID {
            Task { _ = await AudioProbe.report(persistentID: id) }
        }
        #endif
        try? context.save()
    }

    /// Honest, cause-specific explanation. DRM, cloud-only, missing-from-
    /// library and unknown are separate states — never collapse them into one
    /// "DRM" message.
    static func unavailableMessage(for record: SongRecord) -> String {
        guard let id = record.mediaLibraryPersistentID else { return protectedAudioMessage }
        // The item vanished from the library entirely (deleted in Music app).
        if MPMediaLibraryProvider.item(persistentID: id) == nil {
            return "This song is no longer in your Music library. Re-add it in the Music app, or remove it here."
        }
        let info = MPMediaLibraryProvider().mediaAssetInfo(persistentID: id)
        switch AudioAccessClassifier.state(info) {
        case .protected:
            return "This song is DRM-protected, so iOS does not provide this app with access to its audio for analysis."
        case .cloudUnavailable:
            return "This song is in iCloud and isn't downloaded to this device. Download it in the Music app, then try again."
        default:
            return protectedAudioMessage
        }
    }

    /// Generates EVERY difficulty chart for a song from one shared analysis
    /// (Easy, Normal, Hard, Expert, Extreme) and persists each under its own
    /// difficulty key. `summaryDifficulty` picks which chart's stats the
    /// record exposes for list/UI summaries.
    func generateAllCharts(for record: SongRecord, analysis: AudioAnalysis, summaryDifficulty: DifficultyLevel,
                           generation: PipelineToken? = nil) {
        record.analysisState = .generatingChart
        try? context.save()
        let songID = record.id
        let density = settings.chartDensityMultiplier
        let gen = generation ?? beginPipeline(for: songID)

        startPipelineTask(for: songID) { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                self.ai.config = self.settings.aiFusionConfig
                var summary: Chart?
                for difficulty in ChartStorage.generatedDifficulties {
                    guard self.isCurrent(gen, for: songID) else { return }
                    try Task.checkCancellation()
                    let seed = Self.seed(for: songID, difficulty: difficulty)
                    let output = try await ChartGenerator().generate(
                        analysis: analysis, songID: songID,
                        request: ChartGenerator.Request(difficulty: difficulty, densityMultiplier: density, seed: seed),
                        advisor: AIChartAdvisorBridge(system: self.ai))
                    // Superseded mid-generation: a stale chart (built from an
                    // older analysis) must never overwrite the newer run's file.
                    guard self.isCurrent(gen, for: songID) else { return }
                    try await Task.detached { try ChartStorage.save(output.chart, for: songID) }.value
                    self.ai.finalizeDiagnostics(songID: songID, chart: output.chart)
                    if difficulty == summaryDifficulty { summary = output.chart }
                }
                guard self.isCurrent(gen, for: songID),
                      let record = self.fetchRecord(songID) else { return }
                record.analysisState = .ready
                record.chartDifficulty = summary?.difficulty
                record.chartVersion = summary?.chartVersion
                record.chartNotesCount = summary?.notes.count
                record.difficultyScore = summary?.difficultyScore
                record.errorMessage = nil
                try? context.save()
            } catch {
                if self.isCurrent(gen, for: songID) {
                    self.failPipeline(songID: songID, message: (error as? LocalizedError)?.errorDescription ?? "Chart generation failed.")
                }
            }
        }
    }

    /// Regenerates ONE difficulty's chart from cached analysis without
    /// touching the others (used by the song-detail Regenerate menu).
    /// Generation-gated like the full pipeline: a regeneration supersedes any
    /// in-flight one for the same song.
    func generateChart(for record: SongRecord, analysis: AudioAnalysis?, difficulty: DifficultyLevel) {
        record.analysisState = .generatingChart
        try? context.save()
        let songID = record.id
        let density = settings.chartDensityMultiplier
        let gen = beginPipeline(for: songID)

        startPipelineTask(for: songID) { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let analysis = try await self.analysisOrLoad(songID: songID, existing: analysis)
                guard self.isCurrent(gen, for: songID) else { return }
                try Task.checkCancellation()
                self.ai.config = self.settings.aiFusionConfig
                let seed = Self.seed(for: songID, difficulty: difficulty)
                let output = try await ChartGenerator().generate(
                    analysis: analysis, songID: songID,
                    request: ChartGenerator.Request(difficulty: difficulty, densityMultiplier: density, seed: seed),
                    advisor: AIChartAdvisorBridge(system: self.ai))
                // Superseded mid-generation: never overwrite the newer run's file.
                guard self.isCurrent(gen, for: songID) else { return }
                try await Task.detached { try ChartStorage.save(output.chart, for: songID) }.value
                self.ai.finalizeDiagnostics(songID: songID, chart: output.chart)
                guard self.isCurrent(gen, for: songID),
                      let record = self.fetchRecord(songID) else { return }
                if record.chartDifficulty == difficulty || record.chartDifficulty == nil {
                    // Keep the list-level summary pointing at the preferred
                    // level when it matches the regenerated one.
                    record.chartDifficulty = difficulty
                    record.chartVersion = output.chart.chartVersion
                    record.chartNotesCount = output.chart.notes.count
                    record.difficultyScore = output.chart.difficultyScore
                }
                record.analysisState = .ready
                record.errorMessage = nil
                try? context.save()
            } catch {
                if self.isCurrent(gen, for: songID) {
                    self.failPipeline(songID: songID, message: (error as? LocalizedError)?.errorDescription ?? "Chart generation failed.")
                }
            }
        }
    }

    /// Loads a valid chart for one difficulty immediately (used by the Play
    /// button and the demo path); generates it from the shared cached analysis
    /// only if missing or outdated — other difficulties stay untouched.
    /// A corrupt or malformed cached chart is treated as MISSING (discarded +
    /// regenerated) instead of surfacing a dead-end error.
    func ensureChart(for record: SongRecord, difficulty: DifficultyLevel) async throws -> Chart {
        // Player-edited charts take precedence for gameplay: an edited chart
        // is a separate versioned file that never overwrites the generated
        // one, so it is safe to prefer whenever it exists and is valid.
        if let edited = try? ChartStorage.loadEdited(for: record.id, difficulty: difficulty),
           Self.isWellFormed(edited.chart) {
            return edited.chart
        }
        do {
            if let chart = try ChartStorage.loadChart(for: record.id, difficulty: difficulty),
               chart.chartVersion == ChartStorage.chartVersion,
               Self.isWellFormed(chart) {
                return chart
            }
        } catch {
            // Corrupt cache file: discard and regenerate below.
            ChartStorage.deleteChart(for: record.id, difficulty: difficulty)
        }
        // Generation-gated regeneration. A chart has no analysis identity of
        // its own, so a chart generated from a STALE analysis (a reanalysis
        // started while we were loading/generating) must never survive on
        // disk — otherwise it would be indistinguishable from a fresh one.
        // Bounded retry: a superseded run deletes its own output and retries
        // once the newer run has finished; genuinely contended calls throw
        // CancellationError (callers treat it as benign, never as a failure
        // of the song).
        for _ in 0..<3 {
            let token = PipelineToken(songID: record.id, generation: currentGeneration(for: record.id))
            let analysis = try await analysisOrLoad(songID: record.id, existing: nil)
            // A newer run started while we loaded: retry against the new
            // analysis instead of generating from a possibly-stale one.
            guard isCurrent(token, for: record.id) else { continue }
            let seed = Self.seed(for: record.id, difficulty: difficulty)
            ai.config = settings.aiFusionConfig
            let output = try await ChartGenerator().generate(
                analysis: analysis, songID: record.id,
                request: ChartGenerator.Request(difficulty: difficulty, densityMultiplier: settings.chartDensityMultiplier, seed: seed),
                advisor: AIChartAdvisorBridge(system: ai))
            let outputChart = output.chart
            let outputSongID = record.id
            try await Task.detached {
                try ChartStorage.save(outputChart, for: outputSongID)
            }.value
            // A newer run started while we generated: our chart derives from
            // a possibly-stale analysis — delete it and retry.
            guard isCurrent(token, for: record.id) else {
                let staleSongID = record.id
                Task.detached {
                    ChartStorage.deleteChart(for: staleSongID, difficulty: difficulty)
                }
                continue
            }
            ai.finalizeDiagnostics(songID: record.id, chart: output.chart)
            record.analysisState = .ready
            record.errorMessage = nil
            try? context.save()
            return output.chart
        }
        // Still contended after the bounded retries: report a benign
        // cancellation — the song is fine, the caller simply asked at the
        // wrong moment.
        throw CancellationError()
    }

    /// Cached charts for every generated difficulty (fast file reads for the
    /// song-detail difficulty picker).
    func cachedCharts(for record: SongRecord) async -> [DifficultyLevel: Chart] {
        let songID = record.id
        return (try? await Task.detached { try ChartStorage.loadCharts(for: songID) }.value) ?? [:]
    }

    func reanalyze(_ record: SongRecord) {
        runPipeline(for: record)
    }

    // MARK: - Chart editor

    /// Saves the edited chart as a versioned variant of the given difficulty.
    /// The generated chart is preserved; gameplay/preview prefer the edited
    /// variant while it exists.
    func saveEditedChart(_ file: EditedChartFile, for record: SongRecord) {
        try? ChartStorage.saveEdited(file, for: record.id)
        try? context.save()
    }

    /// Deletes the edited variant for a difficulty ("discard edits"). The
    /// generated chart remains.
    func discardEdits(for record: SongRecord, difficulty: DifficultyLevel) {
        ChartStorage.deleteEditedChart(for: record.id, difficulty: difficulty)
    }

    /// "Regenerate chart": drops the edited variant AND the generated chart,
    /// then runs a fresh generation so the editor starts from a clean
    /// baseline. Old edits are never silently overwritten — the caller asks
    /// first (confirmation dialog in the editor).
    func regenerateEditedChart(for record: SongRecord, difficulty: DifficultyLevel) {
        ChartStorage.deleteEditedChart(for: record.id, difficulty: difficulty)
        generateChart(for: record, analysis: nil, difficulty: difficulty)
    }

    // MARK: - Queue

    /// Public record lookup by stable ID (queue entries reference song IDs).
    func record(id: UUID) -> SongRecord? {
        fetchRecord(id)
    }

    /// Builds a ready-to-play session for a queued entry: resolved audio +
    /// cached-or-generated chart at the entry's difficulty. nil when the audio
    /// is unavailable or the song record vanished (the caller removes the
    /// entry). Throws `CancellationError` when the chart build was superseded
    /// by a newer pipeline for the same song — the entry is NOT removed for
    /// that (transient) case.
    func session(for entry: QueueEntry) async throws -> GameSession? {
        guard let record = record(id: entry.songID) else { return nil }
        guard let url = await resolveAudioURL(for: record) else { return nil }
        let chart: Chart
        do {
            chart = try await ensureChart(for: record,
                                          difficulty: entry.difficulty ?? settings.preferredDifficulty)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        let analysis = try? ChartStorage.loadAnalysis(for: record.id)
        return GameSession(chart: chart, analysis: analysis, audioURL: url, title: record.title)
    }

    /// Background pre-generation for a queued entry: resolves audio and
    /// ensures its chart is cached (a no-op when the cached chart is already
    /// valid) so the transition is instant. Runs at utility priority and never
    /// touches state once the entry's preparation token has changed (removed,
    /// re-queued or advanced past).
    func prepareQueueEntry(_ entry: QueueEntry) {
        guard let record = record(id: entry.songID) else {
            queue.remove(entryID: entry.id)
            return
        }
        let token = queue.preparationToken(for: entry.id)
        let difficulty = entry.difficulty ?? settings.preferredDifficulty
        Task(priority: .utility) { [weak self] in
            // Bounded concurrency: a restored queue of hundreds of entries
            // must never spawn hundreds of simultaneous analysis pipelines
            // (CPU + memory contention with active gameplay).
            await PreparationLimiter.shared.acquire()
            defer { Task { await PreparationLimiter.shared.release() } }
            guard let self, self.queue.preparationToken(for: entry.id) == token else { return }
            self.queue.setStatus(.preparing, for: entry.id)
            do {
                guard await self.resolveAudioURL(for: record) != nil else {
                    if self.queue.preparationToken(for: entry.id) == token {
                        self.queue.setStatus(.error, for: entry.id)
                    }
                    return
                }
                _ = try await self.ensureChart(for: record, difficulty: difficulty)
                if self.queue.preparationToken(for: entry.id) == token {
                    self.queue.setStatus(.ready, for: entry.id)
                }
            } catch is CancellationError {
                // Superseded by a newer pipeline for the same song: leave the
                // entry idle so it re-prepares (or the new pipeline's own
                // completion covers it) instead of mislabeling it failed.
                if self.queue.preparationToken(for: entry.id) == token {
                    self.queue.setStatus(.idle, for: entry.id)
                }
            } catch {
                if self.queue.preparationToken(for: entry.id) == token {
                    self.queue.setStatus(.error, for: entry.id)
                }
            }
        }
    }

    /// Prepares the entry AFTER a queued entry (pre-generation pipeline).
    func prepareNextAfter(_ entry: QueueEntry) {
        guard let next = queue.upNext(for: entry) else { return }
        prepareQueueEntry(next)
    }

    /// Starts background preparation for every not-yet-ready queued entry
    /// (called after queue restore so relaunched queues pre-generate again).
    func prepareAllQueued() {
        for entry in queue.entries where entry.status == .idle {
            prepareQueueEntry(entry)
        }
    }

    /// Saves a finished playthrough (automatic transitions persist results
    /// before the next song starts).
    func saveResult(_ result: GameplayResult, for songID: UUID) {
        ResultsStorage.save(result, songID: songID)
    }

    /// Records a finished run into the local statistics and returns the
    /// personal records it broke (shown on the results screen). Practice and
    /// autoplay runs are filtered by the caller before reaching this.
    @discardableResult
    func recordResult(_ result: GameplayResult, for songID: UUID) -> [StatMilestone] {
        saveResult(result, for: songID)
        let chartVersion = try? ChartStorage.loadChart(for: songID, difficulty: result.difficulty)?.chartVersion
        return stats.record(result, for: songID, chartVersion: chartVersion)
    }

    /// Adds a song to the queue and starts preparing its chart in the
    /// background.
    func addToQueue(_ record: SongRecord, difficulty: DifficultyLevel?, playNext: Bool) {
        let entry = QueueEntry(songID: record.id, title: record.title, artist: record.artist,
                               difficulty: difficulty ?? settings.preferredDifficulty)
        if playNext {
            queue.playNext(entry)
        } else {
            queue.add(entry)
        }
        prepareQueueEntry(entry)
    }

    // MARK: - Playlists

    /// Resolves a playlist's ordered song IDs to live records, skipping songs
    /// that no longer exist (deleted or corrupted) without crashing. Returns
    /// the resolvable songs plus how many were dropped.
    func songs(in playlist: Playlist) -> (songs: [SongRecord], missing: Int) {
        let resolved = playlist.songIDs.compactMap { record(id: $0) }
        return (resolved, playlist.songIDs.count - resolved.count)
    }

    /// Total playable duration of a playlist's resolvable songs.
    func playlistDuration(_ playlist: Playlist) -> Double {
        songs(in: playlist).songs.reduce(0) { $0 + max(0, $1.duration) }
    }

    /// Builds the queue from a playlist and returns the first entry to play.
    /// Missing/unresolvable songs are skipped; a playlist with no playable
    /// songs returns nil and leaves the queue untouched.
    /// - `shuffled`: seeded-deterministic order (seed from the playlist id) so
    ///   the same playlist always shuffles identically for tests.
    func queuePlaylist(_ playlist: Playlist, shuffled: Bool) -> QueueEntry? {
        let (songs, _) = songs(in: playlist)
        guard !songs.isEmpty else { return nil }
        let orderedIDs = playlists.playOrder(songIDs: songs.map(\.id),
                                             shuffled: shuffled,
                                             seed: shuffled ? stableSeed(playlist.id) : 0)
        let entries = orderedIDs.compactMap { id -> QueueEntry? in
            guard let song = record(id: id) else { return nil }
            return QueueEntry(songID: song.id, title: song.title, artist: song.artist,
                              difficulty: song.chartDifficulty ?? settings.preferredDifficulty)
        }
        guard let first = entries.first else { return nil }
        queue.clear()
        queue.add(entries)
        queue.setCurrent(entryID: first.id)
        for entry in entries { prepareQueueEntry(entry) }
        return first
    }

    /// Appends every resolvable song of a playlist to the queue (in playlist
    /// order, duplicates allowed across playlist + existing queue).
    func addPlaylistToQueue(_ playlist: Playlist) -> Int {
        let (songs, _) = songs(in: playlist)
        let entries = songs.map { song in
            QueueEntry(songID: song.id, title: song.title, artist: song.artist,
                       difficulty: song.chartDifficulty ?? settings.preferredDifficulty)
        }
        queue.add(entries)
        for entry in entries { prepareQueueEntry(entry) }
        return songs.count
    }

    /// Deterministic 64-bit seed derived from a playlist id (shuffle
    /// reproducibility).
    private func stableSeed(_ id: UUID) -> UInt64 {
        id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ UInt64($1) }
    }

    // MARK: - Demo song (Debug builds)

    #if DEBUG
    /// Creates (or reuses) the synthetic demo song and starts the normal
    /// analyze → chart pipeline. Used by the Developer section and the
    /// `-demoAutoplay` launch argument for Simulator visual testing.
    /// Creates (or reuses) the synthetic demo song. Returns nil when the demo
    /// audio can't be synthesized (storage failure) — the demo path degrades
    /// gracefully instead of crashing the app.
    @discardableResult
    func createDemoSong() -> SongRecord? {
        if let existing = fileRecord(named: DemoSongFactory.fileName) { return existing }
        guard let url = try? DemoSongFactory.writeIfNeeded(to: AppDirectories.songsDirectory) else {
            return nil
        }
        let record = SongRecord(title: "Demo Groove",
                                artist: "Haptic Piano",
                                fileName: url.lastPathComponent,
                                duration: DemoSongFactory.duration,
                                artworkData: nil)
        record.sourceKind = .file
        context.insert(record)
        try? context.save()
        runPipeline(for: record)
        return record
    }

    /// Builds a playable session once the demo song is ready (launch-arg path).
    func demoSession() async -> (record: SongRecord, session: GameSession)? {
        guard let record = createDemoSong() else { return nil }
        return await sessionForReadyRecord(record)
    }

    /// `-demoFile <name>` launch-arg path: like `-demoAutoplay` but for a REAL
    /// audio file the tester placed in the app's Documents directory (e.g. via
    /// `simctl get_app_container` + `cp`). Registers it as an imported song and
    /// runs the normal analyze → chart → session pipeline, so a real MP3 can be
    /// validated end-to-end (import, analysis, chart, autoplay, practice,
    /// queue) without driving the document-picker UI.
    func fileDemoSession(fileName: String) async -> (record: SongRecord, session: GameSession)? {
        let record: SongRecord
        if let existing = fileRecord(named: fileName) {
            record = existing
            if record.analysisState == .failed || record.analysisState == .protected {
                runPipeline(for: record)   // retry a stale failure
            }
        } else {
            let src = AppDirectories.documentsDirectory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: src.path) else {
                print("[DemoFile] missing \(src.path)")
                return nil
            }
            let ext = src.pathExtension.isEmpty ? "mp3" : src.pathExtension
            let destName = UUID().uuidString + "." + ext
            let destURL = AppDirectories.songsDirectory.appendingPathComponent(destName)
            do {
                try FileManager.default.copyItem(at: src, to: destURL)
            } catch {
                print("[DemoFile] copy failed: \(error)")
                return nil
            }
            let metadata = await AudioMetadataLoader.load(from: destURL)
            let newRecord = SongRecord(
                title: metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? src.deletingPathExtension().lastPathComponent,
                artist: metadata.artist ?? "Unknown Artist",
                fileName: destName,
                duration: metadata.duration > 0 ? metadata.duration : 0,
                artworkData: metadata.artworkData)
            newRecord.sourceKind = .file
            context.insert(newRecord)
            try? context.save()
            runPipeline(for: newRecord)
            record = newRecord
        }
        return await sessionForReadyRecord(record)
    }

    /// Shared "wait for analysis → build playable session" step used by the
    /// synthetic demo song AND real imported files (launch-arg paths).
    private func sessionForReadyRecord(_ record: SongRecord)
        async -> (record: SongRecord, session: GameSession)? {
        for _ in 0..<900 {   // up to ~225 s for analysis + chart generation (long MP3s)
            if record.analysisState == .ready { break }
            if record.analysisState == .failed || record.analysisState == .protected {
                print("[DemoFile] analysis failed: \(record.errorMessage ?? "unknown")")
                return nil
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard record.analysisState == .ready,
              let url = await resolveAudioURL(for: record),
              let chart = try? await ensureChart(for: record, difficulty: demoDifficulty) else {
            print("[DemoFile] session build failed")
            return nil
        }
        let analysis = try? ChartStorage.loadAnalysis(for: record.id)
        var practice = demoPracticeConfig
        if practice != nil, let analysis, analysis.sections.indices.contains(demoPracticeSectionIndex) {
            let s = analysis.sections[demoPracticeSectionIndex]
            practice?.section = PracticeSection(id: s.index, label: s.label.displayName,
                                                start: s.start, end: s.end, energy: s.energy)
        }
        if ProcessInfo.processInfo.arguments.contains("-demoQueue"), queue.entries.isEmpty {
            // Demo the automatic-transition path: the same song queued at two
            // difficulties follows the first session automatically.
            queue.add(QueueEntry(songID: record.id, title: record.title, artist: record.artist,
                                 difficulty: .easy))
            queue.add(QueueEntry(songID: record.id, title: record.title, artist: record.artist,
                                 difficulty: .expert))
        }
        return (record, GameSession(chart: chart, analysis: analysis, audioURL: url,
                                    title: record.title, practice: practice))
    }

    /// Practice options for `-demoAutoplay` runs: `-demoPracticeSpeed 0.5`,
    /// `-demoPracticeSection N` (analysis section index), `-demoPracticeLoop`.
    private var demoPracticeConfig: PracticeConfig? {
        let args = ProcessInfo.processInfo.arguments
        var config = PracticeConfig()
        var present = false
        if let idx = args.firstIndex(of: "-demoPracticeSpeed"), idx + 1 < args.count,
           let speed = Double(args[idx + 1]) {
            config.speed = min(max(speed, 0.5), 1.0)
            present = true
        }
        if let idx = args.firstIndex(of: "-demoPracticeSection"), idx + 1 < args.count,
           let section = Int(args[idx + 1]) {
            demoPracticeSectionIndex = section
            present = true
        }
        if args.contains("-demoPracticeLoop") {
            config.loopSection = true
            present = true
        }
        return present ? config : nil
    }

    private var demoPracticeSectionIndex = 0

    /// Difficulty for `-demoAutoplay` runs, from the `-demoDifficulty` launch
    /// argument (easy | normal | hard | expert | extreme). Defaults to hard.
    private var demoDifficulty: DifficultyLevel {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-demoDifficulty"), idx + 1 < args.count else {
            return .hard
        }
        switch args[idx + 1].lowercased() {
        case "easy": return .easy
        case "normal", "medium": return .medium
        case "hard": return .hard
        case "expert": return .expert
        case "extreme": return .extreme
        default: return .hard
        }
    }

    private func fileRecord(named fileName: String) -> SongRecord? {
        let predicate = #Predicate<SongRecord> { $0.fileName == fileName }
        var descriptor = FetchDescriptor<SongRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
    #endif

    // MARK: - Deletion

    /// Removes the record + artifacts. Only file-imported songs own an audio
    /// copy in the sandbox; library songs are never deleted from the user's
    /// Music library.
    func deleteSong(_ record: SongRecord) {
        // Invalidate any in-flight analysis/chart work for this song so its
        // callbacks stop before touching state, then drop its bookkeeping.
        _ = beginPipeline(for: record.id)
        pipelineTracker.forget(for: record.id)
        // Remove the song from the queue (never leave a dangling entry).
        queue.removeAll(songID: record.id)
        // Remove it from every playlist (no dangling playlist entries).
        playlists.removeSongFromAll(record.id)
        // Remove its statistics (re-import starts fresh; nothing is orphaned).
        stats.removeSong(record.id)
        ResultsStorage.deleteAll(for: record.id)
        if record.sourceKind == .file {
            AudioImporter.deleteFile(named: record.fileName)
        }
        ChartStorage.deleteAllCharts(for: record.id)
        ChartStorage.deleteAnalysis(for: record.id)
        context.delete(record)
        try? context.save()
    }

    // MARK: - Helpers

    private func analysisOrLoad(songID: UUID, existing: AudioAnalysis?) async throws -> AudioAnalysis {
        if let existing { return existing }
        guard let loaded = try await Task.detached(operation: { try ChartStorage.loadAnalysis(for: songID) }).value else {
            throw AnalysisError.analysisMissing
        }
        return loaded
    }

    private func fetchRecord(_ songID: UUID) -> SongRecord? {
        let predicate = #Predicate<SongRecord> { $0.id == songID }
        var descriptor = FetchDescriptor<SongRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Structural sanity for a cached chart: version matches, every note is
    /// finite with a valid lane and non-negative in-song time, ids unique.
    private static func isWellFormed(_ chart: Chart) -> Bool {
        var ids = Set<Int>()
        for note in chart.notes {
            guard note.time.isFinite, note.time >= 0, note.duration.isFinite, note.duration >= 0,
                  (0..<4).contains(note.lane), note.strength.isFinite,
                  ids.insert(note.id).inserted else { return false }
        }
        return !chart.notes.isEmpty
    }

    private func failPipeline(songID: UUID, message: String, error: Error? = nil, probeAudio: Bool = false) {
        guard let record = fetchRecord(songID) else { return }
        record.analysisState = .failed
        record.errorMessage = message
        #if DEBUG
        if let analysisError = error as? AnalysisError, let detail = analysisError.debugDetail {
            print("Audio analysis failed — \(detail)")
        } else if let chartError = error as? ChartGenerationError, let detail = chartError.debugDetail {
            print("Chart generation failed — \(detail)")
        } else if let error {
            let ns = error as NSError
            print("Audio analysis failed — \(ns.domain) (\(ns.code)) \(ns.localizedDescription)")
        }
        if probeAudio, let id = record.mediaLibraryPersistentID {
            Task { _ = await AudioProbe.report(persistentID: id) }
        }
        #endif
        try? context.save()
    }

    /// Stable per-(song, difficulty) seed → identical charts every
    /// regeneration, with each difficulty being a distinct arrangement.
    private static func seed(for songID: UUID, difficulty: DifficultyLevel) -> UInt64 {
        var h: UInt64 = 0xC0FFEE
        for byte in songID.uuidString.utf8 {
            h = h &* 31 &+ UInt64(byte)
        }
        for byte in difficulty.rawValue.utf8 {
            h = h &* 31 &+ UInt64(byte)
        }
        return h
    }
}