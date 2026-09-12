import AVFoundation
import XCTest
@testable import Music_Haptics

/// Performance benchmark harness. Prints `BENCH <metric>: <value>` lines for
/// every measurement; assertions only sanity-check correctness. Run with:
///   swift test --filter PerfBenchTests
@MainActor
final class PerfBenchTests: XCTestCase {

    nonisolated(unsafe) private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerfBench-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        AppDirectories.testRootOverride = tempRoot
    }

    override func tearDown() {
        AppDirectories.testRootOverride = nil
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func time(_ name: String, _ work: () -> Void) {
        let start = ContinuousClock.now
        work()
        let elapsed = start.duration(to: .now)
        print(String(format: "BENCH %@: %.1f ms", name, elapsed.timeInterval * 1000))
    }

    private func timeAsync(_ name: String, _ work: () async throws -> Void) async rethrows {
        let start = ContinuousClock.now
        try await work()
        let elapsed = start.duration(to: .now)
        print(String(format: "BENCH %@: %.1f ms", name, elapsed.timeInterval * 1000))
    }

    // MARK: - Synthetic analysis (chart generator + friends)

    private func metronomeAnalysis(bpm: Double, seconds: Double) -> AudioAnalysis {
        let interval = 60.0 / bpm
        var beats: [Beat] = []
        var events: [MusicalEvent] = []
        var t = 0.0
        var i = 0
        while t < seconds {
            let strong = i % 4 == 0
            beats.append(Beat(time: t, strength: strong ? 0.95 : 0.5, isStrong: strong))
            events.append(MusicalEvent(time: t, strength: strong ? 0.9 : 0.5, confidence: 0.8,
                                       type: .kickLike, lowEnergy: 0.7, midEnergy: 0.2, highEnergy: 0.1,
                                       isOnBeat: true, beatStrength: strong ? 0.95 : 0.5,
                                       sectionIndex: 0, importance: strong ? 0.9 : 0.5))
            t += interval
            i += 1
        }
        return AudioAnalysis(duration: seconds, sampleRate: 44100, tempoBPM: bpm, tempoConfidence: 0.9,
                             beats: beats, onsets: [], events: events,
                             sections: [SongSection(index: 0, start: 0, end: seconds, label: .generic, energy: 1.0)],
                             waveform: [], averageEnergy: 0.5, analysisDuration: 0.1, hopTime: 512.0 / 44100.0)
    }

    func testBenchChartGeneration() async throws {
        for (name, seconds) in [("1min", 60.0), ("3min", 180.0), ("5min", 300.0), ("10min", 600.0)] {
            let analysis = metronomeAnalysis(bpm: 120, seconds: seconds)
            try await timeAsync("chartgen-\(name)-x4difficulties") {
                for difficulty in [DifficultyLevel.easy, .medium, .hard, .expert] {
                    _ = try await ChartGenerator().generate(
                        analysis: analysis, songID: UUID(),
                        request: ChartGenerator.Request(difficulty: difficulty, densityMultiplier: 1.0, seed: 7))
                }
            }
            print("BENCH chartgen-\(name)-candidates: \(analysis.events.count)")
        }
    }

    // MARK: - Full audio analysis (real WAV decode + DSP)

    private func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let dataSize = samples.count * 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        func le<T>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v) { Array($0) } }
        data.append(contentsOf: le(UInt32(36 + dataSize)))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(contentsOf: le(UInt32(16)))
        data.append(contentsOf: le(UInt16(1)))
        data.append(contentsOf: le(UInt16(1)))
        data.append(contentsOf: le(UInt32(sampleRate)))
        data.append(contentsOf: le(UInt32(sampleRate * 2)))
        data.append(contentsOf: le(UInt16(2)))
        data.append(contentsOf: le(UInt16(16)))
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: le(UInt32(dataSize)))
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            pcm.append(contentsOf: le(v))
        }
        data.append(pcm)
        try data.write(to: url)
    }

    func testBenchAudioAnalysis() async throws {
        for (name, seconds) in [("1min", 60.0), ("3min", 180.0), ("5min", 300.0), ("10min", 600.0)] {
            let url = tempRoot.appendingPathComponent("bench-\(name).wav")
            let samples = metronomeSamples(bpm: 120, seconds: seconds)
            try writeWAV(samples, sampleRate: 44100, to: url)
            var analysisDuration: Double = 0
            try await timeAsync("analyze-\(name)") {
                let a = try await AudioAnalyzer().analyze(url: url)
                analysisDuration = a.analysisDuration
                XCTAssertGreaterThan(a.beats.count, 0)
            }
            print(String(format: "BENCH analyze-\(name)-realtime-factor: %.2fx", seconds / max(0.001, analysisDuration)))
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func metronomeSamples(bpm: Double, seconds: Double, sampleRate: Double = 44100) -> [Float] {
        let count = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: count)
        let beatInterval = 60.0 / bpm
        let clickLen = Int(0.03 * sampleRate)
        var t = 0.0
        while t < seconds {
            let start = Int(t * sampleRate)
            if start < count {
                for k in 0..<min(clickLen, count - start) {
                    let phase = Double(k) / sampleRate
                    samples[start + k] = Float(sin(2 * .pi * 1000 * phase) * exp(-phase * 120))
                }
            }
            t += beatInterval
        }
        return samples
    }

    // MARK: - Artwork analysis (pure palette; theme factory is UIKit-only)

    func testBenchArtworkAnalysis() {
        var rng = SplitMix64(state: 42)
        let small = (0..<(24 * 24 * 4)).map { _ in UInt8(rng.next() >> 56) }
        time("palette-24x24") {
            _ = ArtworkPaletteAnalyzer.analyze(pixels: small, width: 24)
        }
        let large = (0..<(512 * 512 * 4)).map { _ in UInt8(rng.next() >> 56) }
        time("palette-512x512") {
            _ = ArtworkPaletteAnalyzer.analyze(pixels: large, width: 512)
        }
    }

    // MARK: - Library filtering at scale

    func testBenchLibraryFiltering() {
        for (name, count) in [("10k", 10_000), ("50k", 50_000)] {
            var songs: [LibrarySong] = []
            var records: [UInt64: SongRecordSnapshot] = [:]
            for i in 0..<count {
                let id = UInt64(i + 1)
                songs.append(LibrarySong(persistentID: id, title: "Song \(i) \(["Alpha", "Beta", "Gamma"][i % 3])",
                                         artist: "Artist \(i % 97)", albumTitle: "Album \(i % 13)",
                                         duration: Double(i % 400 + 30),
                                         hasProtectedAsset: i % 11 == 0,
                                         dateAdded: Date(timeIntervalSince1970: Double(i)),
                                         lastPlayedDate: i % 7 == 0 ? Date(timeIntervalSince1970: Double(i)) : nil))
                if i % 5 == 0 {
                    records[id] = SongRecordSnapshot(persistentID: id, isChartReady: i % 10 == 0,
                                                     difficultyLevel: .medium, difficultyScore: Double(i % 10))
                }
            }
            time("filter-\(name)-search") {
                _ = MusicLibraryFiltering.search(songs, text: "song 4")
            }
            time("filter-\(name)-sort-filter") {
                _ = MusicLibraryFiltering.apply(songs, searchText: "beta",
                                                sort: .difficulty,
                                                filters: LibraryFilters(analysis: .analyzed,
                                                                        availability: .accessible,
                                                                        difficultyRange: 3...7),
                                                records: records)
            }
            time("filter-\(name)-sort-title") {
                _ = MusicLibraryFiltering.sorted(songs, by: .title, records: records)
            }
        }
    }

    // MARK: - Persistence churn

    func testBenchPersistence() throws {
        let songID = UUID()
        time("chart-save-load-x100") {
            do {
                for i in 0..<100 {
                    let chart = Chart(songID: songID, difficulty: .medium, chartVersion: ChartStorage.chartVersion,
                                      seed: UInt64(i), notes: [ChartNote(id: 0, time: 1, lane: 0, duration: 0, type: .tap, strength: 1)],
                                      generatedAt: Date(), nps: 1, duration: 10, difficultyScore: 3,
                                      validationWarnings: [], generationDuration: 0)
                    try ChartStorage.save(chart, for: songID)
                    _ = try ChartStorage.loadChart(for: songID, difficulty: .medium)
                }
            } catch {
                XCTFail("\(error)")
            }
        }
        let queue = QueueManager(seed: 1)
        for i in 0..<1000 {
            queue.add(QueueEntry(songID: UUID(), title: "s\(i)", artist: "a", difficulty: .medium))
        }
        time("queue-snapshot-save-load-x50") {
            for _ in 0..<50 {
                QueueStorage.save(queue.snapshot())
                _ = QueueStorage.load()
            }
        }
        time("queue-reorder-x200") {
            for _ in 0..<200 {
                queue.move(fromOffsets: IndexSet(integer: Int.random(in: 0..<1000)),
                           toOffset: Int.random(in: 0..<1000))
            }
        }
    }

    // MARK: - Gameplay per-frame simulation (60 Hz over long charts)

    func testBenchGameplayLoop() async throws {
        for (name, seconds) in [("1min", 60.0), ("3min", 180.0), ("5min", 300.0), ("10min", 600.0)] {
            let analysis = metronomeAnalysis(bpm: 120, seconds: seconds)
            let chart = try await ChartGenerator().generate(
                analysis: analysis, songID: UUID(),
                request: ChartGenerator.Request(difficulty: .hard, densityMultiplier: 1.0, seed: 3)).chart
            let scheduler = NoteScheduler(chart: chart)
            let frameCount = Int(seconds * 60)
            time("gameplay-60hz-\(name)") {
                var judged = 0
                for frame in 0..<frameCount {
                    let t = Double(frame) / 60.0
                    _ = scheduler.notes(in: (t - 2.6)...(t + 3.0))
                    if frame % 30 == 0, let hit = scheduler.nearest(in: frame % 4, to: t, window: 0.25) {
                        scheduler.mark(hit.index, judgment: .perfect)
                        judged += 1
                    }
                    _ = scheduler.pendingMisses(before: t, window: 0.2)
                }
                XCTAssertGreaterThan(judged, 0)
            }
        }
    }

    // MARK: - AI feature extraction + fusion at chart scale

    func testBenchAIFeatures() async throws {
        let analysis = metronomeAnalysis(bpm: 120, seconds: 300)
        let chart = try await ChartGenerator().generate(
            analysis: analysis, songID: UUID(),
            request: ChartGenerator.Request(difficulty: .hard, densityMultiplier: 1.0, seed: 3)).chart
        let metrics = DifficultyMetrics(score10: 5, label: .hard, notesPerSecond: chart.nps,
                                        averageInterval: 0.5, maxBurstNPS: 8, simultaneityRatio: 0.2,
                                        averageJumpDistance: 1.4, alternationRatio: 0.4,
                                        intervalStdDev: 0.2, spikeRatio: 2.0, sustainedNPS: 6)
        time("ai-features-difficulty-x10") {
            for _ in 0..<10 {
                _ = DifficultyFeatureExtractor.extract(notes: chart.notes, metrics: metrics, analysis: analysis)
            }
        }
        time("ai-features-events-\(analysis.events.count)") {
            let events = analysis.events
            let ctx = EventFeatureExtractor.context(for: analysis)
            for (i, event) in events.enumerated() {
                _ = EventFeatureExtractor.extract(event, index: i, events: events, ctx: ctx)
            }
        }
        time("ai-fusion-x10000") {
            for i in 0..<10_000 {
                _ = AIDifficultyFusion.fuse(deterministic: 5.0, ai: i % 2 == 0 ? 6.0 : nil,
                                            config: AIFusionConfig.default)
            }
        }
    }
}

extension Duration {
    var timeInterval: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}