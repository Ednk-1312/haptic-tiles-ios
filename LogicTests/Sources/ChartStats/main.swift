import Foundation
@testable import Music_Haptics

// ChartStats — deterministic before/after report for the v4 chart generator.
//
// Synthesizes a set of deterministic AudioAnalysis "profiles" (sparse ballad,
// vocal-heavy pop, drum-heavy, fast, slow, quiet-intro→chorus, and a
// pathological beat-less case), then generates charts with the v3 legacy
// per-cell selection and the v4 phrase/pattern selection on IDENTICAL inputs
// (same seeds, same difficulty), and prints both with full analytics:
// notes, NPS, quality score, rests, chords, holds, patterns, lane balance,
// section density and repairs.
//
// Usage:
//   swift run ChartStats
//
// Output is a plain-text table, deterministic for a given toolchain.

// MARK: - Deterministic synthetic profiles

struct ProfileSpec: Sendable {
    var name: String
    var duration: Double
    var bpm: Double
    var eventDensity: Double          // events per beat (0…4)
    var eventStrength: @Sendable (Double) -> Double   // 0…1 by beat index
    var sections: [(fraction: Double, label: SectionLabel, energy: Double)]
    var pathological: Bool            // no beats / no tempo (legacy fallback)
}

enum ProfileFactory {
    static func analysis(_ spec: ProfileSpec) -> AudioAnalysis {
        var rng = SplitMix64(state: 0xC0FF_EE &+ UInt64(spec.name.count &* 31))
        let beatInterval = spec.pathological ? 0 : 60.0 / spec.bpm

        var beats: [Beat] = []
        var events: [MusicalEvent] = []
        var onsets: [OnsetEvent] = []

        if !spec.pathological {
            var t = 0.0
            var i = 0
            while t < spec.duration - beatInterval {
                let strength = spec.eventStrength(Double(i))
                beats.append(Beat(time: t, strength: min(1, 0.35 + 0.65 * strength), isStrong: i % 4 == 0))
                let perBeat = Int(spec.eventDensity)
                for k in 0..<max(1, perBeat) {
                    let et = t + Double(k) / Double(max(1, perBeat)) * beatInterval
                    guard et < spec.duration - 0.5 else { continue }
                    let s = 0.35 + 0.65 * rng.uniform()
                    let importance = 0.3 + 0.7 * strength * (1 - 0.4 * rng.uniform())
                    events.append(MusicalEvent(time: et, strength: s, confidence: 0.7,
                                               type: k == 0 ? .beat : .percussive,
                                               lowEnergy: 0.5, midEnergy: 0.5, highEnergy: 0.5,
                                               isOnBeat: k == 0, beatStrength: k == 0 ? strength : 0,
                                               sectionIndex: 0, importance: importance))
                    onsets.append(OnsetEvent(time: et, strength: Float(s), confidence: 0.7))
                }
                t += beatInterval
                i += 1
            }
        } else {
            // Ambient wash: many weak events, no beat grid at all.
            var t = 0.5
            while t < spec.duration - 1.0 {
                let s = 0.15 + 0.25 * rng.uniform()
                events.append(MusicalEvent(time: t, strength: s, confidence: 0.3, type: .melodic,
                                           lowEnergy: 0.6, midEnergy: 0.3, highEnergy: 0.1,
                                           isOnBeat: false, beatStrength: 0, sectionIndex: 0,
                                           importance: 0.2 + 0.3 * rng.uniform()))
                onsets.append(OnsetEvent(time: t, strength: Float(s), confidence: 0.3))
                t += 0.25 + 0.35 * rng.uniform()
            }
        }
        events.sort { $0.time < $1.time }
        onsets.sort { $0.time < $1.time }

        var sections: [SongSection] = []
        var cursor = 0.0
        for (i, part) in spec.sections.enumerated() {
            let end = min(spec.duration, part.fraction * spec.duration)
            sections.append(SongSection(index: i, start: cursor, end: end,
                                        label: part.label, energy: part.energy))
            cursor = end
        }
        if cursor < spec.duration {
            sections.append(SongSection(index: sections.count, start: cursor, end: spec.duration,
                                        label: .outro, energy: 0.35))
        }

        return AudioAnalysis(duration: spec.duration, sampleRate: 44100,
                             tempoBPM: spec.pathological ? nil : spec.bpm,
                             tempoConfidence: spec.pathological ? nil : 0.9,
                             beats: beats, onsets: onsets, events: events, sections: sections,
                             waveform: [], averageEnergy: 0.5, analysisDuration: 0, hopTime: 0.01)
    }

    static let profiles: [ProfileSpec] = [
        ProfileSpec(name: "sparse-ballad", duration: 40, bpm: 72, eventDensity: 1.0,
                    eventStrength: { beat in Int(beat) % 8 == 0 ? 1.0 : (Int(beat) % 4 == 2 ? 0.55 : 0.3) },
                    sections: [(0.12, .intro, 0.2), (0.55, .verse, 0.5), (1.0, .chorus, 0.7)],
                    pathological: false),
        ProfileSpec(name: "vocal-pop", duration: 44, bpm: 112, eventDensity: 2.0,
                    eventStrength: { beat in 0.4 + 0.6 * Double(Int(beat) % 4 == 0 ? 1 : (Int(beat) % 2 == 0 ? 0.7 : 0.5)) },
                    sections: [(0.10, .intro, 0.35), (0.45, .verse, 0.6), (0.55, .generic, 0.7), (1.0, .chorus, 0.9)],
                    pathological: false),
        ProfileSpec(name: "drum-heavy", duration: 36, bpm: 128, eventDensity: 3.0,
                    eventStrength: { beat in 0.5 + 0.5 * Double(Int(beat) % 2 == 0 ? 1 : 0.55) },
                    sections: [(0.15, .intro, 0.4), (1.0, .chorus, 0.95)],
                    pathological: false),
        ProfileSpec(name: "fast-160", duration: 32, bpm: 160, eventDensity: 2.5,
                    eventStrength: { beat in 0.45 + 0.55 * Double(Int(beat) % 4 == 0 ? 1 : 0.5) },
                    sections: [(0.2, .generic, 0.7), (1.0, .chorus, 1.0)],
                    pathological: false),
        ProfileSpec(name: "slow-60", duration: 48, bpm: 60, eventDensity: 1.5,
                    eventStrength: { beat in 0.4 + 0.6 * Double(Int(beat) % 4 == 0 ? 1 : 0.35) },
                    sections: [(0.2, .verse, 0.45), (0.75, .chorus, 0.65), (1.0, .breakdown, 0.3)],
                    pathological: false),
        ProfileSpec(name: "quiet-intro-chorus", duration: 52, bpm: 100, eventDensity: 2.0,
                    eventStrength: { beat in min(1, 0.2 + 0.8 * Double(beat) / 130) },
                    sections: [(0.15, .intro, 0.12), (0.4, .verse, 0.35), (0.6, .generic, 0.6),
                               (0.75, .breakdown, 0.2), (1.0, .chorus, 0.9)],
                    pathological: false),
        ProfileSpec(name: "ambient-no-beats", duration: 30, bpm: 0, eventDensity: 0,
                    eventStrength: { _ in 0.2 },
                    sections: [(1.0, .generic, 0.35)],
                    pathological: true)
    ]
}

// MARK: - Report

struct Row {
    var name: String
    var difficulty: DifficultyLevel
    var mode: String
    var notes: Int
    var nps: Double
    var quality: Double
    var rests: Double
    var chords: Double
    var holds: Double
    var minLaneShare: Double
    var repairs: Int
    var variance: Double
    var patterns: String
    var sectionNPS: String
    var valid: Bool
}

nonisolated func generate(mode: String) async -> [Row] {
    var rows: [Row] = []
    for spec in ProfileFactory.profiles {
        log("== \(mode) \(spec.name)...")
        let analysis = ProfileFactory.analysis(spec)
        for difficulty in [DifficultyLevel.easy, .medium, .hard] {
            let request = ChartGenerator.Request(difficulty: difficulty, densityMultiplier: 1.0,
                                                 seed: 0x5EED + UInt64(spec.name.count &* 7))
            ChartGenerator.forceLegacySelection = (mode == "v3-legacy")
            log("   \(difficulty.rawValue) generating...")
            guard let output = try? await ChartGenerator().generate(analysis: analysis,
                                                                    songID: UUID(), request: request) else {
                rows.append(Row(name: spec.name, difficulty: difficulty, mode: mode, notes: 0, nps: 0,
                                quality: 0, rests: 0, chords: 0, holds: 0, minLaneShare: 0,
                                repairs: 0, variance: 0, patterns: "FAILED", sectionNPS: "", valid: false))
                continue
            }
            let a = ChartAnalyticsBuilder.analyze(chart: output.chart, analysis: analysis)
            let shares = a.laneShares
            let patternSummary = RhythmTemplate.allCases
                .map { t in "\(t.rawValue):\(a.templateCounts[t.rawValue] ?? 0)" }
                .filter { !$0.hasSuffix(":0") }
                .joined(separator: " ")
            let sectionSummary = a.sectionDensity
                .map { "\($0.label)=\(String(format: "%.1f", $0.nps))" }
                .joined(separator: " ")
            rows.append(Row(name: spec.name, difficulty: difficulty, mode: mode,
                            notes: output.chart.notes.count, nps: output.metrics.notesPerSecond,
                            quality: output.chart.qualityScore ?? 0,
                            rests: a.restFrequency, chords: a.chordFrequency, holds: a.holdFrequency,
                            minLaneShare: shares.min() ?? 0, repairs: a.repairCount,
                            variance: a.difficultyVariance, patterns: patternSummary,
                            sectionNPS: sectionSummary, valid: true))
        }
    }
    return rows
}

nonisolated func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

nonisolated func padded(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

nonisolated func printTable(_ rows: [Row]) {
    print("\(padded("profile", 20)) \(padded("level", 7)) \(padded("mode", 9)) \(padded("notes", 5)) \(padded("nps", 6)) \(padded("quality", 7)) \(padded("rests", 6)) \(padded("chords", 6)) \(padded("holds", 6)) \(padded("minlane", 7)) \(padded("repair", 6)) \(padded("var", 6)) sections")
    for r in rows {
        guard r.valid else {
            print("\(padded(r.name, 20)) \(padded(r.difficulty.rawValue, 7)) \(padded(r.mode, 9)) \(r.patterns)")
            continue
        }
        print("\(padded(r.name, 20)) \(padded(r.difficulty.rawValue, 7)) \(padded(r.mode, 9)) \(padded(String(r.notes), 5)) \(String(format: "%6.2f", r.nps)) \(String(format: "%7.2f", r.quality)) \(String(format: "%6.2f", r.rests)) \(String(format: "%6.2f", r.chords)) \(String(format: "%6.2f", r.holds)) \(String(format: "%7.2f", r.minLaneShare)) \(padded(String(r.repairs), 6)) \(String(format: "%6.2f", r.variance)) \(r.sectionNPS)")
        if r.difficulty == .hard {
            print("    patterns: \(r.patterns)")
        }
    }
}

nonisolated func summarize(_ rows: [Row]) {
    let valid = rows.filter { $0.valid }
    guard !valid.isEmpty else { print("No valid charts"); return }
    for mode in ["v3-legacy", "v4-patterns"] {
        let m = valid.filter { $0.mode == mode }
        let avgQ = m.map(\.quality).reduce(0, +) / Double(m.count)
        let avgRests = m.map(\.rests).reduce(0, +) / Double(m.count)
        let avgChords = m.map(\.chords).reduce(0, +) / Double(m.count)
        let avgHolds = m.map(\.holds).reduce(0, +) / Double(m.count)
        let avgMinLane = m.map(\.minLaneShare).reduce(0, +) / Double(m.count)
        let repairs = m.map(\.repairs).reduce(0, +)
        let invalid = rows.filter { $0.mode == mode && !$0.valid }.count
        print("\(padded(mode, 11)) \(m.count) charts | quality \(String(format: "%.2f", avgQ)) | rests \(String(format: "%.2f", avgRests)) | chords \(String(format: "%.2f", avgChords)) | holds \(String(format: "%.2f", avgHolds)) | min-lane \(String(format: "%.2f", avgMinLane)) | repairs \(repairs) | failed \(invalid)")
    }
}

let before = await generate(mode: "v3-legacy")
let after = await generate(mode: "v4-patterns")

print("HAPTIC PIANO — CHART QUALITY: v3 legacy per-cell vs v4 phrase/pattern selection")
print("(identical deterministic inputs; 7 profiles × 3 difficulties each)\n")
print("=== v3 legacy ===")
printTable(before)
print("\n=== v4 patterns ===")
printTable(after)
print("\n=== summary ===")
summarize(before + after)