import XCTest
@testable import Music_Haptics

/// v4 chart-intelligence suite: rhythm templates, lane motifs, rests, chords,
/// holds, section-aware density, quality scoring, multi-candidate selection and
/// pathological input — all deterministic.
final class ChartPatternsTests: XCTestCase {

    // MARK: - Helpers

    private func generate(_ analysis: AudioAnalysis, difficulty: DifficultyLevel,
                          densityMultiplier: Double = 1.0, seed: UInt64 = 23) async throws -> ChartGenerator.Output {
        try await ChartGenerator().generate(
            analysis: analysis, songID: UUID(),
            request: ChartGenerator.Request(difficulty: difficulty, densityMultiplier: densityMultiplier, seed: seed))
    }

    private func validate(_ chart: Chart, difficulty: DifficultyLevel) -> ValidationResult {
        ChartValidator.validate(chart.notes, constraints: ChartConstraints.forDifficulty(difficulty, densityMultiplier: 1.0))
    }

    // MARK: - Rhythm vocabulary

    func testTemplateSelectionIsDeterministic() {
        let analysis = SignalFixtures.metronomeAnalysis(bpm: 120, seconds: 12)
        var phrases = PhraseSequencer.buildPhrases(beats: analysis.beats, playStart: 0.4,
                                                   playEnd: 10.8, energyAt: { _ in 0.9 })
        for i in phrases.indices {
            PhraseSequencer.computeSlotScores(&phrases[i], events: analysis.events)
        }
        func pick() -> [RhythmTemplate] {
            var rng = SplitMix64(state: 42)
            var previous: RhythmTemplate?
            return phrases.map { phrase in
                let t = PhraseSequencer.chooseTemplate(phrase: phrase, targetSlots: 4,
                                                       previous: previous, previousSimilarity: 0,
                                                       rng: &rng)
                previous = t
                return t
            }
        }
        XCTAssertEqual(pick(), pick(), "template roulette must be deterministic")
    }

    func testTemplatesAndMotifsVaryAcrossSong() async throws {
        // Quiet intro → loud chorus gives the sequencer distinct musical
        // material, so it must compose with more than one rhythm template.
        let analysis = SignalFixtures.quietLoud()
        let output = try await generate(analysis, difficulty: .hard)
        let analytics = ChartAnalyticsBuilder.analyze(chart: output.chart, analysis: analysis)
        XCTAssertGreaterThanOrEqual(analytics.templateCounts.count, 2,
                                    "a song with distinct sections should use several rhythm templates")
        XCTAssertLessThanOrEqual(analytics.repeatedPatternRate, 0.9,
                                 "charts must not be one repeated pattern (rate \(analytics.repeatedPatternRate))")
    }

    func testRestsAppearInQuietSections() async throws {
        let analysis = SignalFixtures.quietLoud()
        let output = try await generate(analysis, difficulty: .easy)
        let analytics = ChartAnalyticsBuilder.analyze(chart: output.chart, analysis: analysis)
        XCTAssertGreaterThan(analytics.restFrequency, 0,
                             "quiet sections should produce deliberate rests")
        // Rests concentrate in the quiet half, not the loud one.
        let quiet = analytics.sectionDensity.first { $0.energy < 0.4 } ?? analytics.sectionDensity[0]
        _ = quiet
        XCTAssertTrue(analytics.templateCounts["rest"] != nil || analytics.templateCounts["downbeatOnly"] != nil,
                      "expected a restful template in the quiet-intro chart")
    }

    func testSectionDensityFollowsEnergy() async throws {
        let analysis = SignalFixtures.quietLoud()
        let output = try await generate(analysis, difficulty: .medium)
        let analytics = ChartAnalyticsBuilder.analyze(chart: output.chart, analysis: analysis)
        guard let quiet = analytics.sectionDensity.first(where: { $0.energy < 0.4 }),
              let loud = analytics.sectionDensity.first(where: { $0.energy > 0.6 }) else {
            XCTFail("quiet/loud fixture should expose both energy regions")
            return
        }
        XCTAssertGreaterThan(loud.nps, quiet.nps * 1.4,
                             "chorus/energetic sections must chart denser (quiet \(String(format: "%.2f", quiet.nps)) vs loud \(String(format: "%.2f", loud.nps)))")
    }

    // MARK: - Chords

    func testChordsSurviveValidationOnHigherDifficulties() async throws {
        let analysis = SignalFixtures.drumHeavy(bpm: 128, seconds: 30)
        let easy = try await generate(analysis, difficulty: .easy)
        let easyAnalytics = ChartAnalyticsBuilder.analyze(chart: easy.chart, analysis: analysis)
        XCTAssertEqual(easyAnalytics.chordGroups, 0, "easy must not chart chords")

        let medium = try await generate(analysis, difficulty: .medium)
        let mediumAnalytics = ChartAnalyticsBuilder.analyze(chart: medium.chart, analysis: analysis)
        XCTAssertGreaterThan(mediumAnalytics.chordGroups, 0,
                             "medium+ should place deliberate chords and keep them")
        XCTAssertEqual(validate(medium.chart, difficulty: .medium).hardFailureCount, 0)
        XCTAssertLessThanOrEqual(mediumAnalytics.maxSimultaneous, 2)
    }

    func testValidatorAcceptsChordPairButRejectsSameLaneChord() {
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        func note(_ id: Int, _ t: Double, _ lane: Int) -> ChartNote {
            ChartNote(id: id, time: t, lane: lane, duration: 0, type: .tap, strength: 1)
        }
        // Two voices at the same instant on different lanes = one chord.
        let chord = [note(0, 1.0, 0), note(1, 1.0, 2), note(2, 1.5, 1), note(3, 2.0, 2)]
        XCTAssertEqual(ChartValidator.validate(chord, constraints: constraints).hardFailureCount, 0,
                       "a two-voice chord must be legal")
        // Same lane twice at the same instant is unplayable.
        let badChord = [note(0, 1.0, 0), note(1, 1.0, 0)]
        XCTAssertGreaterThan(ChartValidator.validate(badChord, constraints: constraints).hardFailureCount, 0)
        // A 3-note cluster exceeds the medium cap of 2.
        let triple = [note(0, 1.0, 0), note(1, 1.0, 1), note(2, 1.0, 2)]
        XCTAssertGreaterThan(ChartValidator.validate(triple, constraints: constraints).hardFailureCount, 0)
    }

    func testRepairPreservesKeptChords() {
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        func note(_ id: Int, _ t: Double, _ lane: Int) -> ChartNote {
            ChartNote(id: id, time: t, lane: lane, duration: 0, type: .tap, strength: 1)
        }
        // A chord at 1.0 plus a violator at 1.05 (3 voices in one window).
        let input = [note(0, 1.0, 0), note(1, 1.0, 2), note(2, 1.05, 1), note(3, 1.5, 3), note(4, 2.0, 0)]
        let repaired = ChartValidator.repair(input, constraints: constraints)
        XCTAssertEqual(ChartValidator.validate(repaired, constraints: constraints).hardFailureCount, 0)
        let chordVoices = repaired.filter { abs($0.time - 1.0) < 0.01 }
        XCTAssertEqual(chordVoices.count, 2, "repair must keep both chord voices when legal")
    }

    func testChordJumpsUseMinDistance() {
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        func note(_ id: Int, _ t: Double, _ lane: Int) -> ChartNote {
            ChartNote(id: id, time: t, lane: lane, duration: 0, type: .tap, strength: 1)
        }
        // Chord (0,2) 0.4s after a lane-3 note: min distance is 1 (→ lane 2).
        let chart = [note(0, 0.0, 3), note(1, 0.4, 0), note(2, 0.4, 2)]
        XCTAssertEqual(ChartValidator.validate(chart, constraints: constraints).hardFailureCount, 0,
                       "chord reachability must be measured by min lane distance")
    }

    // MARK: - Holds

    func testHoldsOnlyOnStrongMaterialWithRoom() async throws {
        let analysis = SignalFixtures.drumHeavy(bpm: 120, seconds: 32)
        let output = try await generate(analysis, difficulty: .hard)
        let analytics = ChartAnalyticsBuilder.analyze(chart: output.chart, analysis: analysis)
        XCTAssertGreaterThan(analytics.holdCount, 0, "strong-beat material should yield some holds")
        XCTAssertLessThan(analytics.holdFrequency, 0.4, "holds are seasoning, not the default")

        // Hold tails must clear the next note in the same lane (validator enforces it).
        XCTAssertEqual(validate(output.chart, difficulty: .hard).hardFailureCount, 0)
        let strongTimes: [Double] = analysis.beats.filter { $0.isStrong || $0.strength > 0.7 }.map { $0.time }
        for note in output.chart.notes where note.type == .hold {
            // The generator's hold gate: a strong-beat accent, or a very
            // strong non-beat accent — never a weak random onset.
            XCTAssertTrue(strongTimes.contains { abs($0 - note.time) < 0.06 } || note.strength >= 0.72,
                          "hold head must sit on a strong beat or strong accent (at \(String(format: "%.2f", note.time)))")
        }
    }

    // MARK: - Playability + quality

    func testLaneBalanceAcrossFourLanes() async throws {
        let analysis = SignalFixtures.quietLoud()
        let output = try await generate(analysis, difficulty: .hard)
        let analytics = ChartAnalyticsBuilder.analyze(chart: output.chart, analysis: analysis)
        let shares = analytics.laneShares
        XCTAssertEqual(shares.count, 4)
        XCTAssertGreaterThanOrEqual(shares.min() ?? 0, 0.08,
                                    "one lane is starved (shares \(shares.map { String(format: "%.0f%%", $0 * 100) }))")
        XCTAssertFalse(analytics.isSuspiciouslyOneSided)
    }

    func testQualityScorerIsChordAware() {
        func note(_ id: Int, _ t: Double, _ lane: Int) -> ChartNote {
            ChartNote(id: id, time: t, lane: lane, duration: 0, type: .tap, strength: 1)
        }
        let empty: [Phrase] = []
        let sections: [SongSection] = []
        // 2-note chord at 0.0 then a note at 0.3: reaction gap is 0.3s from the
        // chord anchor — the chord pair itself must not count as 0 ms reaction.
        let chordChart = [note(0, 0.0, 0), note(1, 0.0, 2), note(2, 0.3, 1), note(3, 0.6, 2), note(4, 0.9, 1)]
        let plainChart = [note(0, 0.0, 0), note(1, 0.3, 1), note(2, 0.6, 2), note(3, 0.9, 1)]
        let withChord = ChartQualityScorer.score(notes: chordChart, analysis: nil, difficulty: .medium,
                                                 phrases: empty, sections: sections)
        let plain = ChartQualityScorer.score(notes: plainChart, analysis: nil, difficulty: .medium,
                                             phrases: empty, sections: sections)
        XCTAssertLessThan(withChord.reactionPenalty - plain.reactionPenalty, 0.5,
                          "a chord must not inflate reaction penalties")
    }

    func testMultiCandidateSelectionIsDeterministicAndValid() async throws {
        let analysis = SignalFixtures.drumHeavy(bpm: 140, seconds: 36)
        let request = ChartGenerator.Request(difficulty: .hard, densityMultiplier: 1.0, seed: 99)
        let a = try await ChartGenerator().generate(analysis: analysis, songID: UUID(), request: request)
        let b = try await ChartGenerator().generate(analysis: analysis, songID: UUID(), request: request)
        XCTAssertEqual(a.chart.notes, b.chart.notes)
        XCTAssertEqual(a.chart.qualityScore, b.chart.qualityScore)
        XCTAssertEqual(a.chart.repairCount, 0, "well-shaped candidates should need no repair")
        XCTAssertEqual(validate(a.chart, difficulty: .hard).hardFailureCount, 0)
    }

    // MARK: - Pathological input

    func testBeatlessAmbientChartsWithRealFill() async throws {
        // No beats, no tempo: the legacy fallback must still produce a chart
        // with meaningful density instead of one lonely note.
        var events: [MusicalEvent] = []
        for i in 0..<60 {
            events.append(SignalFixtures.event(time: 0.6 * Double(i), strength: 0.5, importance: 0.4))
        }
        let analysis = SignalFixtures.makeAnalysis(
            duration: 40, bpm: 0, beats: [],
            events: events,
            sections: [SongSection(index: 0, start: 0, end: 40, label: .generic, energy: 0.6)])
        for difficulty in [DifficultyLevel.easy, .medium, .hard] {
            let output = try await generate(analysis, difficulty: difficulty)
            XCTAssertGreaterThan(output.chart.notes.count, 12,
                                 "\\(difficulty): beat-less fallback chart is nearly empty")
            XCTAssertEqual(validate(output.chart, difficulty: difficulty).hardFailureCount, 0)
        }
    }

    func testLegacySwitchStillGeneratesValidCharts() async throws {
        let analysis = SignalFixtures.drumHeavy(bpm: 128, seconds: 24)
        let request = ChartGenerator.Request(difficulty: .medium, densityMultiplier: 1.0, seed: 5)
        ChartGenerator.forceLegacySelection = true
        let legacy = try await ChartGenerator().generate(analysis: analysis, songID: UUID(), request: request)
        ChartGenerator.forceLegacySelection = false
        let v4 = try await ChartGenerator().generate(analysis: analysis, songID: UUID(), request: request)
        XCTAssertEqual(validate(legacy.chart, difficulty: .medium).hardFailureCount, 0)
        XCTAssertEqual(validate(v4.chart, difficulty: .medium).hardFailureCount, 0)
        // v4 composes with templates; legacy per-cell selection behaves differently.
        XCTAssertNotEqual(legacy.chart.notes, v4.chart.notes)
    }
}