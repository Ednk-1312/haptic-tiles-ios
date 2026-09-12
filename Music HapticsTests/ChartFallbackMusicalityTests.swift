import XCTest
@testable import Music_Haptics

/// Tests for the tier-4 fallback chart path: accent-prioritized beat
/// selection and pattern-aware lanes (never a raw round-robin dump).
final class ChartFallbackMusicalityTests: XCTestCase {

    private func beat(_ time: Double, _ strength: Double, strong: Bool = false) -> Beat {
        Beat(time: time, strength: strength, isStrong: strong)
    }

    // MARK: - Accent-prioritized selection

    func testStrongBeatWinsOverWeakWithinWindow() {
        // Two beats 0.1 s apart: the weak one at 1.0, the strong one at 1.1.
        let beats = [beat(1.0, 0.2), beat(1.1, 0.2, strong: true)]
        let selected = ChartGenerator.selectAccentBeats(beats, minSpacing: 0.18)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected[0].time, 1.1, accuracy: 0.0001)
        // Strength inherits the strong-beat accent bonus (0.2·0.9 + 0.2 = 0.38),
        // clearly above a plain weak beat (0.2·0.9 = 0.18).
        XCTAssertGreaterThan(selected[0].strength, 0.3)
    }

    func testSpacingNeverBelowMinimum() {
        var beats: [Beat] = []
        for i in 0..<50 {
            beats.append(beat(0.05 * Double(i), 0.5, strong: i % 4 == 0))
        }
        let selected = ChartGenerator.selectAccentBeats(beats, minSpacing: 0.18)
        for i in 1..<selected.count {
            XCTAssertGreaterThanOrEqual(selected[i].time - selected[i - 1].time, 0.18 - 1e-9)
        }
        // Grid double-detection collapses: 50 ticks/2.45 s → far fewer notes.
        XCTAssertLessThan(selected.count, 20)
    }

    func testDownbeatsPreferredWhenDoubleDetected() {
        // 0.1 s grid (faster than the 0.18 spacing window) where every other
        // beat is strong — the strong beats must win the local window, so the
        // picked times land on multiples of 0.2 (not on the weak 0.1 grid).
        var beats: [Beat] = []
        for i in 0..<20 {
            beats.append(beat(0.1 * Double(i), 0.4, strong: i % 2 == 0))
        }
        let selected = ChartGenerator.selectAccentBeats(beats, minSpacing: 0.18)
        XCTAssertFalse(selected.isEmpty)
        for s in selected {
            let offGrid = s.time.truncatingRemainder(dividingBy: 0.2)
            let onGrid = abs(offGrid) < 1e-9 || abs(offGrid - 0.2) < 1e-9
            XCTAssertTrue(onGrid, "picked beat \(s.time) should be a strong-beat multiple")
        }
    }

    func testSelectionIsDeterministic() {
        let beats = [beat(0.5, 0.3), beat(0.7, 0.8), beat(0.9, 0.2, strong: true),
                     beat(1.3, 0.6), beat(1.5, 0.1), beat(2.0, 0.9, strong: true)]
        let a = ChartGenerator.selectAccentBeats(beats, minSpacing: 0.2)
        let b = ChartGenerator.selectAccentBeats(beats, minSpacing: 0.2)
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.time, y.time)
            XCTAssertEqual(x.strength, y.strength)
        }
    }

    func testEmptyInput() {
        XCTAssertTrue(ChartGenerator.selectAccentBeats([], minSpacing: 0.18).isEmpty)
    }

    // MARK: - Pattern-aware lanes (no round-robin 1→2→3→4)

    func testFallbackLanesAreNotRawRoundRobin() {
        // Feed 12 evenly spaced beats; the old tier-4 cycled lanes 0,1,2,3,0…
        // PatternGenerator must NOT produce the exact round-robin sequence.
        let beats = (0..<12).map { beat(0.5 + 0.25 * Double($0), 0.6) }
        let selected = ChartGenerator.selectAccentBeats(beats, minSpacing: 0.18)
        XCTAssertEqual(selected.count, 12)
        var rng = SplitMix64(state: 42)
        let placed = selected.map { (time: $0.time, strength: $0.strength, allowPair: false) }
        let notes = PatternGenerator.assignLanes(to: placed, rng: &rng)
            .sorted { $0.time < $1.time }
        let lanes = notes.map(\.lane)
        XCTAssertEqual(lanes.count, 12)
        XCTAssertNotEqual(lanes, [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3])
        // Lane balance stays sane (no lane starved).
        for lane in 0..<4 {
            XCTAssertGreaterThanOrEqual(lanes.filter { $0 == lane }.count, 1)
        }
        // Feasible movement: no 1↔4 bouncing between consecutive notes.
        for i in 1..<lanes.count {
            XCTAssertLessThanOrEqual(abs(lanes[i] - lanes[i - 1]), 3)
        }
    }

    func testFallbackLaneAssignmentIsDeterministic() {
        let beats = (0..<8).map { beat(0.5 + 0.25 * Double($0), 0.6) }
        let selected = ChartGenerator.selectAccentBeats(beats, minSpacing: 0.18)
        func lanes() -> [Int] {
            var rng = SplitMix64(state: 7)
            let placed = selected.map { (time: $0.time, strength: $0.strength, allowPair: false) }
            return PatternGenerator.assignLanes(to: placed, rng: &rng).sorted { $0.time < $1.time }.map(\.lane)
        }
        XCTAssertEqual(lanes(), lanes())
    }
}