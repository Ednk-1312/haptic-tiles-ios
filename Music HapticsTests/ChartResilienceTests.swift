import Foundation
import XCTest
@testable import Music_Haptics

/// Chart-generation resilience: pathological inputs must never fail the song
/// ("unplayable pattern (candidate 3)" was the old fatal outcome), repair must
/// fix what it can (malformed notes, density over cap), and the user-facing
/// error surface must never leak internal candidate/tier names.
final class ChartResilienceTests: XCTestCase {
    private let songID = UUID(uuidString: "00000000-0000-0000-0000-00000000CAFE")!

    private func generate(_ analysis: AudioAnalysis, difficulty: DifficultyLevel = .expert,
                          density: Double = 1.0) async throws -> ChartGenerator.Output {
        let request = ChartGenerator.Request(difficulty: difficulty,
                                             densityMultiplier: density,
                                             seed: 0xDEAD_BEEF)
        return try await ChartGenerator().generate(analysis: analysis, songID: songID, request: request)
    }

    // MARK: - Pathological inputs never throw

    /// Double-beat artifacts: beats ~50 ms apart (a tempo misdetected at ~4×
    /// real speed). Every phrase is degenerate; generation must still produce
    /// a valid chart via the legacy/synthetic tiers instead of failing.
    func testDegenerateDoubleBeatGridStillGeneratesAValidChart() async throws {
        let seconds = 12.0
        var beats: [Beat] = []
        var events: [MusicalEvent] = []
        var t = 0.0
        var i = 0
        while t < seconds {
            beats.append(Beat(time: t, strength: i % 4 == 0 ? 0.9 : 0.5, isStrong: i % 4 == 0))
            events.append(SignalFixtures.event(time: t, strength: 0.6, importance: 0.6,
                                               beatStrength: 0.5, isOnBeat: true))
            t += 0.05   // ~1,200 BPM grid — pure artifact
            i += 1
        }
        let analysis = SignalFixtures.makeAnalysis(
            duration: seconds, bpm: 120, beats: beats, events: events,
            sections: [SongSection(index: 0, start: 0, end: seconds, label: .generic, energy: 0.7)])

        for difficulty in DifficultyLevel.allCases {
            let output = try await generate(analysis, difficulty: difficulty)
            XCTAssertGreaterThan(output.chart.notes.count, 0, "\(difficulty) produced an empty chart")
            let constraints = ChartConstraints.forDifficulty(difficulty, densityMultiplier: 1.0)
            let validation = ChartValidator.validate(output.chart.notes, constraints: constraints)
            XCTAssertEqual(validation.hardFailureCount, 0, "\(difficulty): \(validation.hardFailures)")
            XCTAssertGreaterThanOrEqual(output.fallbackTier, 1)
            XCTAssertLessThanOrEqual(output.fallbackTier, 4)
        }
    }

    /// Beat-less, tempo-less material with only a few events: the raw-event
    /// last resort must produce a deterministic chart, not an error.
    func testNearlyEventlessAnalysisStillCharts() async throws {
        let analysis = SignalFixtures.makeAnalysis(
            duration: 8.0, bpm: 0, beats: [],
            events: (1...3).map { SignalFixtures.event(time: Double($0), strength: 0.8, importance: 0.8) },
            sections: [])
        let output = try await generate(analysis, difficulty: .medium)
        XCTAssertGreaterThan(output.chart.notes.count, 0)
        let validation = ChartValidator.validate(output.chart.notes,
                                                 constraints: ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0))
        XCTAssertEqual(validation.hardFailureCount, 0)
    }

    /// Extreme onset density (100 events/s) — the chart must stay inside the
    /// notes-per-second cap via the density repair, not dump every onset.
    func testExtremeDensityStaysInsideNPSBounds() async throws {
        let seconds = 10.0
        var beats: [Beat] = []
        var events: [MusicalEvent] = []
        var t = 0.0
        var i = 0
        while t < seconds {
            if i % 10 == 0 {
                beats.append(Beat(time: t, strength: 0.9, isStrong: i % 40 == 0))
            }
            events.append(SignalFixtures.event(time: t, strength: 0.55, importance: 0.55,
                                               beatStrength: 0.4, isOnBeat: i % 4 == 0))
            t += 0.01
            i += 1
        }
        let analysis = SignalFixtures.makeAnalysis(
            duration: seconds, bpm: 150, beats: beats, events: events,
            sections: [SongSection(index: 0, start: 0, end: seconds, label: .chorus, energy: 1.0)])

        for difficulty in [DifficultyLevel.medium, .hard, .expert, .extreme] {
            let output = try await generate(analysis, difficulty: difficulty)
            XCTAssertGreaterThan(output.chart.notes.count, 0)
            let constraints = ChartConstraints.forDifficulty(difficulty, densityMultiplier: 1.0)
            let validation = ChartValidator.validate(output.chart.notes, constraints: constraints)
            XCTAssertEqual(validation.hardFailureCount, 0, "\(difficulty): \(validation.hardFailures)")
            // Density sanity: the densest 1s window of chord-group anchors
            // never exceeds the cap (validation's own sliding-window measure).
            let anchors = Self.anchorTimes(output.chart.notes)
            var maxWindow = 0
            var right = 0
            for left in 0..<anchors.count {
                while right < anchors.count && anchors[right] - anchors[left] < 1.0 { right += 1 }
                maxWindow = max(maxWindow, right - left)
            }
            XCTAssertLessThanOrEqual(Double(maxWindow), constraints.maxNPS + 0.5)
        }
    }

    /// Determinism under the pathological path: the SAME degenerate input must
    /// produce the byte-identical chart every time, and the tier must be
    /// recorded for diagnostics.
    func testPathologicalGenerationIsDeterministic() async throws {
        var beats: [Beat] = []
        var events: [MusicalEvent] = []
        var t = 0.0
        var i = 0
        while t < 10.0 {
            beats.append(Beat(time: t, strength: 0.5, isStrong: i % 4 == 0))
            events.append(SignalFixtures.event(time: t, strength: 0.5, importance: 0.5))
            t += 0.045
            i += 1
        }
        let analysis = SignalFixtures.makeAnalysis(
            duration: 10.0, bpm: 0, beats: beats, events: events,
            sections: [SongSection(index: 0, start: 0, end: 10, label: .generic, energy: 0.5)])

        let a = try await generate(analysis, difficulty: .hard)
        let b = try await generate(analysis, difficulty: .hard)
        XCTAssertEqual(a.chart.notes, b.chart.notes)   // ChartNote is Equatable
        XCTAssertNotNil(a.chart.fallbackTier)
        XCTAssertEqual(a.fallbackTier, b.fallbackTier)
        XCTAssertEqual(a.chart.fallbackTier, a.fallbackTier)
    }

    /// The user-facing error must never leak internal machinery.
    func testChartGenerationErrorMessageIsUserFriendly() {
        let error = ChartGenerationError.unableToGenerate("candidate 3 unplayable: Density 11.4 events/s exceeds cap")
        let message = error.errorDescription ?? ""
        XCTAssertFalse(message.localizedCaseInsensitiveContains("candidate"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("tier"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("density"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("cap"))
        // The technical reason stays available for developer logs.
        XCTAssertTrue(error.debugDetail?.contains("candidate") == true)
    }

    // MARK: - Repair hardening

    /// Malformed notes (NaN, negative time, invalid lane) are dropped by
    /// repair so a single bad note can't doom an otherwise fine chart.
    func testRepairDropsMalformedNotes() {
        let constraints = ChartConstraints.forDifficulty(.medium, densityMultiplier: 1.0)
        let good: [ChartNote] = [
            ChartNote(id: 0, time: 1.0, lane: 0, duration: 0, type: .tap, strength: 0.8),
            ChartNote(id: 1, time: 1.5, lane: 1, duration: 0, type: .tap, strength: 0.8)
        ]
        let malformed: [ChartNote] = [
            ChartNote(id: 2, time: .nan, lane: 0, duration: 0, type: .tap, strength: 0.8),
            ChartNote(id: 3, time: 2.0, lane: 7, duration: 0, type: .tap, strength: 0.8),
            ChartNote(id: 4, time: -0.5, lane: 2, duration: 0, type: .tap, strength: 0.8),
            ChartNote(id: 5, time: 2.5, lane: 3, duration: -1, type: .hold, strength: 0.8)
        ]
        let repaired = ChartValidator.repair(good + malformed, constraints: constraints)
        XCTAssertEqual(repaired.count, 2)
        let validation = ChartValidator.validate(repaired, constraints: constraints)
        XCTAssertEqual(validation.hardFailureCount, 0)
    }

    /// A chart exceeding the notes-per-second cap is thinned by repair until
    /// its chord-group anchor rate fits, instead of being rejected outright.
    func testRepairEnforcesDensityCap() {
        let constraints = ChartConstraints.forDifficulty(.hard, densityMultiplier: 1.0)
        // maxNPS for hard = min(12, max(6, 4.2*1.5)) = 6.3 → 200 notes at 0.03s
        // spacing is ~33 events/s — wildly over cap.
        let notes = (0..<200).map { i in
            ChartNote(id: i, time: Double(i) * 0.03, lane: i % 4, duration: 0,
                      type: .tap, strength: Double(i % 10) / 10)
        }
        let repaired = ChartValidator.repair(notes, constraints: constraints)
        XCTAssertGreaterThan(repaired.count, 0)
        XCTAssertLessThanOrEqual(repaired.count, 120)   // 200 * 0.03 ≈ 6s → ≤ 38 anchors + slack
        let validation = ChartValidator.validate(repaired, constraints: constraints)
        if validation.hardFailureCount > 0 {
            // Print the offending neighbor pairs for diagnosis.
            let sorted = repaired.sorted { $0.time < $1.time }
            var groups: [[ChartNote]] = [[sorted[0]]]
            for i in 1..<sorted.count {
                if sorted[i].time - groups[groups.count - 1][0].time < 0.1 {
                    groups[groups.count - 1].append(sorted[i])
                } else {
                    groups.append([sorted[i]])
                }
            }
            for g in 1..<groups.count {
                let prev = groups[g - 1], cur = groups[g]
                let gap = cur[0].time - prev[0].time
                var jump = 3
                for a in prev.map(\.lane) { for b in cur.map(\.lane) { jump = min(jump, abs(a - b)) } }
                if jump == 2 && gap < constraints.minGapForJump2 {
                    print("PAIR prev=\(prev.map { ($0.time, $0.lane) }) cur=\(cur.map { ($0.time, $0.lane) }) gap=\(gap)")
                }
            }
            print("ALL: \(sorted.map { ($0.time, $0.lane) })")
        }
        XCTAssertEqual(validation.hardFailureCount, 0, validation.hardFailures.joined(separator: " | "))
        // Concrete bound: the densest 1s window fits the cap.
        let anchors = Self.anchorTimes(repaired)
        var maxWindow = 0
        var right = 0
        for left in 0..<anchors.count {
            while right < anchors.count && anchors[right] - anchors[left] < 1.0 { right += 1 }
            maxWindow = max(maxWindow, right - left)
        }
        XCTAssertLessThanOrEqual(Double(maxWindow), constraints.maxNPS)
    }

    // MARK: - Beat tracker hardening

    /// Double-beat artifacts in the onset envelope are merged: no two beats
    /// can sit closer than the absolute 0.09 s floor.
    func testBeatTrackerMergesSubFloorBeatGaps() {
        let hopTime = 512.0 / 44100.0
        let length = Int(20.0 / hopTime)
        // Impulses every 0.04 s (~1,500 "BPM" artifact density).
        var times: [Double] = []
        var t = 1.0
        while t < 19.0 {
            times.append(t)
            t += 0.04
        }
        let flux = SignalFixtures.impulseFlux(times: times, hopTime: hopTime, length: length)
        let track = BeatTracker.track(flux: flux, hopTime: hopTime, bpm: 120, confidence: 0.9)
        XCTAssertGreaterThanOrEqual(track.beats.count, 2)
        for i in 1..<track.beats.count {
            XCTAssertGreaterThanOrEqual(track.beats[i].time - track.beats[i - 1].time, 0.09 - 1e-9,
                                        "beats closer than the absolute floor")
        }
    }

    // MARK: - Helpers

    /// Times of chord-group anchors (first note of each group; later voices
    /// within 0.1 s are members).
    private static func anchorTimes(_ notes: [ChartNote]) -> [Double] {
        let sorted = notes.sorted { $0.time < $1.time }
        var anchors: [Double] = []
        for note in sorted {
            if let last = anchors.last, note.time - last < 0.1 { continue }
            anchors.append(note.time)
        }
        return anchors
    }
}