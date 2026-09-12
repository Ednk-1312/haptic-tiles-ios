import Foundation

/// Everything the analysis pipeline learned about one song.
/// Stored as JSON next to the chart, so re-launching the app never re-analyzes.
struct AudioAnalysis: Codable, Sendable {
    var duration: Double
    var sampleRate: Double
    var tempoBPM: Double?
    var tempoConfidence: Double?
    var beats: [Beat]
    var onsets: [OnsetEvent]
    var events: [MusicalEvent]
    var sections: [SongSection]
    var waveform: [Float]         // downsampled RMS envelope (0…1), ~512 points
    var averageEnergy: Double
    var analysisDuration: Double  // wall time of analysis, for diagnostics
    var hopTime: Double           // analysis hop size, for diagnostics
}