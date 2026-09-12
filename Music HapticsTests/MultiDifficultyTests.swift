import XCTest
@testable import Music_Haptics

/// Multi-difficulty chart system: every difficulty is generated from ONE
/// shared analysis, cached separately, deterministic, independently playable,
/// and mostly monotonic (significant inversions must be diagnosed, not hidden).
final class MultiDifficultyTests: XCTestCase {

    private func generate(_ analysis: AudioAnalysis, difficulty: DifficultyLevel,
                          densityMultiplier: Double = 1.0, seed: UInt64 = 4242) async throws -> Chart {
        try await ChartGenerator().generate(
            analysis: analysis, songID: UUID(),
            request: ChartGenerator.Request(difficulty: difficulty, densityMultiplier: densityMultiplier, seed: seed))
            .chart
    }

    private func generateAll(_ analysis: AudioAnalysis, seed: UInt64 = 4242) async throws -> [DifficultyLevel: Chart] {
        var charts: [DifficultyLevel: Chart] = [:]
        for difficulty in ChartStorage.generatedDifficulties {
            // Distinct seed per difficulty, like AppState does.
            var h: UInt64 = 0x5EED
            for byte in difficulty.rawValue.utf8 { h = h &* 31 &+ UInt64(byte) }
            charts[difficulty] = try await ChartGenerator().generate(
                analysis: analysis, songID: UUID(),
                request: ChartGenerator.Request(difficulty: difficulty, densityMultiplier: 1.0,
                                                seed: seed &+ h))
                .chart
        }
        return charts
    }

    private func validate(_ chart: Chart, difficulty: DifficultyLevel) -> ValidationResult {
        ChartValidator.validate(chart.notes, constraints: ChartConstraints.forDifficulty(difficulty, densityMultiplier: 1.0))
    }

    private func makeChart(songID: UUID, difficulty: DifficultyLevel, score: Double, notes: Int) -> Chart {
        Chart(songID: songID, difficulty: difficulty, chartVersion: ChartStorage.chartVersion,
              seed: 1, notes: (0..<notes).map { ChartNote(id: $0, time: Double($0) * 0.5, lane: $0 % 4,
                                                           duration: 0, type: .tap, strength: 0.5) },
              generatedAt: Date(), nps: Double(notes) / 30, duration: 30,
              difficultyScore: score, validationWarnings: [], generationDuration: 0,
              qualityScore: 8, repairCount: 0)
    }

    // MARK: - Shared analysis + determinism

    func testAllDifficultiesUseSameAnalysisAndAreDeterministic() async throws {
        let analysis = SignalFixtures.drumHeavy(bpm: 128, seconds: 24)
        let first = try await generateAll(analysis)
        let second = try await generateAll(analysis)
        for difficulty in ChartStorage.generatedDifficulties {
            guard let a = first[difficulty], let b = second[difficulty] else {
                XCTFail("missing chart for \(difficulty)")
                return
            }
            XCTAssertEqual(a.notes, b.notes, "\(difficulty): regeneration must be byte-identical")
        }
        // Each difficulty is a distinct arrangement, not the same chart reused.
        let pairs: [(DifficultyLevel, DifficultyLevel)] = [(.easy, .hard), (.medium, .expert), (.easy, .extreme)]
        for (low, high) in pairs {
            XCTAssertNotEqual(first[low]!.notes, first[high]!.notes, "\(low) and \(high) must differ")
        }
    }

    // MARK: - Density ordering

    func testDensityRisesWithDifficulty() async throws {
        let analysis = SignalFixtures.drumHeavy(bpm: 120, seconds: 30)
        let charts = try await generateAll(analysis)
        let ordered = ChartStorage.generatedDifficulties.compactMap { charts[$0] }
        // Notes must generally rise: allow small crossings but Easy must stay
        // clearly below Expert, and no SIGNIFICANT inversion may exist.
        XCTAssertLessThan(ordered[0].notes.count, ordered[3].notes.count,
                          "easy (\(ordered[0].notes.count)) must chart far fewer notes than expert (\(ordered[3].notes.count))")
        XCTAssertLessThanOrEqual(ordered[0].notes.count, ordered[1].notes.count,
                                 "easy \(ordered[0].notes.count) > normal \(ordered[1].notes.count)")
        XCTAssertEqual(ChartMonotonicity.inversions(charts: charts), [],
                       "a steady groove must rate monotonically")
    }

    func testCrossingRatingsAreToleratedButSignificantOnesDiagnosed() async throws {
        // A sparse, accent-only song can rate oddly: easy charts the accents
        // densely while harder difficulties add structure — small crossings are
        // acceptable, big ones must be surfaced.
        let analysis = SignalFixtures.sparseVocal(bpm: 90, seconds: 32)
        let charts = try await generateAll(analysis)
        let inversions = ChartMonotonicity.inversions(charts: charts)
        if !inversions.isEmpty {
            print("Inversion diagnostics: \(inversions.joined(separator: " | "))")
        }
        // Even with crossings, every difficulty stays playable and the easy
        // chart never out-charts expert by a huge margin.
        for difficulty in ChartStorage.generatedDifficulties {
            guard let chart = charts[difficulty] else {
                XCTFail("missing \(difficulty)"); return
            }
            XCTAssertEqual(validate(chart, difficulty: difficulty).hardFailureCount, 0)
        }
        XCTAssertLessThan(charts[.easy]!.notes.count, charts[.expert]!.notes.count + 5,
                          "easy must not out-chart expert")
    }

    // MARK: - Independent playability

    func testEveryDifficultyIsIndependentlyPlayable() async throws {
        for fixture in [SignalFixtures.drumHeavy(bpm: 140, seconds: 24),
                        SignalFixtures.quietLoud(),
                        SignalFixtures.fastDrumHeavy(bpm: 220, seconds: 20)] {
            let charts = try await generateAll(fixture)
            for difficulty in ChartStorage.generatedDifficulties {
                let chart = try XCTUnwrap(charts[difficulty])
                let result = validate(chart, difficulty: difficulty)
                XCTAssertEqual(result.hardFailureCount, 0,
                               "\(difficulty) @ \(fixture.beats.count)-beat fixture: \(result.hardFailures.joined(separator: "; "))")
                for note in chart.notes {
                    XCTAssertTrue((0..<4).contains(note.lane))
                }
            }
        }
    }

    func testExtremeStaysWithinPhysicalCaps() async throws {
        let analysis = SignalFixtures.fastDrumHeavy(bpm: 220, seconds: 24)
        let chart = try await generate(analysis, difficulty: .extreme, densityMultiplier: 1.0)
        let result = validate(chart, difficulty: .extreme)
        XCTAssertEqual(result.hardFailureCount, 0, "extreme must remain physically playable")
        let constraints = ChartConstraints.forDifficulty(.extreme, densityMultiplier: 1.0)
        XCTAssertLessThanOrEqual(Double(chart.notes.count) / max(chart.duration, 1), constraints.maxNPS,
                                 "extreme must respect the density cap")
        XCTAssertLessThan(chart.notes.count, analysis.events.count,
                          "extreme must never transcribe every onset")
    }

    // MARK: - Per-difficulty storage

    func testChartStorageKeepsDifficultiesSeparate() throws {
        let songID = UUID()
        defer {
            ChartStorage.deleteAllCharts(for: songID)
        }
        let easy = makeChart(songID: songID, difficulty: .easy, score: 2.5, notes: 40)
        let expert = makeChart(songID: songID, difficulty: .expert, score: 7.5, notes: 180)
        try ChartStorage.save(easy, for: songID)
        try ChartStorage.save(expert, for: songID)

        XCTAssertEqual(try ChartStorage.loadChart(for: songID, difficulty: .easy)?.notes.count, 40)
        XCTAssertEqual(try ChartStorage.loadChart(for: songID, difficulty: .expert)?.notes.count, 180)
        XCTAssertNil(try ChartStorage.loadChart(for: songID, difficulty: .hard),
                     "generating expert must not fabricate other difficulties")

        // Deleting one difficulty leaves the others untouched.
        ChartStorage.deleteChart(for: songID, difficulty: .expert)
        XCTAssertNil(try ChartStorage.loadChart(for: songID, difficulty: .expert))
        XCTAssertEqual(try ChartStorage.loadChart(for: songID, difficulty: .easy)?.notes.count, 40)

        let all = try ChartStorage.loadCharts(for: songID)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[.easy]?.difficultyScore, 2.5)

        // deleteAllCharts removes everything, including the legacy path.
        try ChartStorage.save(expert, for: songID)
        ChartStorage.deleteAllCharts(for: songID)
        XCTAssertNil(try ChartStorage.loadChart(for: songID, difficulty: .easy))
        XCTAssertNil(try ChartStorage.loadChart(for: songID, difficulty: .expert))
    }

    func testLegacySingleChartIsReadAsFallback() throws {
        let songID = UUID()
        defer { ChartStorage.deleteAllCharts(for: songID) }
        // Legacy layout: a chart at the song-level path (no difficulty suffix).
        let legacyURL = AppDirectories.chartsDirectory
            .appendingPathComponent(songID.uuidString + ".chart.json")
        let chart = makeChart(songID: songID, difficulty: .hard, score: 6.0, notes: 90)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(chart).write(to: legacyURL, options: .atomic)

        XCTAssertEqual(try ChartStorage.loadChart(for: songID, difficulty: .hard)?.notes.count, 90,
                       "legacy chart must be honored when its difficulty matches")
        XCTAssertNil(try ChartStorage.loadChart(for: songID, difficulty: .easy),
                     "legacy chart must not answer for a different difficulty")
    }

    // MARK: - Inversion diagnostics

    func testSignificantInversionsAreReportedAndMinorOnesAreNot() {
        let songID = UUID()
        func charts(easy: Double, normal: Double, hard: Double, expert: Double, extreme: Double) -> [DifficultyLevel: Chart] {
            var result: [DifficultyLevel: Chart] = [:]
            let values: [(DifficultyLevel, Double)] = [(.easy, easy), (.medium, normal), (.hard, hard),
                                                       (.expert, expert), (.extreme, extreme)]
            for (level, score) in values {
                result[level] = makeChart(songID: songID, difficulty: level, score: score, notes: Int(score * 20))
            }
            return result
        }
        // Clean monotonic run → no diagnostics.
        XCTAssertEqual(ChartMonotonicity.inversions(charts: charts(easy: 2, normal: 4, hard: 6, expert: 8, extreme: 9)), [])
        // One significant inversion (hard rates 1.5 BELOW normal).
        let crossed = ChartMonotonicity.inversions(charts: charts(easy: 2, normal: 4, hard: 2.5, expert: 8, extreme: 9))
        XCTAssertEqual(crossed.count, 1, "got: \(crossed)")
        XCTAssertTrue(crossed[0].contains("Hard"), "diagnostic must name the level: \(crossed[0])")
        XCTAssertTrue(crossed[0].contains("Medium"), "diagnostic must name the lower level: \(crossed[0])")
        // Tiny crossings (≤ 0.75) are tolerated — no diagnostics.
        XCTAssertEqual(ChartMonotonicity.inversions(charts: charts(easy: 2, normal: 4, hard: 3.4, expert: 8, extreme: 9)), [])
    }
}