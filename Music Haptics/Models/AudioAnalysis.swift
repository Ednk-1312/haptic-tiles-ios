import Foundation

/// Everything the analysis pipeline learned about one song.
/// Stored as JSON next to the chart, so re-launching the app never re-analyzes.
struct AudioAnalysis: Codable, Sendable {
    var duration: Double
    var sampleRate: Double
    var tempoBPM: Double?
    var tempoConfidence: Double?
    /// Which pre-game tempo path produced the stable BPM.
    var tempoAnalyzer: TempoAnalyzerKind = .dsp
    /// Stability and ambiguity diagnostics from the tempo stage.
    var tempoStability: Double = 0
    var tempoHalfDoubleAmbiguity: Double = 0
    var tempoChangeDetected: Bool = false
    var tempoAnalysisVersion: Int = TempoAnalysisResult.analyzerVersion
    var tempoAnalysisCacheHit: Bool = false
    var tempoInferenceDuration: Double? = nil
    var tempoFallbackReason: String? = nil
    var beats: [Beat]
    var onsets: [OnsetEvent]
    var events: [MusicalEvent]
    var sections: [SongSection]
    var waveform: [Float]         // downsampled RMS envelope (0…1), ~512 points
    var averageEnergy: Double
    var analysisDuration: Double  // wall time of analysis, for diagnostics
    var hopTime: Double           // analysis hop size, for diagnostics

    private enum CodingKeys: String, CodingKey {
        case duration, sampleRate, tempoBPM, tempoConfidence
        case tempoAnalyzer, tempoStability, tempoHalfDoubleAmbiguity
        case tempoChangeDetected, tempoAnalysisVersion, tempoAnalysisCacheHit
        case tempoInferenceDuration, tempoFallbackReason
        case beats, onsets, events, sections, waveform, averageEnergy
        case analysisDuration, hopTime
    }

    init(duration: Double,
         sampleRate: Double,
         tempoBPM: Double?,
         tempoConfidence: Double?,
         tempoAnalyzer: TempoAnalyzerKind = .dsp,
         tempoStability: Double = 0,
         tempoHalfDoubleAmbiguity: Double = 0,
         tempoChangeDetected: Bool = false,
         tempoAnalysisVersion: Int = TempoAnalysisResult.analyzerVersion,
         tempoAnalysisCacheHit: Bool = false,
         tempoInferenceDuration: Double? = nil,
         tempoFallbackReason: String? = nil,
         beats: [Beat],
         onsets: [OnsetEvent],
         events: [MusicalEvent],
         sections: [SongSection],
         waveform: [Float],
         averageEnergy: Double,
         analysisDuration: Double,
         hopTime: Double) {
        self.duration = duration
        self.sampleRate = sampleRate
        self.tempoBPM = tempoBPM
        self.tempoConfidence = tempoConfidence
        self.tempoAnalyzer = tempoAnalyzer
        self.tempoStability = tempoStability
        self.tempoHalfDoubleAmbiguity = tempoHalfDoubleAmbiguity
        self.tempoChangeDetected = tempoChangeDetected
        self.tempoAnalysisVersion = tempoAnalysisVersion
        self.tempoAnalysisCacheHit = tempoAnalysisCacheHit
        self.tempoInferenceDuration = tempoInferenceDuration
        self.tempoFallbackReason = tempoFallbackReason
        self.beats = beats
        self.onsets = onsets
        self.events = events
        self.sections = sections
        self.waveform = waveform
        self.averageEnergy = averageEnergy
        self.analysisDuration = analysisDuration
        self.hopTime = hopTime
    }

    /// Backward-compatible decoding is important because old analysis files
    /// remain valid DSP/chart inputs after the tempo metadata is expanded.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        duration = try values.decode(Double.self, forKey: .duration)
        sampleRate = try values.decode(Double.self, forKey: .sampleRate)
        tempoBPM = try values.decodeIfPresent(Double.self, forKey: .tempoBPM)
        tempoConfidence = try values.decodeIfPresent(Double.self, forKey: .tempoConfidence)
        tempoAnalyzer = try values.decodeIfPresent(TempoAnalyzerKind.self, forKey: .tempoAnalyzer) ?? .dsp
        tempoStability = try values.decodeIfPresent(Double.self, forKey: .tempoStability) ?? 0
        tempoHalfDoubleAmbiguity = try values.decodeIfPresent(Double.self, forKey: .tempoHalfDoubleAmbiguity) ?? 0
        tempoChangeDetected = try values.decodeIfPresent(Bool.self, forKey: .tempoChangeDetected) ?? false
        tempoAnalysisVersion = try values.decodeIfPresent(Int.self, forKey: .tempoAnalysisVersion)
            ?? TempoAnalysisResult.analyzerVersion
        tempoAnalysisCacheHit = try values.decodeIfPresent(Bool.self, forKey: .tempoAnalysisCacheHit) ?? false
        tempoInferenceDuration = try values.decodeIfPresent(Double.self, forKey: .tempoInferenceDuration)
        tempoFallbackReason = try values.decodeIfPresent(String.self, forKey: .tempoFallbackReason)
        beats = try values.decode([Beat].self, forKey: .beats)
        onsets = try values.decode([OnsetEvent].self, forKey: .onsets)
        events = try values.decode([MusicalEvent].self, forKey: .events)
        sections = try values.decode([SongSection].self, forKey: .sections)
        waveform = try values.decode([Float].self, forKey: .waveform)
        averageEnergy = try values.decode(Double.self, forKey: .averageEnergy)
        analysisDuration = try values.decode(Double.self, forKey: .analysisDuration)
        hopTime = try values.decode(Double.self, forKey: .hopTime)
    }
}