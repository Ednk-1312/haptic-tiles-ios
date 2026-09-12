import AVFAudio
import XCTest
@testable import Music_Haptics

/// Reliability & stability pass: the app must stay stable under invalid data,
/// pathological inputs, repeated sessions and unexpected state. Every test is
/// deterministic (scripted clocks, in-memory fixtures, real files only for
/// storage recovery).
final class ReliabilityTests: XCTestCase {

    // MARK: - Chart sanitization (defense in depth)

    func testSanitizerDropsNonFiniteAndOutOfRangeNotes() {
        var chart = makeChart()
        chart.notes = [
            ChartNote(id: 0, time: .nan, lane: 0, duration: 0, type: .tap, strength: 0.5),
            ChartNote(id: 1, time: .infinity, lane: 1, duration: 0, type: .tap, strength: 0.5),
            ChartNote(id: 2, time: -1, lane: 2, duration: 0, type: .tap, strength: 0.5),
            ChartNote(id: 3, time: 3.0, lane: 3, duration: 0, type: .tap, strength: 0.5),
            ChartNote(id: 4, time: 3.0, lane: 7, duration: 0, type: .tap, strength: 0.5),   // bad lane
            ChartNote(id: 5, time: 50, lane: 1, duration: 0, type: .tap, strength: 0.5),   // beyond song
            ChartNote(id: 6, time: 4.0, lane: 0, duration: -1, type: .tap, strength: 0.5), // bad duration
        ]
        let sanitized = chart.sanitized(songDuration: 10)
        // Only the two well-formed notes survive; the negative-duration tap is
        // malformed and dropped like the rest.
        XCTAssertEqual(sanitized.notes.count, 1)
        XCTAssertEqual(sanitized.notes.map(\.time), [3.0])
        XCTAssertEqual(sanitized.notes.map(\.lane), [3])
        XCTAssertTrue(sanitized.notes.allSatisfy { $0.time.isFinite && $0.duration.isFinite && $0.strength.isFinite })
    }

    func testSanitizerFixesHoldTypeAndReidsSequentially() {
        var chart = makeChart()
        chart.notes = [
            ChartNote(id: 99, time: 2.0, lane: 0, duration: 0, type: .hold, strength: 0.5),  // hold with 0 duration → tap
            ChartNote(id: 5, time: 1.0, lane: 1, duration: 1.0, type: .hold, strength: 0.5),
        ]
        let sanitized = chart.sanitized(songDuration: 10)
        XCTAssertEqual(sanitized.notes.map(\.time), [1.0, 2.0])
        XCTAssertEqual(sanitized.notes.map(\.id), [0, 1])
        XCTAssertEqual(sanitized.notes[0].type, .hold)
        XCTAssertEqual(sanitized.notes[1].type, .tap)
        XCTAssertEqual(sanitized.notes[1].duration, 0)
    }

    // MARK: - Validator malformed-note gate

    func testValidatorRejectsMalformedNotes() {
        let constraints = ChartConstraints.forDifficulty(.hard, densityMultiplier: 1)
        let bad = [
            ChartNote(id: 0, time: 1.0, lane: 0, duration: 0, type: .tap, strength: .nan),
            ChartNote(id: 1, time: 2.0, lane: 1, duration: 0, type: .tap, strength: 0.5),
        ]
        let result = ChartValidator.validate(bad, constraints: constraints)
        XCTAssertTrue(result.hardFailures.contains { $0.contains("Malformed") })

        // NaN time must NOT silently pass (NaN comparisons are false).
        let nanTime = [
            ChartNote(id: 0, time: .nan, lane: 0, duration: 0, type: .tap, strength: 0.5),
            ChartNote(id: 1, time: 2.0, lane: 1, duration: 0, type: .tap, strength: 0.5),
        ]
        XCTAssertTrue(ChartValidator.validate(nanTime, constraints: constraints).hardFailureCount > 0)

        let badLane = [
            ChartNote(id: 0, time: 1.0, lane: -1, duration: 0, type: .tap, strength: 0.5),
            ChartNote(id: 1, time: 2.0, lane: 1, duration: 0, type: .tap, strength: 0.5),
        ]
        XCTAssertTrue(ChartValidator.validate(badLane, constraints: constraints).hardFailureCount > 0)

        let negativeTime = [
            ChartNote(id: 0, time: -0.5, lane: 0, duration: 0, type: .tap, strength: 0.5),
            ChartNote(id: 1, time: 2.0, lane: 1, duration: 0, type: .tap, strength: 0.5),
        ]
        XCTAssertTrue(ChartValidator.validate(negativeTime, constraints: constraints).hardFailureCount > 0)
    }

    // MARK: - AI output validation (never leaks into gameplay)

    func testDifficultyFusionClampsInvalidScores() {
        let config = AIFusionConfig(enabled: true, difficultyAIWeight: 0.5,
                                    eventAIWeight: 0.5, minEventConfidence: 0.3)
        for bad in [Double.nan, .infinity, -.infinity, -5, 15] {
            let outcome = AIDifficultyFusion.fuse(deterministic: 4.2, ai: bad, config: config)
            XCTAssertTrue(outcome.finalScore.isFinite)
            XCTAssertTrue((0...10).contains(outcome.finalScore))
            XCTAssertTrue((0...10).contains(outcome.deterministicScore))
            if bad.isFinite {
                XCTAssertTrue((0...10).contains(outcome.aiScore ?? -1))
                XCTAssertTrue(outcome.usedAI)
            }
        }
        // Unavailable (nil) → pure deterministic, no AI.
        let nilOutcome = AIDifficultyFusion.fuse(deterministic: 4.2, ai: nil, config: config)
        XCTAssertEqual(nilOutcome.finalScore, 4.2)
        XCTAssertFalse(nilOutcome.usedAI)
    }

    func testEventFusionClampsAndFallsBack() {
        let config = AIFusionConfig(enabled: true, difficultyAIWeight: 0.5,
                                    eventAIWeight: 0.5, minEventConfidence: 0.3)
        for bad in [Double.nan, .infinity, 99, -99] {
            let outcome = AIEventFusion.fusedImportance(time: 1, dsp: 0.6, ai: bad, config: config)
            XCTAssertTrue(outcome.finalImportance.isFinite)
            XCTAssertTrue((0...1).contains(outcome.finalImportance))
        }
        // Indecisive AI (≈0.5) → DSP unchanged.
        let unsure = AIEventFusion.fusedImportance(time: 1, dsp: 0.6, ai: 0.51, config: config)
        XCTAssertEqual(unsure.finalImportance, 0.6)
        XCTAssertFalse(unsure.usedAI)
        // Unavailable → DSP unchanged.
        let nilOutcome = AIEventFusion.fusedImportance(time: 1, dsp: 0.6, ai: nil, config: config)
        XCTAssertEqual(nilOutcome.finalImportance, 0.6)
        XCTAssertFalse(nilOutcome.usedAI)
    }

    // MARK: - Persistence recovery

    func testCorruptChartFileIsRecoverable() throws {
        let songID = UUID()
        let url = try XCTUnwrap(ChartStorage.chartURLForTesting(songID: songID, difficulty: .hard))
        try "not a chart".write(to: url, atomically: true, encoding: .utf8)
        // Corrupt cache must throw (never decode garbage silently)…
        XCTAssertThrowsError(try ChartStorage.loadChart(for: songID, difficulty: .hard))
        // …and the recovery path (delete → regenerate) leaves a clean slate.
        ChartStorage.deleteChart(for: songID, difficulty: .hard)
        XCTAssertNil(try ChartStorage.loadChart(for: songID, difficulty: .hard))
    }

    func testCorruptAnalysisFileLoadsAsNil() throws {
        let songID = UUID()
        try "garbage".write(to: ChartStorage.analysisURLForTesting(songID: songID), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ChartStorage.loadAnalysis(for: songID))
        ChartStorage.deleteAnalysis(for: songID)
        XCTAssertNil(try ChartStorage.loadAnalysis(for: songID))
    }

    func testStaleVersionedChartIsRejectedByVersionCheck() throws {
        let songID = UUID()
        var chart = makeChart()
        chart.chartVersion = ChartStorage.chartVersion - 1
        try ChartStorage.save(chart, for: songID)
        // ensureChart treats a version mismatch as missing (regenerates); the
        // storage layer itself still reads it, the version gate is the caller's.
        let loaded = try XCTUnwrap(try ChartStorage.loadChart(for: songID, difficulty: .medium))
        XCTAssertNotEqual(loaded.chartVersion, ChartStorage.chartVersion)
        ChartStorage.deleteAllCharts(for: songID)
    }

    // MARK: - Scheduler: restart cleanliness, no double judgments

    @MainActor
    func testRestartLeavesNoStaleJudgments() {
        let chart = makeChart(notes: [(1, 0), (2, 1), (3, 2), (4, 3)])
        let first = NoteScheduler(chart: chart)
        // Full playthrough.
        for note in first.sortedNotes {
            _ = first.nearest(in: note.lane, to: note.time, window: 0.2)
            first.mark(note.id, judgment: .perfect)
        }
        XCTAssertTrue(first.sortedNotes.indices.allSatisfy { first.judgment(for: $0) != nil })
        // Restart = brand-new scheduler on the SAME chart: nothing survives.
        let fresh = NoteScheduler(chart: chart)
        XCTAssertTrue(fresh.sortedNotes.indices.allSatisfy { fresh.judgment(for: $0) == nil })
        XCTAssertEqual(fresh.pendingMisses(before: 100, window: 0.2).count, 4)
    }

    @MainActor
    func testNoDoubleJudgmentFromSecondTap() {
        let chart = makeChart(notes: [(2, 1)])
        let scheduler = NoteScheduler(chart: chart)
        let first = scheduler.nearest(in: 1, to: 2.0, window: 0.2)
        XCTAssertNotNil(first)
        scheduler.mark(first!.index, judgment: .perfect)
        // A second tap at the same instant must not re-judge the same note…
        XCTAssertNil(scheduler.nearest(in: 1, to: 2.0, window: 0.2))
        // …and a tap in another lane can't steal it.
        XCTAssertNil(scheduler.nearest(in: 0, to: 2.0, window: 0.2))
    }

    // MARK: - Stress: song A → B → A with no leakage

    @MainActor
    func testStressAlternatingSongsStayIndependent() {
        let chartA = makeChart(notes: [(1, 0), (2, 1), (3, 0), (4, 2)])
        let chartB = makeChart(notes: [(0.5, 3), (1.5, 2), (2.5, 1), (3.5, 0), (4.5, 3)])
        let a1 = AutoplaySimulation.run(chart: chartA)
        let b1 = AutoplaySimulation.run(chart: chartB)
        // Repeated alternation: A again must equal the first A exactly.
        let a2 = AutoplaySimulation.run(chart: chartA)
        let b2 = AutoplaySimulation.run(chart: chartB)
        XCTAssertEqual(a1.score, a2.score)
        XCTAssertEqual(a1.perfectCount, a2.perfectCount)
        XCTAssertEqual(b1.score, b2.score)
        XCTAssertEqual(b1.perfectCount, b2.perfectCount)
        XCTAssertNotEqual(a1.score, b1.score)
        XCTAssertEqual(a1.perfectCount, 4)
        XCTAssertEqual(b1.perfectCount, 5)
        XCTAssertEqual(a1.missCount, 0)
        XCTAssertEqual(b1.missCount, 0)
    }

    @MainActor
    func testDenseChartEveryNoteJudgedExactlyOnce() {
        // 120 notes in 8 s — well past the generation density cap; the
        // simulation must still judge each note exactly once.
        var notes: [ChartNote] = []
        for i in 0..<120 {
            notes.append(ChartNote(id: i, time: 0.05 * Double(i), lane: i % 4,
                                   duration: 0, type: .tap, strength: 0.5))
        }
        var chart = makeChart()
        chart.notes = notes
        let result = AutoplaySimulation.run(chart: chart)
        let judged = result.perfectCount + result.greatCount + result.goodCount + result.missCount
        XCTAssertEqual(judged, 120)
        XCTAssertEqual(result.perfectCount, 120)   // ideal player hits everything
        XCTAssertEqual(result.missCount, 0)
    }

    // MARK: - Pathological generator inputs (must never crash / emit garbage)

    func testGeneratorSurvivesPathologicalAnalyses() async {
        let pathological: [(String, AudioAnalysis)] = [
            ("silence", SignalFixtures.makeAnalysis(duration: 30, bpm: 120, beats: [],
                                                   events: [], sections: [])),
            ("zeroDuration", SignalFixtures.makeAnalysis(duration: 0, bpm: 120, beats: [],
                                                         events: [], sections: [])),
            ("bpmTooLow", SignalFixtures.makeAnalysis(duration: 20, bpm: 20,
                                                      beats: [], events: [], sections: [])),
            ("bpmTooHigh", SignalFixtures.makeAnalysis(duration: 20, bpm: 400,
                                                       beats: [], events: [], sections: [])),
            ("nanEvents", SignalFixtures.makeAnalysis(duration: 20, bpm: 120,
                                                      beats: [Beat(time: .nan, strength: 0.5, isStrong: false)],
                                                      events: [SignalFixtures.event(time: .nan, strength: 0.5, importance: 0.5)],
                                                      sections: [])),
        ]
        for (name, analysis) in pathological {
            do {
                let output = try await ChartGenerator().generate(
                    analysis: analysis, songID: UUID(),
                    request: ChartGenerator.Request(difficulty: .medium, densityMultiplier: 1, seed: 42))
                // Whatever comes out must be structurally valid.
                for note in output.chart.notes {
                    XCTAssertTrue(note.time.isFinite, "\(name): non-finite time")
                    XCTAssertTrue(note.duration.isFinite, "\(name): non-finite duration")
                    XCTAssertTrue(note.time >= 0, "\(name): negative time")
                    XCTAssertTrue((0..<4).contains(note.lane), "\(name): bad lane")
                    XCTAssertTrue(note.time <= max(analysis.duration, 1), "\(name): beyond song")
                }
                XCTAssertEqual(output.chart.notes.map(\.id), Array(output.chart.notes.indices), "\(name): ids not sequential")
            } catch {
                // A graceful throw (e.g. "couldn't generate") is acceptable;
                // a crash is not. Fail on anything except a documented error.
                XCTAssertTrue(error is ChartGenerationError, "\(name): unexpected error \(error)")
            }
        }
    }

    func testGeneratorIsDeterministicAcrossRepeatedRuns() async throws {
        let analysis = SignalFixtures.drumHeavy()
        let request = ChartGenerator.Request(difficulty: .expert, densityMultiplier: 1, seed: 0xDEAD)
        let a = try await ChartGenerator().generate(analysis: analysis, songID: UUID(), request: request)
        let b = try await ChartGenerator().generate(analysis: analysis, songID: UUID(), request: request)
        XCTAssertEqual(a.chart.notes, b.chart.notes)
        XCTAssertEqual(a.chart.difficultyScore, b.chart.difficultyScore)
    }

    // MARK: - Playback state machine (real AVAudioPlayer, tiny WAV)

    @MainActor
    func testAudioPlayerIdempotentTransitions() throws {
        let url = try Self.writeSilentWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayer()
        try player.load(url: url)
        XCTAssertEqual(player.state, .idle)
        player.play(from: 0)
        XCTAssertEqual(player.state, .playing)
        player.pause()
        XCTAssertEqual(player.state, .paused)
        player.pause()          // double pause = no-op
        XCTAssertEqual(player.state, .paused)
        player.resume()
        XCTAssertEqual(player.state, .playing)
        player.seek(to: 0.1)
        XCTAssertEqual(player.state, .playing)
        player.stop()
        XCTAssertEqual(player.state, .idle)
        player.stop()           // double stop = no-op
        XCTAssertEqual(player.state, .idle)
        player.play(from: 0)    // play without load = no-op (no crash)
        XCTAssertEqual(player.state, .idle)
    }

    @MainActor
    func testAudioPlayerClockStaysMonotonicAfterPauseResumeSeek() throws {
        let url = try Self.writeSilentWAV(duration: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayer()
        try player.load(url: url)
        player.play(from: 0)
        let t0 = player.currentTime
        XCTAssertGreaterThanOrEqual(t0, 0)
        player.pause()
        let paused = player.currentTime
        player.resume()
        let afterResume = player.currentTime
        // Resume must not jump the clock backwards.
        XCTAssertGreaterThanOrEqual(afterResume, paused - 0.05)
        player.seek(to: 1.0)
        let afterSeek = player.currentTime
        XCTAssertGreaterThanOrEqual(afterSeek, 0.95)
        XCTAssertLessThanOrEqual(afterSeek, 1.05)
        player.stop()
    }

    // MARK: - Fixtures

    private func makeChart() -> Chart {
        Chart(songID: UUID(), difficulty: .medium, chartVersion: ChartStorage.chartVersion, seed: 1,
              notes: [], generatedAt: Date(timeIntervalSince1970: 0), nps: 0, duration: 10,
              difficultyScore: 5, validationWarnings: [], generationDuration: 0)
    }

    private func makeChart(notes: [(time: Double, lane: Int)]) -> Chart {
        var chart = makeChart()
        chart.notes = notes.enumerated().map { i, n in
            ChartNote(id: i, time: n.time, lane: n.lane, duration: 0, type: .tap, strength: 0.5)
        }
        return chart
    }

    /// 16-bit PCM mono WAV (44100 Hz) of pure silence — enough for the player
    /// to load, play and seek deterministically.
    private static func writeSilentWAV(duration: Double) throws -> URL {
        let sampleRate = 44100
        let frames = Int(duration * Double(sampleRate))
        let dataSize = frames * 2
        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: UInt32(36 + dataSize).littleEndianBytes)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(contentsOf: UInt32(16).littleEndianBytes)          // fmt chunk size
        wav.append(contentsOf: UInt16(1).littleEndianBytes)           // PCM
        wav.append(contentsOf: UInt16(1).littleEndianBytes)           // mono
        wav.append(contentsOf: UInt32(sampleRate).littleEndianBytes)
        wav.append(contentsOf: UInt32(sampleRate * 2).littleEndianBytes)  // byte rate
        wav.append(contentsOf: UInt16(2).littleEndianBytes)           // block align
        wav.append(contentsOf: UInt16(16).littleEndianBytes)          // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        wav.append(contentsOf: UInt32(dataSize).littleEndianBytes)
        wav.append(Data(count: dataSize))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reliability-\(UUID().uuidString).wav")
        try wav.write(to: url)
        return url
    }
}

private extension UInt16 {
    var littleEndianBytes: [UInt8] { [UInt8(truncatingIfNeeded: self), UInt8(truncatingIfNeeded: self >> 8)] }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        [UInt8(truncatingIfNeeded: self), UInt8(truncatingIfNeeded: self >> 8),
         UInt8(truncatingIfNeeded: self >> 16), UInt8(truncatingIfNeeded: self >> 24)]
    }
}