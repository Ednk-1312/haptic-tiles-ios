import Foundation

/// Lane assignment. Rules keep patterns intentional, thumb-playable AND spread
/// naturally across all four lanes:
/// - tight streams alternate on a lane pair, but a pair only keeps its bonus
///   for a short run — then the chart *migrates* instead of looping forever
///   on the same two lanes (the old 3→4→3→4 / right-side bias),
/// - medium gaps walk to adjacent lanes,
/// - big jumps are reserved for slow passages,
/// - extreme 1↔4 bouncing is penalized,
/// - after a warm-up, per-lane usage pressure gently favors underused lanes so
///   no lane is starved while movement stays musical.
/// Assignment is seeded, so the same chart regenerates identically.
enum PatternGenerator {
    private struct Context {
        var usage = [0, 0, 0, 0]         // notes placed per lane
        var lastLane = -1
        var secondLastLane = -1
        var lastTime = -Double.infinity
        var pairRun = 0                  // consecutive alternations on one pair
        var pairA = -1
        var pairB = -1

        mutating func register(lane: Int, time: Double) {
            usage[lane] += 1
            secondLastLane = lastLane
            lastLane = lane
            lastTime = time
            // Track alternation runs on a fixed two-lane pair.
            let prev = secondLastLane
            if prev >= 0, prev != lastLane {
                if (pairA == prev && pairB == lastLane) || (pairA == lastLane && pairB == prev) {
                    pairRun += 1
                } else {
                    pairA = prev
                    pairB = lastLane
                    pairRun = 1
                }
            } else {
                pairA = -1
                pairB = -1
                pairRun = 0
            }
        }
    }

    static func assignLanes(to placed: [(time: Double, strength: Double, allowPair: Bool)],
                            rng: inout SplitMix64,
                            preferredLanes: [Int?]? = nil) -> [ChartNote] {
        var result: [ChartNote] = []
        var ctx = Context()
        var pendingPairIndex: Int?

        for (i, item) in placed.enumerated() {
            let preferred = preferredLanes?[safe: i] ?? nil
            // Simultaneous pair: this note joins the previous one on outer lanes.
            if let partnerIndex = pendingPairIndex,
               placed[partnerIndex].allowPair,
               abs(placed[partnerIndex].time - item.time) < 0.06 {
                let partnerPreferred = preferredLanes?[safe: partnerIndex] ?? nil
                let pairStart: Int
                if let partnerPreferred { pairStart = partnerPreferred % 2 }        // 0/1 → (0,2) or (1,3)
                else { pairStart = rng.uniform() < 0.5 ? 0 : 1 }
                let lanes = (pairStart, pairStart + 2)
                result[partnerIndex] = ChartNote(id: partnerIndex, time: placed[partnerIndex].time,
                                                 lane: lanes.0, duration: 0, type: .tap,
                                                 strength: placed[partnerIndex].strength)
                result.append(ChartNote(id: i, time: item.time, lane: lanes.1, duration: 0,
                                        type: .tap, strength: item.strength))
                ctx.register(lane: lanes.0, time: placed[partnerIndex].time)
                ctx.register(lane: lanes.1, time: item.time)
                pendingPairIndex = nil
                continue
            }

            let gap = item.time - ctx.lastTime
            let lane = chooseLane(gap: gap, ctx: ctx, rng: &rng, preferred: preferred)
            result.append(ChartNote(id: i, time: item.time, lane: lane, duration: 0,
                                    type: .tap, strength: item.strength))
            ctx.register(lane: lane, time: item.time)
            if item.allowPair { pendingPairIndex = i }
        }
        return result
    }

    /// Cost-based lane choice with pattern bonuses, motif preference and
    /// lane-balance pressure. `preferred` is the phrase motif's lane for this
    /// note (nil = free); it biases but never overrides the safety costs.
    private static func chooseLane(gap: Double, ctx: Context, rng: inout SplitMix64,
                                  preferred: Int?) -> Int {
        let total = ctx.usage.reduce(0, +)
        let leastUsed = ctx.usage.min() ?? 0
        var costs = [Double](repeating: 0, count: 4)
        for lane in 0..<4 {
            guard ctx.lastLane >= 0 else {
                costs[lane] = rng.uniform()
                continue
            }
            // Small seeded tie-breaker only; patterns come from the rules below.
            var cost = rng.uniform() * 0.10
            let distance = abs(lane - ctx.lastLane)
            if lane == ctx.lastLane {
                // Repeating a lane is only comfortable when there is room.
                cost += gap < 0.35 ? 5.5 : 0.9
            } else {
                // Jumps cost more when notes are close together.
                cost += Double(distance) * (gap < 0.3 ? 2.5 : gap < 0.6 ? 1.2 : 0.4)
                if distance == 1 { cost -= 0.7 }   // walking is comfortable
                if distance == 2, gap >= 0.35 { cost -= 0.6 }   // skip-flourish when roomy
            }
            if distance == 3 && gap < 0.5 { cost += 4 }    // 1↔4 only when slow
            if distance == 2 && gap < 0.28 { cost += 3 }

            // Continue an established alternation (a,b,a,b…) — but a pair that
            // has been alternating for a while must give way so the stream
            // migrates across the board instead of looping on one pair.
            let prev = ctx.secondLastLane
            if prev >= 0, lane == prev, lane != ctx.lastLane {
                let onRunningPair = (ctx.pairA == lane && ctx.pairB == ctx.lastLane)
                    || (ctx.pairA == ctx.lastLane && ctx.pairB == lane)
                if onRunningPair && ctx.pairRun >= 6 {
                    cost += 0.6                     // pair worn out: push onward
                } else if onRunningPair && ctx.pairRun >= 4 {
                    cost -= 0.6                     // fresh-ish pair still cheap
                } else {
                    cost -= 1.6                     // very fresh alternation
                }
            }

            // Penalize bouncing between the two extremes (1,4,1,4,…).
            if ctx.lastLane == 0 && ctx.secondLastLane == 3 && lane == 0 { cost += 3 }
            if ctx.lastLane == 3 && ctx.secondLastLane == 0 && lane == 3 { cost += 3 }

            // Lane-balance pressure (after a short warm-up): underused lanes
            // become cheaper so the whole width of the board gets used.
            if total >= 6 {
                cost += 0.6 * Double(max(0, ctx.usage[lane] - leastUsed))
            }
            // Phrase-motif preference: the desired lane gets a solid bonus,
            // neighbors a tiny nudge; safety costs above still win in tight
            // spots so the motif can never force an impossible move.
            if let preferred {
                if lane == preferred { cost -= 1.15 }
                else if abs(lane - preferred) == 1 { cost += 0.12 }
            }
            costs[lane] = cost
        }
        var best = 0
        for lane in 1..<4 where costs[lane] < costs[best] { best = lane }
        return best
    }
}

private extension Array {
    /// Bounds-safe subscript for the motif lookup tables.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}