import Accelerate
import AVFoundation
import CoreMedia
import Foundation

/// Granular analysis failures. User-facing text stays simple; `debugDetail`
/// carries the exact underlying NSError domain/code so a failing song can be
/// diagnosed instead of collapsing into one generic "DRM or format" message.
enum AnalysisError: LocalizedError {
    case invalidURL
    case protectedAsset
    case assetLoadFailed(detail: String)
    case noAudioTrack
    case readerCreationFailed(detail: String)
    case sampleReadFailed(detail: String)
    case emptyAudio
    case tooShort
    case noOnsets
    case noFluxData
    case analysisMissing

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "This song's audio URL is invalid."
        case .protectedAsset:
            return "This song is DRM-protected, so Haptic Piano can't access its audio."
        case .assetLoadFailed:
            return "The song's audio couldn't be opened for analysis."
        case .noAudioTrack:
            return "No audio track was found in this file."
        case .readerCreationFailed:
            return "The audio decoder couldn't be created for this file."
        case .sampleReadFailed:
            return "The audio stopped decoding before the end of the file."
        case .emptyAudio:
            return "This file contains no audio."
        case .tooShort:
            return "This file is too short to analyze (need at least 3 seconds)."
        case .noOnsets:
            return "No musical events were detected in this file."
        case .noFluxData:
            return "Not enough audio data could be decoded from this file."
        case .analysisMissing:
            return "No analysis data was found for this song."
        }
    }

    /// Technical detail for developer diagnostics (NSError domain/code, reader
    /// status, …). nil when the case needs no further explanation.
    var debugDetail: String? {
        switch self {
        case .assetLoadFailed(let detail),
             .readerCreationFailed(let detail),
             .sampleReadFailed(let detail):
            return detail
        default:
            return nil
        }
    }
}

/// Streaming, on-device analysis pipeline.
///
/// The file is decoded chunk by chunk; only compact feature arrays (flux, RMS,
/// band energy) are kept — never the full waveform. The method is `async` and
/// `nonisolated`, so its heavy work runs off the main thread when awaited.
final class AudioAnalyzer {
    private let fftSize = 2048
    private let hopSize = 512

    func analyze(url: URL) async throws -> AudioAnalysis {
        let started = Date()
        guard url.scheme != nil else { throw AnalysisError.invalidURL }
        // Only sandbox `file://` URLs need an existence check. Music-library
        // items resolve to `ipod-library://` URLs whose `.path` is a synthetic
        // identifier, not a real file on disk — AVFoundation validates those
        // itself. Checking `fileExists` on them would reject every library song.
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            throw AnalysisError.invalidURL
        }

        // Decode via AVAssetReader: streams every container/codec AVFoundation
        // supports (MP3, AAC/M4A, WAV, AIFF, ipod-library items, …) and converts
        // each chunk to the requested format, so we never hold the whole song
        // in memory.
        let asset = AVURLAsset(url: url)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AnalysisError.readerCreationFailed(detail: Self.describe(error))
        }
        let tracks: [AVAssetTrack]
        do {
            // AVFoundation's load() does not reliably honour task cancellation
            // (asset inspection can take many seconds for a fresh file on the
            // simulator), so check explicitly before and after the await.
            try Task.checkCancellation()
            tracks = try await asset.loadTracks(withMediaType: .audio)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AnalysisError.assetLoadFailed(detail: Self.describe(error))
        }
        guard let audioTrack = tracks.first else { throw AnalysisError.noAudioTrack }

        let descriptions: [CMFormatDescription]
        do {
            try Task.checkCancellation()
            descriptions = try await audioTrack.load(.formatDescriptions)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AnalysisError.assetLoadFailed(detail: Self.describe(error))
        }
        guard let formatDescription = descriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw AnalysisError.assetLoadFailed(detail: "No usable audio format description")
        }
        let sampleRate = asbd.pointee.mSampleRate
        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        guard sampleRate > 0, channelCount > 0 else {
            throw AnalysisError.assetLoadFailed(detail: "Invalid audio format: sampleRate=\(sampleRate), channels=\(channelCount)")
        }

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: channelCount
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw AnalysisError.readerCreationFailed(detail: "startReading returned false; status=\(Self.statusName(reader.status)); error=\(reader.error.map(Self.describe) ?? "none")")
        }

        guard let spectral = SpectralAnalyzer(fftSize: fftSize) else {
            throw AnalysisError.assetLoadFailed(detail: "FFT setup failed")
        }

        var flux: [Float] = []
        var rms: [Float] = []
        var bands: [(low: Float, mid: Float, high: Float)] = []
        var previousMag: [Float] = []
        var pending: [Float] = []
        /// Hop frames consumed from the front of `pending` since the last
        /// compaction (see the hop loop below).
        var consumedOffset = 0
        var totalFrames: Int64 = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            // Cooperative cancellation: a superseded/re-analysed song must
            // STOP decoding promptly (the generation gate prevents the result
            // from landing, but the CPU work should unwind too). Chunks are
            // ~50 ms, so cancellation latency is bounded by one chunk.
            do {
                try Task.checkCancellation()
            } catch {
                reader.cancelReading()
                throw error
            }
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &dataPointer)
            guard let dataPointer, length > 0 else { continue }

            // Interleaved Float32 PCM: mix all channels down to mono.
            let frameCount = length / (channelCount * MemoryLayout<Float>.size)
            let samples = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            pending.reserveCapacity(pending.count + frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += samples[frame * channelCount + channel]
                }
                pending.append(sum / Float(channelCount))
            }
            totalFrames += Int64(frameCount)

            // Process complete FFT hops, keeping the overlap in `pending`.
            // Consumption is tracked by OFFSET (no per-hop removeFirst — the
            // old code memmoved the whole pending array every hop); the prefix
            // is dropped once per chunk instead. The FFT window is read
            // straight from `pending` via an unsafe buffer, so no frame array
            // is allocated per hop either (~46k hops on a 10-minute song).
            //
            // AVAssetReader may deliver the ENTIRE file as one giant buffer,
            // so the per-chunk cancellation check above is not enough on its
            // own — a 10-minute song would run all its hops before noticing
            // a cancel. Check every 64 hops (~0.7 s of audio) as well.
            var hopCounter = 0
            while pending.count - consumedOffset >= fftSize {
                if hopCounter % 64 == 0 {
                    do {
                        try Task.checkCancellation()
                    } catch {
                        reader.cancelReading()
                        throw error
                    }
                }
                hopCounter += 1
                pending.withUnsafeBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    let windowPtr = UnsafeBufferPointer(start: base + consumedOffset, count: fftSize)
                    let mags = spectral.magnitudeSpectrum(of: windowPtr)

                    // Spectral flux: sum of positive magnitude deltas (onset energy).
                    var f: Float = 0
                    if previousMag.count == mags.count {
                        for k in 0..<mags.count where mags[k] > previousMag[k] {
                            f += mags[k] - previousMag[k]
                        }
                    }
                    previousMag = mags
                    flux.append(f)

                    // RMS energy of the hop window.
                    var meanSquare: Float = 0
                    vDSP_measqv(windowPtr.baseAddress!, 1, &meanSquare, vDSP_Length(fftSize))
                    rms.append(sqrt(meanSquare))

                    // Band energies for approximate event classification.
                    let low = spectral.bandEnergy(mags, lowHz: 40, highHz: 220, sampleRate: sampleRate)
                    let mid = spectral.bandEnergy(mags, lowHz: 220, highHz: 2200, sampleRate: sampleRate)
                    let high = spectral.bandEnergy(mags, lowHz: 2200, highHz: 10000, sampleRate: sampleRate)
                    bands.append((low, mid, high))
                }
                consumedOffset += hopSize
            }
            if consumedOffset >= fftSize {
                pending.removeFirst(consumedOffset)
                consumedOffset = 0
            }
        }
        guard reader.status == .completed else {
            if Task.isCancelled { throw CancellationError() }
            // Decoding stopped before the end (corrupt/truncated file, or a
            // protected asset the reader could not fully decode).
            throw AnalysisError.sampleReadFailed(detail: "status=\(Self.statusName(reader.status)); error=\(reader.error.map(Self.describe) ?? "none")")
        }

        let duration = Double(totalFrames) / sampleRate
        guard totalFrames > 0 else { throw AnalysisError.emptyAudio }
        guard duration >= 3 else { throw AnalysisError.tooShort }
        // Duration-relative flux guard: a raw hop count of 64 means 0.74 s at
        // 44.1 kHz but 4.1 s at 8 kHz — a legitimate 3–4 s low-rate file must
        // not be rejected as "no flux data".
        guard Double(flux.count) * (Double(hopSize) / sampleRate) >= 0.5 else { throw AnalysisError.noFluxData }

        let hopTime = Double(hopSize) / sampleRate

        // Every post-decode stage is synchronous and CPU-heavy (the tempo ACF
        // alone takes seconds in Debug). Cancellation must unwind BETWEEN
        // stages, not only during decoding — a cancelled analysis must never
        // run these to completion.
        try Task.checkCancellation()
        let tempo = TempoEstimator.estimate(flux: flux, hopTime: hopTime)
        try Task.checkCancellation()
        let track = BeatTracker.track(flux: flux, hopTime: hopTime, bpm: tempo.bpm, confidence: tempo.confidence)
        try Task.checkCancellation()
        let onsets = OnsetDetector.detect(flux: flux, hopTime: hopTime)
        try Task.checkCancellation()
        let sections = SectionDetector.detect(rms: rms, hopTime: hopTime, duration: duration)
        try Task.checkCancellation()

        // A rejected/failed analysis stage must not make the song unusable:
        // when onset detection finds nothing, derive deterministic fallback
        // events from the detected beats, then from a quarter-note grid at
        // the detected tempo. Only when NO musical structure exists (no
        // tempo, no beats, no onsets) is the song honestly reported as
        // having no musical events.
        let events: [MusicalEvent]
        if onsets.isEmpty {
            events = Self.finalize(Self.fallbackEvents(beats: track.beats, tempoBPM: tempo.bpm,
                                                       bands: bands, hopTime: hopTime,
                                                       sections: sections, duration: duration))
            guard !events.isEmpty else { throw AnalysisError.noOnsets }
        } else {
            // Unified musical events: onsets + beat context + approximate types.
            events = Self.finalize(buildEvents(onsets: onsets, bands: bands, hopTime: hopTime,
                                               beats: track.beats, sections: sections))
        }

        try Task.checkCancellation()
        let waveform = downsample(rms, to: 512)
        let avgEnergy = rms.isEmpty ? 0 : Double(rms.reduce(0, +)) / Double(rms.count)
        try Task.checkCancellation()

        return AudioAnalysis(duration: duration,
                             sampleRate: sampleRate,
                             tempoBPM: tempo.bpm > 0 ? tempo.bpm : nil,
                             tempoConfidence: tempo.confidence,
                             beats: track.beats,
                             onsets: onsets,
                             events: events,
                             sections: sections,
                             waveform: waveform,
                             averageEnergy: avgEnergy,
                             analysisDuration: Date().timeIntervalSince(started),
                             hopTime: hopTime)
    }

    // MARK: - Error helpers

    /// "Domain (code) description" — the exact reason for developer diagnostics.
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) (\(ns.code)) \(ns.localizedDescription)"
    }

    private static func statusName(_ status: AVAssetReader.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .reading: return "reading"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    // MARK: - Event building

    private func buildEvents(onsets: [OnsetEvent], bands: [(low: Float, mid: Float, high: Float)],
                             hopTime: Double, beats: [Beat], sections: [SongSection]) -> [MusicalEvent] {
        var raw: [MusicalEvent] = []

        // Nearest-beat lookup via two pointers (both lists are time-sorted).
        var beatIdx = 0
        for onset in onsets {
            while beatIdx < beats.count - 1 && beats[beatIdx + 1].time < onset.time { beatIdx += 1 }

            var beatStrength = 0.0
            var isOnBeat = false
            if !beats.isEmpty {
                let near = beats[beatIdx]
                if abs(near.time - onset.time) < 0.12 {
                    isOnBeat = true
                    beatStrength = near.strength
                } else if beatIdx + 1 < beats.count, abs(beats[beatIdx + 1].time - onset.time) < 0.12 {
                    isOnBeat = true
                    beatStrength = beats[beatIdx + 1].strength
                }
            }

            let hop = min(bands.count - 1, max(0, Int(onset.time / hopTime)))
            let band = bands[hop]
            let totalBand = band.low + band.mid + band.high
            let lowR = totalBand > 0 ? Double(band.low) / Double(totalBand) : 0
            let midR = totalBand > 0 ? Double(band.mid) / Double(totalBand) : 0
            let highR = totalBand > 0 ? Double(band.high) / Double(totalBand) : 0

            // Approximate classification from spectral shape (honest heuristics).
            let type: MusicalEventType
            if lowR > 0.55 {
                type = .kickLike
            } else if highR > 0.35 && midR > 0.3 {
                type = .snareLike
            } else if midR > 0.5 {
                type = .melodic
            } else {
                type = .percussive
            }

            let sectionIndex = sections.firstIndex { onset.time >= $0.start && onset.time < $0.end } ?? 0
            let sectionEnergy = sections.indices.contains(sectionIndex) ? sections[sectionIndex].energy : 0.5

            // Importance: what should chart generation pick first?
            let importance = Double(onset.strength) * 0.45
                + Double(onset.confidence) * 0.15
                + beatStrength * 0.30
                + sectionEnergy * 0.10

            raw.append(MusicalEvent(time: onset.time,
                                    strength: Double(onset.strength),
                                    confidence: Double(onset.confidence),
                                    type: type,
                                    lowEnergy: lowR,
                                    midEnergy: midR,
                                    highEnergy: highR,
                                    isOnBeat: isOnBeat,
                                    beatStrength: beatStrength,
                                    sectionIndex: sectionIndex,
                                    importance: importance))
        }

        // Normalize importance to 0…1 and merge events closer than 30 ms.
        let maxImportance = raw.map(\.importance).max() ?? 1
        var events: [MusicalEvent] = []
        for var event in raw {
            event.importance = event.importance / maxImportance
            if let last = events.last, event.time - last.time < 0.03 {
                if event.importance > last.importance { events[events.count - 1] = event }
                continue
            }
            events.append(event)
        }
        return events
    }

    /// Deterministic fallback musical events when onset detection found
    /// nothing (quiet/sparse material): one event per detected beat (strong
    /// beats become accents), or — without beats — a quarter-note grid at the
    /// detected tempo. Pure derivation from detected structure: identical
    /// inputs → identical events, so charts stay reproducible.
    static func fallbackEvents(beats: [Beat], tempoBPM: Double,
                               bands: [(low: Float, mid: Float, high: Float)],
                               hopTime: Double, sections: [SongSection],
                               duration: Double) -> [MusicalEvent] {
        var raw: [MusicalEvent] = []
        if !beats.isEmpty {
            for beat in beats {
                raw.append(beatEvent(beat: beat, bands: bands, hopTime: hopTime, sections: sections))
            }
        } else if tempoBPM > 0, (20...300).contains(tempoBPM) {
            let interval = 60.0 / tempoBPM
            var t = 0.0
            var i = 0
            while t < duration {
                let strong = i % 4 == 0
                raw.append(beatEvent(beat: Beat(time: t, strength: strong ? 0.8 : 0.5, isStrong: strong),
                                     bands: bands, hopTime: hopTime, sections: sections))
                t += interval
                i += 1
            }
        }
        guard !raw.isEmpty else { return [] }
        let maxImportance = raw.map(\.importance).max() ?? 1
        return raw.map { var e = $0; e.importance /= maxImportance; return e }
    }

    /// One event derived from a single beat (grid or detected).
    private static func beatEvent(beat: Beat,
                                  bands: [(low: Float, mid: Float, high: Float)],
                                  hopTime: Double, sections: [SongSection]) -> MusicalEvent {
        let hop = bands.isEmpty ? 0 : min(bands.count - 1, max(0, Int(beat.time / hopTime)))
        let band = bands.isEmpty ? (low: Float(1) / 3, mid: Float(1) / 3, high: Float(1) / 3) : bands[hop]
        let total = band.low + band.mid + band.high
        let lowR = total > 0 ? Double(band.low) / Double(total) : 1.0 / 3.0
        let midR = total > 0 ? Double(band.mid) / Double(total) : 1.0 / 3.0
        let highR = total > 0 ? Double(band.high) / Double(total) : 1.0 / 3.0
        let sectionIndex = sections.firstIndex { beat.time >= $0.start && beat.time < $0.end } ?? 0
        return MusicalEvent(time: beat.time,
                            strength: beat.strength,
                            confidence: 0.6,
                            type: beat.isStrong ? .accent : .beat,
                            lowEnergy: lowR,
                            midEnergy: midR,
                            highEnergy: highR,
                            isOnBeat: true,
                            beatStrength: beat.strength,
                            sectionIndex: sectionIndex,
                            importance: 0.35 + 0.65 * beat.strength)
    }

    /// Shared event finalization: keep the most important candidates, sorted
    /// deterministically by time. (Importance normalization and 30 ms merging
    /// happen inside `buildEvents` for onset-derived events; the fallback
    /// grid's minimum spacing is far above the merge window.)
    private static func finalize(_ events: [MusicalEvent]) -> [MusicalEvent] {
        var sorted = events.sorted { $0.importance > $1.importance }
        if sorted.count > 4000 { sorted = Array(sorted.prefix(4000)) }
        return sorted.sorted { $0.time < $1.time }
    }

    private func downsample(_ values: [Float], to count: Int) -> [Float] {
        guard values.count > count, count > 0 else { return values }
        let stride = Double(values.count) / Double(count)
        var out: [Float] = []
        out.reserveCapacity(count)
        var pos = 0.0
        while out.count < count && Int(pos) < values.count {
            out.append(values[Int(pos)])
            pos += stride
        }
        return out
    }
}