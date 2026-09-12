import XCTest
@testable import Music_Haptics

/// Chart-quality suite: charts across very different musical material must be
/// musical and playable — never onset dumps — and always deterministic.
final class ChartQualityTests: XCTestCase {

    // MARK: - Helpers

    private func generate(_ analysis: AudioAnalysis, difficulty: DifficultyLevel,
                          densityMultiplier: Double = 1.0, seed: UInt64 = 11) async throws -> ChartGenerator.Output {
        try await ChartGenerator().generate(
            analysis: analysis, songID: UUID(),
            request: ChartGenerator.Request(difficulty: difficulty, densityMultiplier: densityMultiplier, seed: seed))
    }

    private func validate(_ chart: Chart, difficulty: DifficultyLevel,
                          densityMultiplier: Double = 1.0) -> ValidationResult {
        ChartValidator.validate(chart.notes, constraints: ChartConstraints.forDifficulty(difficulty, densityMultiplier: densityMultiplier))
    }

    private func nps(_ notes: [ChartNote], from: Double, to: Double) -> Double {
        let inRange = notes.filter { $0.time >= from && $0.time <= to }
        return Double(inRange.count) / max(to - from, 0.001)
    }

    private func assertPlayable(_ chart: Chart, difficulty: DifficultyLevel,
                                densityMultiplier: Double = 1.0,
                                _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = validate(chart, difficulty: difficulty, densityMultiplier: densityMultiplier)
        XCTAssertEqual(result.hardFailureCount, 0,
                       "\(message): \(result.hardFailures.joined(separator: "; "))", file: file, line: line)
        for note in chart.notes {
            XCTAssertTrue((0..<4).contains(note.lane), "\(message): lane out of range", file: file, line: line)
        }
    }

    // MARK: - Core promises

    func testDrumHeavyChartIsPlayableAndNotAnOnsetDump() async throws {
        // A constant eighth-note groove: a real chart can go full-groove only
        // at higher difficulties — easy/medium must leave space.
        let analysis = SignalFixtures.drumHeavy()
        let candidates = analysis.events.count
        var counts: [Double] = []
        for difficulty in [DifficultyLevel.easy, .medium, .hard, .extreme] {
            let output = try await generate(analysis, difficulty: difficulty)
            let notes = output.chart.notes
            assertPlayable(output.chart, difficulty: difficulty, "drum-heavy \(difficulty)")
            counts.append(Double(notes.count))
            // v5 onset-first placement puts every note ON an audible event,
            // so the justifiable ceiling sits slightly higher than the old
            // beat-baseline era (1.25); the absolute NPS caps still bind.
            XCTAssertLessThan(Double(notes.count), Double(candidates) * 1.35,
                              "\(difficulty): more notes than the music can justify")
            XCTAssertGreaterThan(notes.count, candidates / 6,
                                 "\(difficulty): chart is too empty for a full drum track")
        }
        // Lower difficulties are deliberately sparser than higher ones.
        XCTAssertLessThan(counts[0], counts[1], "easy must be sparser than medium")
        XCTAssertLessThanOrEqual(counts[1], counts[2], "medium must not exceed hard")
        XCTAssertLessThanOrEqual(counts[2], counts[3], "hard must not exceed extreme")
        // Medium leaves real breathing room (never a transcription dump).
        XCTAssertLessThanOrEqual(counts[1], Double(candidates) * 0.85,
                                 "medium charts nearly every onset of a full drum track")
    }

    func testFastDenseMusicStaysUnderHardCaps() async throws {
        let analysis = SignalFixtures.fastDrumHeavy(bpm: 220)
        let difficulty = DifficultyLevel.extreme
        let output = try await generate(analysis, difficulty: difficulty, densityMultiplier: 1.3)
        assertPlayable(output.chart, difficulty: difficulty, densityMultiplier: 1.3, "fast 220bpm")

        // Validator guarantees no 1s window exceeds the cap; double-check span NPS.
        let notes = output.chart.notes
        let span = max((notes.last?.time ?? 0) - (notes.first?.time ?? 0), 1)
        XCTAssertLessThan(Double(notes.count) / span, difficulty.targetNPS * 2.0,
                          "span NPS must respect the difficulty target")
        XCTAssertLessThan(notes.count, analysis.events.count / 2,
                          "fast dense music must not become an onset dump")
        XCTAssertFalse(notes.isEmpty)
    }

    func testSparseVocalPreservesAccents() async throws {
        let analysis = SignalFixtures.sparseVocal()
        let output = try await generate(analysis, difficulty: .medium)
        assertPlayable(output.chart, difficulty: .medium, "sparse vocal")

        // Strong half-bar accents should mostly survive.
        let accents = analysis.events.filter { $0.importance >= 0.8 }
        let matched = accents.filter { accent in
            output.chart.notes.contains { abs($0.time - accent.time) <= 0.06 }
        }.count
        XCTAssertGreaterThanOrEqual(Double(matched), Double(accents.count) * 0.6,
                                    "too many strong accents dropped")
        // Weak breathy onsets should mostly be skipped.
        let weakOnsets = analysis.events.filter { $0.importance <= 0.15 }
        let weakMatched = weakOnsets.filter { weak in
            output.chart.notes.contains { abs($0.time - weak.time) <= 0.06 }
        }.count
        XCTAssertLessThanOrEqual(Double(weakMatched), Double(weakOnsets.count) * 0.35,
                                 "chart clings to weak onsets")
    }

    func testQuietSectionsBreatheAndLoudSectionsFill() async throws {
        let analysis = SignalFixtures.quietLoud()
        let output = try await generate(analysis, difficulty: .medium)
        assertPlayable(output.chart, difficulty: .medium, "quiet/loud")

        let notes = output.chart.notes
        let quietNPS = nps(notes, from: 4, to: 13)
        let loudNPS = nps(notes, from: 28, to: 58)
        XCTAssertGreaterThan(loudNPS, quietNPS * 1.5,
                             "energetic sections must be noticeably denser (quiet \(String(format: "%.2f", quietNPS)) vs loud \(String(format: "%.2f", loudNPS)))")
        XCTAssertLessThan(quietNPS, 2.6, "quiet sections must stay sparse")
        XCTAssertGreaterThan(loudNPS, 2.0, "loud sections should actually fill")
    }

    func testSimultaneousNotesRespectDifficulty() async throws {
        // Easy allows no chords.
        let easy = try await generate(SignalFixtures.drumHeavy(), difficulty: .easy)
        let easyAnalytics = ChartAnalyticsBuilder.analyze(chart: easy.chart, analysis: SignalFixtures.drumHeavy())
        XCTAssertEqual(easyAnalytics.maxSimultaneous, 1)
        XCTAssertEqual(easyAnalytics.chordGroups, 0)

        // Expert/extreme may use them but never beyond the allowed count.
        for difficulty in [DifficultyLevel.medium, .hard, .expert, .extreme] {
            let output = try await generate(SignalFixtures.drumHeavy(), difficulty: difficulty)
            let analytics = ChartAnalyticsBuilder.analyze(chart: output.chart,
                                                          analysis: SignalFixtures.drumHeavy())
            XCTAssertLessThanOrEqual(analytics.maxSimultaneous, difficulty.maxSimultaneous,
                                     "\(difficulty): simultaneous notes exceed allowed count")
        }
    }

    func testNoRepetitiveExtremeBouncing() async throws {
        let output = try await generate(SignalFixtures.drumHeavy(bpm: 100), difficulty: .medium)
        let analytics = ChartAnalyticsBuilder.analyze(chart: output.chart, analysis: SignalFixtures.drumHeavy(bpm: 100))
        XCTAssertLessThanOrEqual(analytics.maxExtremeBounceRun, 4,
                                 "chart repeatedly bounces 1↔4 (run \(analytics.maxExtremeBounceRun))")
        XCTAssertFalse(output.chart.validationWarnings.contains { $0.contains("bouncing") },
                       "generator produced a flagged bounce pattern")
    }

    func testGenerationIsDeterministicAcrossMaterial() async throws {
        let materials: [(String, AudioAnalysis)] = [
            ("drum", SignalFixtures.drumHeavy(bpm: 128, seconds: 30)),
            ("fast", SignalFixtures.fastDrumHeavy()),
            ("sparse", SignalFixtures.sparseVocal()),
            ("quietloud", SignalFixtures.quietLoud())
        ]
        for (name, analysis) in materials {
            for difficulty in [DifficultyLevel.medium, .extreme] {
                let request = ChartGenerator.Request(difficulty: difficulty, densityMultiplier: 1.0, seed: 5)
                let a = try await ChartGenerator().generate(analysis: analysis, songID: UUID(), request: request)
                let b = try await ChartGenerator().generate(analysis: analysis, songID: UUID(), request: request)
                XCTAssertEqual(a.chart.notes, b.chart.notes, "\(name) \(difficulty): not deterministic")
            }
        }
    }

    func testNoBeatsFallbackStillProducesChart() async throws {
        // Ambient-style analysis: no beats, no tempo, but real onsets.
        var events: [MusicalEvent] = []
        for i in 0..<60 {
            events.append(SignalFixtures.event(time: 0.6 * Double(i), strength: 0.6, importance: 0.5))
        }
        let analysis = SignalFixtures.makeAnalysis(
            duration: 40, bpm: 0, beats: [],
            events: events,
            sections: [SongSection(index: 0, start: 0, end: 40, label: .generic, energy: 0.6)])
        let output = try await generate(analysis, difficulty: .medium)
        assertPlayable(output.chart, difficulty: .medium, "no-beat fallback")
        XCTAssertFalse(output.chart.notes.isEmpty)
    }

    func testBeatFillKicksInForVerySparseMusic() async throws {
        // Music with almost nothing but downbeats every 2 s.
        let bpm = 120.0
        let interval = 60.0 / bpm
        let seconds = 40.0
        let beats = SignalFixtures.quarterBeats(bpm: bpm, seconds: seconds)
        var events: [MusicalEvent] = []
        var t = 0.0
        var i = 0
        while t < seconds {
            if i % 4 == 0 {
                events.append(SignalFixtures.event(time: t, strength: 0.9, importance: 0.95,
                                                   beatStrength: 1.0, isOnBeat: true))
            }
            t += interval
            i += 1
        }
        let analysis = SignalFixtures.makeAnalysis(
            duration: seconds, bpm: bpm, beats: beats, events: events,
            sections: [SongSection(index: 0, start: 0, end: seconds, label: .generic, energy: 0.9)])
        let output = try await generate(analysis, difficulty: .medium)
        assertPlayable(output.chart, difficulty: .medium, "sparse-with-beats")
        // Beat fill should produce a rhythmically steady, chartable result.
        let analytics = ChartAnalyticsBuilder.analyze(chart: output.chart, analysis: analysis)
        XCTAssertGreaterThan(analytics.beatFillNoteCount, 0, "expected beat-fill notes")
        XCTAssertGreaterThan(output.chart.notes.count, 20)
    }
}