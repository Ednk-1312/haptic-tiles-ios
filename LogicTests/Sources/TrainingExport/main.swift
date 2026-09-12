import Foundation
@testable import Music_Haptics

// Training-data export tool.
//
// Runs the REAL deterministic chart pipeline (synthesis → ChartGenerator →
// ChartDifficultyAnalyzer → feature extractors) over many seeded synthetic
// songs and writes labeled feature records as JSONL:
//
//   difficulty.jsonl   — 16 chart features → deterministic difficulty score
//   events.jsonl       — 16 event features → 1/0 (kept/skipped by the chart)
//   patterns.jsonl     — 16 pattern features → 1/0 (the deterministic plan)
//
// Usage:
//   swift run TrainingExport [outputDirectory] [songCount]
//
// Labels are ground truth from the app's own systems, so the trained models
// can never drift from what the app actually does. Deterministic: the same
// seed always produces the same dataset.

let defaultOut = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("../AI/Training/data")
    .standardizedFileURL
let outDir = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : defaultOut
let songCount = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 90) : 90

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
print("Generating training data: \(songCount) synthetic songs → \(outDir.path)")

let started = Date()
let records = await TrainingDataSynthesis.generateRecords(songCount: songCount) { done, total in
    if done % 10 == 0 || done == total {
        print("  \(done)/\(total) songs…")
    }
}

let encoder = JSONEncoder()
let difficultyLines = records.difficulty.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
let eventLines = records.events.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
let patternLines = records.patterns.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }

let difficultyURL = outDir.appendingPathComponent("difficulty.jsonl")
let eventsURL = outDir.appendingPathComponent("events.jsonl")
let patternsURL = outDir.appendingPathComponent("patterns.jsonl")
try difficultyLines.joined(separator: "\n").write(to: difficultyURL, atomically: true, encoding: .utf8)
try eventLines.joined(separator: "\n").write(to: eventsURL, atomically: true, encoding: .utf8)
try patternLines.joined(separator: "\n").write(to: patternsURL, atomically: true, encoding: .utf8)

let elapsed = Int(Date().timeIntervalSince(started))
print("Done in \(elapsed)s — \(difficultyLines.count) difficulty, \(eventLines.count) event, \(patternLines.count) pattern records.")