import XCTest
@testable import Music_Haptics

/// Regression coverage for the optional Foundation Models tier. These tests
/// exercise the platform-independent boundary; they do not pretend that a
/// simulator has an Apple Intelligence model available.
@MainActor
final class GameplayIntelligenceTests: XCTestCase {
    func testUnavailableAvailabilityAlwaysUsesStandardTier() {
        let states: [OnDeviceAIAvailability] = [
            .checking, .deviceNotEligible, .appleIntelligenceDisabled,
            .modelNotReady, .unsupportedOS, .temporaryFailure
        ]

        for state in states {
            XCTAssertFalse(state.supportsEnhancedTier)
            XCTAssertEqual(state.tier, .standardMath)
        }
        XCTAssertEqual(OnDeviceAIAvailability.enhancedAvailable.tier,
                       .enhancedOnDeviceAI)
    }

    func testModelOutputIsSortedClampedDeduplicatedAndCompleted() {
        let duration = 10.0
        let raw = [
            DynamicSpeedProfile.SpeedCurvePoint(time: 8, intensity: 4),
            DynamicSpeedProfile.SpeedCurvePoint(time: -2, intensity: -4),
            DynamicSpeedProfile.SpeedCurvePoint(time: 8.005, intensity: 0.25),
            DynamicSpeedProfile.SpeedCurvePoint(time: 3, intensity: .nan),
            DynamicSpeedProfile.SpeedCurvePoint(time: 4, intensity: 0.5)
        ]

        let validated = GameplayIntelligenceValidation.speedPoints(raw, duration: duration)
        XCTAssertEqual(validated?.first?.time ?? -1, 0)
        XCTAssertEqual(validated?.last?.time ?? -1, duration)
        XCTAssertEqual(validated?.count, 4)
        XCTAssertEqual(validated?[1].time ?? -1, 4)
        XCTAssertEqual(validated?[2].time ?? -1, 8.005, accuracy: 0.000_001)
        XCTAssertEqual(validated?[2].intensity ?? -2, 0.25, accuracy: 0.000_001)
        XCTAssertTrue(validated?.allSatisfy { (-1...1).contains($0.intensity) } == true)
    }

    func testInvalidModelOutputFallsBackToStandardMathProfile() {
        let chart = fixtureChart()
        let analysis = AudioAnalysis(duration: 12, sampleRate: 44_100,
                                     tempoBPM: 120, tempoConfidence: 0.9,
                                     beats: [], onsets: [], events: [], sections: [],
                                     waveform: [], averageEnergy: 0.5,
                                     analysisDuration: 0.1, hopTime: 0.01)
        let invalid = [
            DynamicSpeedProfile.SpeedCurvePoint(time: .nan, intensity: 0.5)
        ]
        let profile = DynamicSpeedProfile.make(analysis: analysis, chart: chart,
                                                enabled: true, intensity: .standard,
                                                enhancedPoints: GameplayIntelligenceValidation.speedPoints(invalid,
                                                                                                          duration: 12))
        XCTAssertNotEqual(profile.source, .enhancedOnDeviceAI)
        XCTAssertTrue(profile.points.allSatisfy { $0.multiplier.isFinite })
    }

    func testAIOutputChangesOnlyVisualProfileNotChartTiming() {
        let chart = fixtureChart()
        let timestamps = chart.notes.map(\.time)
        let analysis = AudioAnalysis(duration: 12, sampleRate: 44_100,
                                     tempoBPM: 120, tempoConfidence: 0.9,
                                     beats: [], onsets: [], events: [], sections: [],
                                     waveform: [], averageEnergy: 0.5,
                                     analysisDuration: 0.1, hopTime: 0.01)
        let points = [
            DynamicSpeedProfile.SpeedCurvePoint(time: 0, intensity: -1),
            DynamicSpeedProfile.SpeedCurvePoint(time: 6, intensity: 1),
            DynamicSpeedProfile.SpeedCurvePoint(time: 12, intensity: 0)
        ]
        let profile = DynamicSpeedProfile.make(analysis: analysis, chart: chart,
                                                enabled: true, intensity: .standard,
                                                enhancedPoints: points)
        XCTAssertEqual(profile.source, .enhancedOnDeviceAI)
        XCTAssertEqual(chart.notes.map(\.time), timestamps)
        for note in chart.notes {
            XCTAssertEqual(profile.progress(noteTime: note.time,
                                            currentTime: note.time,
                                            baseLead: 1.8), 0, accuracy: 0.000_001)
        }
    }

    func testDisabledAIUsesStandardFallbackWithoutCallingModel() async {
        let service = OnDeviceAIService()
        let chart = fixtureChart()
        let points = await service.prepareSpeedCurve(songID: chart.songID,
                                                     chart: chart,
                                                     analysis: nil,
                                                     enabled: false)
        XCTAssertNil(points)
        XCTAssertEqual(service.tier(enabled: true), .standardMath,
                       "a freshly created service must not opt into AI before availability is confirmed")
    }

    func testPlayerAnalysisRequiresEnoughLocalHistory() {
        let songID = UUID()
        var tier = DifficultyStats(difficulty: .medium)
        tier.attempts = 2
        let insufficient = StatsSnapshot(schemaVersion: StatsSnapshot.currentSchemaVersion,
                                         stats: [SongStats(songID: songID,
                                                           title: "Local",
                                                           perDifficulty: [tier])])
        XCTAssertFalse(GameplayIntelligenceValidation.hasSufficientHistory(insufficient))

        tier.attempts = 3
        let sufficient = StatsSnapshot(schemaVersion: StatsSnapshot.currentSchemaVersion,
                                       stats: [SongStats(songID: songID,
                                                         title: "Local",
                                                         perDifficulty: [tier])])
        XCTAssertTrue(GameplayIntelligenceValidation.hasSufficientHistory(sufficient))
    }
    func testPlayerRecommendationValidationIsExplicitAndClamped() {
        let date = Date(timeIntervalSince1970: 123)
        let recommendation = GameplayIntelligenceValidation.playerRecommendation(
            summary: "  You tend to arrive late in dense sections.  ",
            difficulty: "HARD",
            dynamicSpeed: true,
            intensity: "EXPRESSIVE",
            confidence: 4,
            generatedAt: date)
        XCTAssertEqual(recommendation?.recommendedDifficulty, .hard)
        XCTAssertEqual(recommendation?.dynamicSpeedIntensity, .expressive)
        XCTAssertEqual(recommendation?.confidence, 1)
        XCTAssertEqual(recommendation?.generatedAt, date)
        XCTAssertNil(GameplayIntelligenceValidation.playerRecommendation(
            summary: "", difficulty: "hard", dynamicSpeed: true,
            intensity: "standard", confidence: 0.5))
        XCTAssertNil(GameplayIntelligenceValidation.playerRecommendation(
            summary: "usable", difficulty: "impossible", dynamicSpeed: true,
            intensity: "standard", confidence: 0.5))
    }

    func testRealRuntimeAvailabilityIsNeverPersistedAsEnhancedTier() async {
        let service = OnDeviceAIService()
        let availability = await service.refresh()
        // The test is intentionally runtime-agnostic: a simulator may report
        // any current OS state. The invariant is that the tier is derived from
        // that exact state, never from a device-name guess or persisted value.
        XCTAssertEqual(service.tier(enabled: true), availability.tier)
        XCTAssertEqual(service.tier(enabled: false), .standardMath)
    }

    func testGameplayContextCapturesHoldsChordsSectionsAndSpeedTransitions() {
        let songID = UUID()
        let chart = Chart(songID: songID, difficulty: .hard,
                          chartVersion: ChartStorage.chartVersion, seed: 9,
                          notes: [
                              ChartNote(id: 0, time: 1.0, lane: 0, duration: 0,
                                        type: .tap, strength: 0.6),
                              ChartNote(id: 1, time: 1.04, lane: 1, duration: 2.0,
                                        type: .hold, strength: 0.9),
                              ChartNote(id: 2, time: 5.0, lane: 3, duration: 0,
                                        type: .tap, strength: 0.7)
                          ], generatedAt: Date(timeIntervalSince1970: 0),
                          nps: 0.25, duration: 12, difficultyScore: 6,
                          validationWarnings: [], generationDuration: 0)
        let analysis = AudioAnalysis(duration: 12, sampleRate: 44_100,
                                     tempoBPM: 120, tempoConfidence: 0.9,
                                     beats: [], onsets: [], events: [],
                                     sections: [
                                         SongSection(index: 0, start: 0, end: 4,
                                                     label: .intro, energy: 0.2),
                                         SongSection(index: 1, start: 4, end: 12,
                                                     label: .chorus, energy: 0.9)
                                     ], waveform: [], averageEnergy: 0.5,
                                     analysisDuration: 0.1, hopTime: 0.01)
        let profile = DynamicSpeedProfile.make(analysis: analysis, chart: chart,
                                                enabled: true, intensity: .standard)
        let context = GameplayAIContext.make(chart: chart, analysis: analysis,
                                             standardProfile: profile,
                                             dynamicSpeedEnabled: true,
                                             dynamicSpeedIntensity: .standard)

        XCTAssertEqual(context.holdCount, 1)
        XCTAssertEqual(context.chordCount, 1)
        XCTAssertEqual(context.sections.count, 2)
        XCTAssertGreaterThan(context.sections[1].energy, context.sections[0].energy)
        XCTAssertGreaterThanOrEqual(context.accelerationTransitionCount, 0)
        XCTAssertTrue(context.standardSpeedPoints.count >= 2)
        XCTAssertTrue(context.maximumLaneJump >= 0)
        XCTAssertTrue(context.spatialTravelRisk.isFinite)
    }

    func testValidatedGameplayPlanBoundsFindingsAndRecommendations() {
        let chart = fixtureChart()
        let finding = GameplayAIQualityFinding(category: String(repeating: "x", count: 80),
                                                severity: 4, sectionIndex: 99,
                                                explanation: String(repeating: "e", count: 300),
                                                suggestedCorrection: "repair")
        let plan = GameplayIntelligenceValidation.gameplayPlan(
            points: [
                .init(time: 2, intensity: 4),
                .init(time: 8, intensity: -4)
            ],
            findings: [finding], confidence: 4, songID: chart.songID,
            chart: chart, duration: 10, sectionCount: 2,
            intensity: .expressive, recommendedDifficulty: .extreme,
            recommendedHoldDensity: 4, recommendedChordDensity: -.infinity)

        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.confidence, 1)
        XCTAssertEqual(plan?.points.first?.time, 0)
        XCTAssertEqual(plan?.points.last?.time, 10)
        XCTAssertEqual(plan?.points.map(\.intensity).max(), 1)
        XCTAssertEqual(plan?.points.map(\.intensity).min(), -1)
        XCTAssertEqual(plan?.findings.first?.category.count, 48)
        XCTAssertEqual(plan?.findings.first?.explanation.count, 240)
        XCTAssertEqual(plan?.findings.first?.sectionIndex, 1)
        XCTAssertEqual(plan?.recommendedHoldDensity, 1)
        XCTAssertNil(plan?.recommendedChordDensity)
    }

    func testGameplayPlanRejectsInsufficientSpeedPoints() {
        let chart = fixtureChart()
        let plan = GameplayIntelligenceValidation.gameplayPlan(
            points: [.init(time: 3, intensity: 0.2)],
            findings: [], confidence: 0.5, songID: chart.songID,
            chart: chart, duration: 10, sectionCount: 0)
        XCTAssertNil(plan, "a structured response without a usable curve must use Standard Math")
    }

    private func fixtureChart() -> Chart {
        Chart(songID: UUID(), difficulty: .medium,
              chartVersion: ChartStorage.chartVersion, seed: 7,
              notes: [
                  ChartNote(id: 0, time: 1, lane: 0, duration: 0,
                            type: .tap, strength: 0.5),
                  ChartNote(id: 1, time: 4, lane: 1, duration: 0,
                            type: .tap, strength: 0.5)
              ], generatedAt: Date(timeIntervalSince1970: 0),
              nps: 0.2, duration: 12, difficultyScore: 5,
              validationWarnings: [], generationDuration: 0)
    }
}
