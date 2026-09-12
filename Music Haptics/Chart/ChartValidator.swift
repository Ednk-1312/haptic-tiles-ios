import Foundation

struct ChartConstraints: Sendable {
    var minSpacing: Double        // absolute floor between any two notes
    var maxNPS: Double            // hard cap on notes per second
    var maxSimultaneous: Int      // max notes within 0.1s
    var minSameLaneGap: Double
    var maxJump: Int
    var minGapForJump2: Double
    var minGapForJump3: Double
    var maxSpikeRatio: Double

    static func forDifficulty(_ difficulty: DifficultyLevel, densityMultiplier: Double) -> ChartConstraints {
        ChartConstraints(
            minSpacing: max(difficulty.minSpacing, 0.045),
            maxNPS: min(12, max(6, difficulty.targetNPS * 1.5 * densityMultiplier)),
            maxSimultaneous: difficulty.maxSimultaneous,
            minSameLaneGap: 0.13,
            maxJump: 3,
            minGapForJump2: 0.26,
            minGapForJump3: 0.5,
            maxSpikeRatio: 1.8
        )
    }
}

struct ValidationResult: Sendable {
    var hardFailures: [String]
    var warnings: [String]
    var hardFailureCount: Int { hardFailures.count }
}

/// Playability gatekeeper. Checks spacing, density, simultaneity, lane jumps,
/// same-lane repetition, spikes and pathological patterns; can repair or reject.
enum ChartValidator {
    static func validate(_ notes: [ChartNote], constraints: ChartConstraints) -> ValidationResult {
        var hard: [String] = []
        var warnings: [String] = []
        // Malformed-note gate: NaN comparisons are ALWAYS false, so a non-finite
        // value would silently pass every check below. Reject them up front.
        for note in notes {
            if !note.time.isFinite || !note.duration.isFinite || !note.strength.isFinite
                || !(0..<4).contains(note.lane)
                || note.time < 0 || note.duration < 0 {
                hard.append("Malformed note (non-finite or out of range) at \(note.time)")
            }
        }
        guard notes.count > 1 else {
            return ValidationResult(hardFailures: notes.isEmpty ? ["Chart is empty"] : hard, warnings: warnings)
        }
        let sorted = notes.sorted { $0.time < $1.time }
        guard hard.isEmpty else {
            return ValidationResult(hardFailures: hard, warnings: warnings)
        }

        // Chord-aware spacing: notes within 0.1s of the group's first note are
        // ONE musical event (a chord) — the player hits them together. Spacing
        // and jump rules therefore apply BETWEEN chord groups, not between
        // individual chord voices. Lane uniqueness inside a chord is enforced
        // by the same-lane rule below, and the simultaneity check caps group
        // size. (Without this, every chord pair reads as a 0 ms spacing
        // violation and gets repaired away.)
        //
        // Chord jumps use MIN distance between the two groups' lane sets: a
        // chord (0,2) after a lane-3 note is reachable (lane 2 is adjacent),
        // even though one voice is 3 lanes away.
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
            if gap < constraints.minSpacing {
                hard.append("Notes are \(Int(gap * 1000))ms apart (min \(Int(constraints.minSpacing * 1000))ms)")
            }
            let jump = minLaneDistance(prev.map(\.lane), cur.map(\.lane))
            if jump > constraints.maxJump {
                hard.append("Lane jump of \(jump) is impossible")
            }
            if jump == 3 && gap < constraints.minGapForJump3 {
                hard.append("1↔4 jump only \(Int(gap * 1000))ms apart")
            }
            if jump == 2 && gap < constraints.minGapForJump2 {
                hard.append("2-lane jump only \(Int(gap * 1000))ms apart")
            }
        }

        // Same-lane rule with hold awareness: a note's body occupies its lane
        // until time + duration, so the next note in that lane must clear the
        // TAIL (plus the same-lane gap), not just the head. Taps (duration 0)
        // behave exactly as before.
        var lastInLane = [Int](repeating: -1, count: 4)
        for i in sorted.indices {
            let note = sorted[i]
            if note.lane >= 0, note.lane < lastInLane.count {
                let prevIdx = lastInLane[note.lane]
                if prevIdx >= 0 {
                    let prev = sorted[prevIdx]
                    let tail = prev.time + prev.duration
                    if note.time < tail - 0.001 {
                        hard.append("Note \(i) overlaps a hold in lane \(note.lane + 1)")
                    } else if note.time - tail < constraints.minSameLaneGap {
                        hard.append("Same-lane repeat \(Int((note.time - tail) * 1000))ms after hold/tap in lane \(note.lane + 1)")
                    }
                }
                lastInLane[note.lane] = i
            }
        }

        // Density: max CHORD GROUPS in any 1s window (a chord is one event for
        // readability; its extra voices are governed by the simultaneity cap).
        var anchors: [ChartNote] = []
        for note in sorted {
            if let last = anchors.last, note.time - last.time < 0.1 { continue }
            anchors.append(note)
        }
        var maxWindow = 0
        var right = 0
        for left in 0..<anchors.count {
            while right < anchors.count && anchors[right].time - anchors[left].time < 1.0 { right += 1 }
            maxWindow = max(maxWindow, right - left)
        }
        if Double(maxWindow) > constraints.maxNPS {
            hard.append("Density \(maxWindow) events/s exceeds cap \(String(format: "%.1f", constraints.maxNPS))")
        }

        // Simultaneity: notes within 0.1s.
        for i in 0..<sorted.count {
            var count = 0
            for j in i..<sorted.count where sorted[j].time - sorted[i].time < 0.1 {
                count += 1
            }
            if count > constraints.maxSimultaneous {
                hard.append("\(count) simultaneous notes (max \(constraints.maxSimultaneous))")
                break
            }
        }

        // Spikes: sustained windows much denser than the average (chord-aware).
        if anchors.count > 20 {
            let overall = Double(anchors.count) / max(anchors.last!.time - anchors.first!.time, 1)
            var spikeWindow = 0
            right = 0
            for left in 0..<anchors.count {
                while right < anchors.count && anchors[right].time - anchors[left].time < 3.0 { right += 1 }
                spikeWindow = max(spikeWindow, right - left)
            }
            let spikeNPS = Double(spikeWindow) / 3.0
            if overall > 0.5 && spikeNPS > overall * constraints.maxSpikeRatio {
                warnings.append("Difficulty spike: \(String(format: "%.1f", spikeNPS)) events/s vs \(String(format: "%.1f", overall)) average")
            }
        }

        // Extreme bounce pattern 1-4-1-4 (or 4-1-4-1).
        var bounce = 0
        for i in 2..<sorted.count {
            let l = sorted[i].lane, p1 = sorted[i - 1].lane, p2 = sorted[i - 2].lane
            if l == p2 && ((l == 0 && p1 == 3) || (l == 3 && p1 == 0)) {
                bounce += 1
                if bounce >= 3 {
                    warnings.append("Repeated 1↔4 bouncing pattern")
                    break
                }
            }
        }

        return ValidationResult(hardFailures: hard, warnings: warnings)
    }

    /// Drops violating notes, twice, then returns. Chord-group aware: notes
    /// within 0.1s of the group's first note are one event, so spacing/jump
    /// rules compare each note against the previous group's ANCHOR, the group
    /// is capped at `maxSimultaneous`, and lane conflicts (same-lane chord
    /// voices, hold bodies) still drop the offending note.
    ///
    /// - Parameter keptGroupLanes: lanes of the CURRENT group's already-kept
    ///   voices, used as the previous group for the NEXT group's jump checks.
    private static func keptGroupLanes(_ group: [ChartNote], keep: [ChartNote]) -> [Int] {
        // Lanes of the group's kept notes: everything in `keep` whose time is
        // within [first, first + 0.1) — the group's OWN members. The lower
        // bound is REQUIRED: without it the filter also accumulated every
        // earlier kept lane (negative differences satisfy `< 0.1`), so
        // `prevGroupLanes` grew without bound and the jump checks became
        // vacuous — a 1↔4 bounce at 150 ms could survive repair.
        guard let first = group.first else { return [] }
        return keep.filter { $0.time >= first.time && $0.time - first.time < 0.1 }.map(\.lane)
    }

    /// Minimum lane distance between two lane sets (chord-aware jumps). Empty
    /// input (first group) imposes no constraint.
    private static func minLaneDistance(_ a: [Int], _ b: [Int]) -> Int {
        var best = 3
        for x in a where (0..<4).contains(x) {
            for y in b where (0..<4).contains(y) {
                best = min(best, abs(x - y))
            }
        }
        return a.isEmpty || b.isEmpty ? 0 : best
    }

    /// Drops violating notes, twice, then returns. Chord-group aware: notes
    /// within 0.1s of the group's first note are one event, so spacing/jump
    /// rules compare each note against the previous group's ANCHOR, the group
    /// is capped at `maxSimultaneous`, and lane conflicts (same-lane chord
    /// voices, hold bodies) still drop the offending note.
    static func repair(_ notes: [ChartNote], constraints: ChartConstraints) -> [ChartNote] {
        // Malformed notes are DROPPED up front: the validation gate rejects
        // them (NaN/negative time/duration, out-of-range lane, non-finite
        // strength) and no amount of spacing/lane surgery can fix them —
        // without this, a single bad note made the whole candidate unrepairable
        // and generation failed with "unplayable pattern (candidate N)".
        var result = notes.filter { note in
            note.time.isFinite && note.duration.isFinite && note.strength.isFinite
                && (0..<4).contains(note.lane) && note.time >= 0 && note.duration >= 0
        }.sorted { $0.time < $1.time }
        result = Self.spacingRepair(result, constraints: constraints)
        // Density cap: the passes above fix spacing/jumps/lanes, but a chart
        // that EXCEEDS maxNPS (dense template fills + catch-up pushes on fast
        // songs) can never pass validation without thinning. Drop the weakest
        // anchor of the densest 1s window until the window rate fits the cap.
        // Deterministic: windows scan left→right, ties keep the earliest.
        result = Self.thinToDensityCap(result, constraints: constraints)
        // Thinning can make two remaining notes neighbors that violate the
        // jump/gap rules — one more spacing pass restores playability.
        result = Self.spacingRepair(result, constraints: constraints)
        return result
    }

    /// One spacing/lane/jump/overlap pass (keeps chord groups intact).
    private static func spacingRepair(_ notes: [ChartNote],
                                      constraints: ChartConstraints) -> [ChartNote] {
        var result = notes.sorted { $0.time < $1.time }
        for _ in 0..<2 {
            var keep: [ChartNote] = []
            var lastInLane = [ChartNote?](repeating: nil, count: 4)
            var prevGroupAnchor: ChartNote?
            var prevGroupLanes: [Int] = []
            var i = 0
            while i < result.count {
                // One chord group: everything within 0.1s of the group's first note.
                var group: [ChartNote] = []
                var j = i
                while j < result.count, result[j].time - result[i].time < 0.1 {
                    group.append(result[j])
                    j += 1
                }
                var firstKept: ChartNote?
                var keptInGroup = 0
                for note in group {
                    // Same-lane conflicts: hold bodies and same-lane chords.
                    if note.lane >= 0, note.lane < lastInLane.count,
                       let prev = lastInLane[note.lane],
                       note.time < prev.time + prev.duration + constraints.minSameLaneGap {
                        continue
                    }
                    guard keptInGroup < constraints.maxSimultaneous else { continue }
                    // Spacing/jump rules apply BETWEEN groups only — every note
                    // in this group is a chord voice of the same musical event,
                    // compared against the PREVIOUS group's first kept note.
                    if let prevGroupAnchor {
                        let gap = note.time - prevGroupAnchor.time
                        let jump = minLaneDistance(prevGroupLanes, [note.lane])
                        let spacingOK = gap >= constraints.minSpacing
                        let jumpOK = jump <= constraints.maxJump
                            && !(jump == 3 && gap < constraints.minGapForJump3)
                            && !(jump == 2 && gap < constraints.minGapForJump2)
                        if !spacingOK || !jumpOK { continue }
                    }
                    keep.append(note)
                    if note.lane >= 0, note.lane < lastInLane.count {
                        lastInLane[note.lane] = note
                    }
                    if firstKept == nil { firstKept = note }
                    keptInGroup += 1
                }
                // The previous group for the NEXT group's checks is this
                // group's first kept note and its full kept lane set.
                prevGroupAnchor = firstKept
                prevGroupLanes = keptGroupLanes(group, keep: keep)
                i = j
            }
            result = keep
        }
        return result
    }

    /// Repeatedly drops the weakest anchor of the densest 1-second window
    /// until the window rate fits maxNPS. Returns the thinned list.
    private static func thinToDensityCap(_ notes: [ChartNote],
                                         constraints: ChartConstraints) -> [ChartNote] {
        var result = notes.sorted { $0.time < $1.time }
        while !result.isEmpty {
            var anchors: [(index: Int, time: Double, strength: Double)] = []
            for (i, note) in result.enumerated() {
                if let last = anchors.last, note.time - result[last.index].time < 0.1 { continue }
                anchors.append((i, note.time, note.strength))
            }
            if anchors.isEmpty { break }
            var maxCount = 0
            var maxLeft = 0
            var right = 0
            for left in 0..<anchors.count {
                while right < anchors.count && anchors[right].time - anchors[left].time < 1.0 { right += 1 }
                if right - left > maxCount { maxCount = right - left; maxLeft = left }
            }
            if Double(maxCount) <= constraints.maxNPS { break }
            var drop = maxLeft
            for k in (maxLeft + 1)..<(maxLeft + maxCount) where anchors[k].strength < anchors[drop].strength {
                drop = k
            }
            result.remove(at: anchors[drop].index)
        }
        return result
    }
}