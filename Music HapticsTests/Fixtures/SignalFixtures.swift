import Foundation
@testable import Music_Haptics

/// Deterministic synthetic signals for unit tests (no audio files needed).
enum SignalFixtures {
    /// Metronome: decaying clicks at `bpm`, `seconds` long.
    static func metronome(bpm: Double, seconds: Double, sampleRate: Double = 44100) -> [Float] {
        let count = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: count)
        let beatInterval = 60.0 / bpm
        var t = 0.0
        while t < seconds {
            let start = Int(t * sampleRate)
            let len = min(Int(0.03 * sampleRate), count - start)
            if len > 0 {
                for i in 0..<len {
                    let phase = Double(i) / sampleRate
                    let envelope = exp(-phase * 120)
                    samples[start + i] += Float(sin(2 * .pi * 1000 * phase) * envelope)
                }
            }
            t += beatInterval
        }
        return samples
    }

    /// SICKO MODE-like dense rap fixture (accessible substitute for the
    /// DRM-protected Apple Music asset). Reproduces the song's characteristic
    /// analysis surface: ~155 BPM trap section with sixteenth-note hi-hat
    /// rolls, kick/clap accents, vocal-like mid-band bursts, then a mid-song
    /// beat switch to a slower half-time feel. Fully deterministic.
    static func sickoModeLike(seconds: Double = 92, sampleRate: Double = 44100) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(sampleRate * seconds))

        func addBurst(_ start: Double, duration: Double, freq: Double, amp: Float,
                      decay: Double, broadband: Bool = false) {
            let startIdx = Int(start * sampleRate)
            let count = min(Int(duration * sampleRate), max(0, samples.count - startIdx))
            guard count > 0 else { return }
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let env = Float(exp(-t * decay))
                let wave: Float
                if broadband {
                    // Deterministic "noise" from incommensurate primes (no RNG).
                    wave = Float(sin(2 * .pi * 997 * t) + sin(2 * .pi * 2141 * t) + sin(2 * .pi * 3673 * t)) / 3
                } else {
                    wave = Float(sin(2 * .pi * freq * t))
                }
                samples[startIdx + i] += wave * env * amp
            }
        }

        // Section A (0…60 s): 155 BPM trap — kick on 1+3, clap on 2+4,
        // sixteenth-note hi-hat rolls, vocal-like mid-band bursts.
        let intervalA = 60.0 / 155.0
        var t = 0.0
        var i = 0
        while t < 60 {
            let beat = i % 4
            if beat == 0 || beat == 2 {
                addBurst(t, duration: 0.14, freq: 55, amp: 0.9, decay: 22)
            } else {
                addBurst(t, duration: 0.09, freq: 0, amp: 0.7, decay: 45, broadband: true)
            }
            for h in 0..<4 {
                addBurst(t + Double(h) * intervalA / 4, duration: 0.028, freq: 8000, amp: 0.32, decay: 160)
            }
            t += intervalA
            i += 1
        }
        // Vocals: syllable-like 400 Hz bursts with AM, 8…50 s.
        var v = 8.0
        while v < 50 {
            addBurst(v, duration: 0.3, freq: 400, amp: 0.3, decay: 8)
            v += 0.62
        }

        // Section B (60…90 s): beat switch to 140 BPM half-time — kick on 1,
        // clap on 3, eighth-note hats, sparser vocals.
        let intervalB = 60.0 / 140.0
        t = 60
        i = 0
        while t < 90 {
            let beat = i % 4
            if beat == 0 {
                addBurst(t, duration: 0.14, freq: 55, amp: 0.8, decay: 22)
            } else if beat == 2 {
                addBurst(t, duration: 0.09, freq: 0, amp: 0.6, decay: 45, broadband: true)
            }
            for h in 0..<2 {
                addBurst(t + Double(h) * intervalB / 2, duration: 0.028, freq: 8000, amp: 0.25, decay: 160)
            }
            t += intervalB
            i += 1
        }
        v = 62.0
        while v < 88 {
            addBurst(v, duration: 0.3, freq: 400, amp: 0.24, decay: 8)
            v += 1.2
        }
        return samples
    }

    /// Flux-like onset envelope: impulses at the given times.
    static func impulseFlux(times: [Double], hopTime: Double, length: Int,
                            amplitude: Float = 1) -> [Float] {
        var flux = [Float](repeating: 0, count: length)
        for t in times {
            let idx = Int(t / hopTime)
            if idx >= 0 && idx < length { flux[idx] = amplitude }
        }
        return flux
    }

    /// A synthetic AudioAnalysis of a steady metronome at `bpm`.
    static func metronomeAnalysis(bpm: Double, seconds: Double) -> AudioAnalysis {
        let beatInterval = 60.0 / bpm
        var beats: [Beat] = []
        var events: [MusicalEvent] = []
        var t = 0.0
        var i = 0
        while t < seconds {
            let strong = i % 4 == 0
            beats.append(Beat(time: t, strength: strong ? 0.95 : 0.5, isStrong: strong))
            events.append(MusicalEvent(time: t,
                                       strength: strong ? 0.9 : 0.5,
                                       confidence: 0.8,
                                       type: .kickLike,
                                       lowEnergy: 0.7,
                                       midEnergy: 0.2,
                                       highEnergy: 0.1,
                                       isOnBeat: true,
                                       beatStrength: strong ? 0.95 : 0.5,
                                       sectionIndex: 0,
                                       importance: strong ? 0.9 : 0.5))
            t += beatInterval
            i += 1
        }
        return AudioAnalysis(duration: seconds,
                             sampleRate: 44100,
                             tempoBPM: bpm,
                             tempoConfidence: 0.9,
                             beats: beats,
                             onsets: [],
                             events: events,
                             sections: [SongSection(index: 0, start: 0, end: seconds, label: .generic, energy: 1.0)],
                             waveform: [],
                             averageEnergy: 0.5,
                             analysisDuration: 0.1,
                             hopTime: 512.0 / 44100.0)
    }

    // MARK: - Characteristic-type fixtures (for chart-quality tests)

    /// Beat grid helpers.
    static func quarterBeats(bpm: Double, seconds: Double, strongEvery: Int = 4,
                             strongStrength: Double = 1.0) -> [Beat] {
        let interval = 60.0 / bpm
        var beats: [Beat] = []
        var t = 0.0
        var i = 0
        while t < seconds {
            let strong = i % strongEvery == 0
            beats.append(Beat(time: t, strength: strong ? strongStrength : 0.6, isStrong: strong))
            t += interval
            i += 1
        }
        return beats
    }

    static func event(time: Double, strength: Double, importance: Double,
                      beatStrength: Double = 0, isOnBeat: Bool = false,
                      type: MusicalEventType = .percussive) -> MusicalEvent {
        MusicalEvent(time: time,
                     strength: strength,
                     confidence: 0.8,
                     type: type,
                     lowEnergy: 0.4,
                     midEnergy: 0.4,
                     highEnergy: 0.2,
                     isOnBeat: isOnBeat,
                     beatStrength: beatStrength,
                     sectionIndex: 0,
                     importance: importance)
    }

    static func makeAnalysis(duration: Double, bpm: Double, beats: [Beat],
                             events: [MusicalEvent],
                             sections: [SongSection]) -> AudioAnalysis {
        AudioAnalysis(duration: duration,
                      sampleRate: 44100,
                      tempoBPM: bpm,
                      tempoConfidence: 0.9,
                      beats: beats,
                      onsets: [],
                      events: events,
                      sections: sections,
                      waveform: [],
                      averageEnergy: 0.5,
                      analysisDuration: 0.01,
                      hopTime: 512.0 / 44100.0)
    }

    /// Drum-heavy: eighth-note kick/percussion onsets on top of a strong beat
    /// grid — plenty of onsets that a good chart must *not* all transcribe.
    static func drumHeavy(bpm: Double = 120, seconds: Double = 30) -> AudioAnalysis {
        let interval = 60.0 / bpm
        let beats = quarterBeats(bpm: bpm, seconds: seconds)
        var events: [MusicalEvent] = []
        var t = 0.0
        var i = 0
        while t < seconds {
            let onBeat = i % 2 == 0
            let isDownbeat = i % 4 == 0
            events.append(event(time: t,
                                strength: onBeat ? (isDownbeat ? 0.95 : 0.7) : 0.5,
                                importance: onBeat ? (isDownbeat ? 0.95 : 0.6) : 0.4,
                                beatStrength: onBeat ? 0.8 : 0,
                                isOnBeat: onBeat,
                                type: isDownbeat ? .kickLike : .percussive))
            t += interval / 2
            i += 1
        }
        return makeAnalysis(duration: seconds, bpm: bpm, beats: beats, events: events,
                            sections: [SongSection(index: 0, start: 0, end: seconds, label: .generic, energy: 1.0)])
    }

    /// Very fast, very dense percussion (200+ BPM with sixteenths) — the chart
    /// must stay playable and far below the onset count.
    static func fastDrumHeavy(bpm: Double = 220, seconds: Double = 24) -> AudioAnalysis {
        let interval = 60.0 / bpm
        let beats = quarterBeats(bpm: bpm, seconds: seconds)
        var events: [MusicalEvent] = []
        var t = 0.0
        var i = 0
        while t < seconds {
            let onBeat = i % 4 == 0
            events.append(event(time: t, strength: onBeat ? 0.8 : 0.55,
                                importance: onBeat ? 0.7 : 0.4,
                                beatStrength: onBeat ? 0.7 : 0,
                                isOnBeat: onBeat))
            t += interval / 4
            i += 1
        }
        return makeAnalysis(duration: seconds, bpm: bpm, beats: beats, events: events,
                            sections: [SongSection(index: 0, start: 0, end: seconds, label: .generic, energy: 1.0)])
    }

    /// Sparse, vocal-like: strong downbeat accents with long gaps — the chart
    /// must preserve the accents and fill rhythmically, not dump tiny onsets.
    static func sparseVocal(bpm: Double = 90, seconds: Double = 32) -> AudioAnalysis {
        let interval = 60.0 / bpm
        let beats = quarterBeats(bpm: bpm, seconds: seconds)
        var events: [MusicalEvent] = []
        var t = 0.0
        var i = 0
        while t < seconds {
            if i % 2 == 0 {
                // Strong accents every half-bar.
                events.append(event(time: t, strength: 0.85, importance: 0.9,
                                    beatStrength: 0.9, isOnBeat: true, type: .melodic))
            } else {
                // Weak breathy onsets deliberately OFF the subdivision grid
                // (beat + 80 ms) — the chart should skip most of these.
                events.append(event(time: t + 0.08, strength: 0.15, importance: 0.12))
            }
            t += interval
            i += 1
        }
        return makeAnalysis(duration: seconds, bpm: bpm, beats: beats, events: events,
                            sections: [SongSection(index: 0, start: 0, end: seconds, label: .generic, energy: 0.85)])
    }

    /// One quiet intro section then an energetic chorus — density must follow.
    static func quietLoud(seconds: Double = 64, bpm: Double = 120) -> AudioAnalysis {
        let interval = 60.0 / bpm
        let beats = quarterBeats(bpm: bpm, seconds: seconds)
        var events: [MusicalEvent] = []

        // Quiet intro: sparse weak taps.
        var t = 0.0
        var i = 0
        while t < 16 {
            if i % 4 == 0 {
                events.append(event(time: t, strength: 0.2, importance: 0.3, type: .melodic))
            }
            t += interval
            i += 1
        }
        // Loud chorus: busy eighth-note groove.
        t = 16
        i = 0
        while t < seconds {
            let onBeat = i % 2 == 0
            let down = i % 4 == 0
            events.append(event(time: t,
                                strength: onBeat ? (down ? 0.95 : 0.7) : 0.5,
                                importance: onBeat ? (down ? 0.95 : 0.65) : 0.45,
                                beatStrength: onBeat ? 0.8 : 0,
                                isOnBeat: onBeat,
                                type: down ? .kickLike : .percussive))
            t += interval / 2
            i += 1
        }
        let sections = [
            SongSection(index: 0, start: 0, end: 16, label: .intro, energy: 0.12),
            SongSection(index: 1, start: 16, end: seconds, label: .chorus, energy: 1.0)
        ]
        return makeAnalysis(duration: seconds, bpm: bpm, beats: beats, events: events, sections: sections)
    }
}