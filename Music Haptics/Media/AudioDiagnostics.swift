import AVFoundation
import CoreMedia
import Foundation
import MediaPlayer
import UIKit

/// One row of an audio-diagnostics report.
struct ProbeRow: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let value: String
}

/// Full diagnostic report for a real library item / asset: every step of the
/// MPMediaItem → AVAsset → AVAssetReader → AVAudioPlayer path, so a failure
/// appears at its exact stage with the underlying NSError domain/code.
struct AudioProbeReport: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let rows: [ProbeRow]

    var summary: String {
        rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }
}

/// Developer diagnostics for the My Music audio path (iOS only — uses
/// MPMediaItem, so it is NOT part of the macOS logic-test package).
enum AudioProbe {
    /// Probe a library item by persistent ID; nil if it's no longer in the library.
    static func report(persistentID: UInt64) async -> AudioProbeReport? {
        guard let item = MPMediaLibraryProvider.item(persistentID: persistentID) else { return nil }
        return await report(item: item)
    }

    static func report(item: MPMediaItem) async -> AudioProbeReport {
        var rows = itemRows(for: item)
        if let url = item.assetURL {
            rows.append(contentsOf: await assetRows(url: url))
            rows.append(contentsOf: await playbackRows(url: url))
        }
        return publish(AudioProbeReport(title: item.title ?? "Unknown Title", rows: rows))
    }

    static func report(url: URL) async -> AudioProbeReport {
        var rows = [ProbeRow(label: "URL", value: url.absoluteString)]
        rows.append(contentsOf: await assetRows(url: url))
        rows.append(contentsOf: await playbackRows(url: url))
        return publish(AudioProbeReport(title: url.lastPathComponent, rows: rows))
    }

    private static func publish(_ report: AudioProbeReport) -> AudioProbeReport {
        print("=== Audio Probe: \(report.title) ===")
        print(report.summary)
        return report
    }

    // MARK: - MPMediaItem facts

    private static func itemRows(for item: MPMediaItem) -> [ProbeRow] {
        var rows: [ProbeRow] = []
        rows.append(ProbeRow(label: "Title", value: item.title ?? "—"))
        rows.append(ProbeRow(label: "Persistent ID", value: String(item.persistentID)))
        rows.append(ProbeRow(label: "hasProtectedAsset", value: item.hasProtectedAsset ? "true" : "false"))
        rows.append(ProbeRow(label: "isCloudItem", value: item.isCloudItem ? "true" : "false"))
        if let url = item.assetURL {
            rows.append(ProbeRow(label: "assetURL", value: url.absoluteString))
            rows.append(ProbeRow(label: "URL scheme", value: url.scheme ?? "nil"))
            rows.append(ProbeRow(label: "URL path", value: url.path))
            rows.append(ProbeRow(label: "isFileURL", value: url.isFileURL ? "true" : "false"))
            if url.isFileURL {
                rows.append(ProbeRow(label: "fileExists",
                                     value: FileManager.default.fileExists(atPath: url.path) ? "true" : "false"))
            }
        } else {
            rows.append(ProbeRow(label: "assetURL", value: "nil"))
        }
        return rows
    }

    // MARK: - AVAsset / AVAssetReader

    private static func assetRows(url: URL) async -> [ProbeRow] {
        var rows: [ProbeRow] = []
        let asset = AVURLAsset(url: url)

        do {
            let duration = try await asset.load(.duration)
            rows.append(ProbeRow(label: "AVAsset duration", value: String(format: "%.3fs", duration.seconds)))
        } catch {
            rows.append(ProbeRow(label: "AVAsset duration", value: "load failed → \(describe(error))"))
        }

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            rows.append(ProbeRow(label: "Audio tracks", value: "\(tracks.count)"))
        } catch {
            rows.append(ProbeRow(label: "Audio tracks", value: "load failed → \(describe(error))"))
            return rows
        }
        guard let audioTrack = tracks.first else { return rows }

        do {
            let descriptions = try await audioTrack.load(.formatDescriptions)
            rows.append(ProbeRow(label: "Format descriptions", value: "\(descriptions.count)"))
        } catch {
            rows.append(ProbeRow(label: "Format descriptions", value: "load failed → \(describe(error))"))
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
            rows.append(ProbeRow(label: "AVAssetReader", value: "created"))
        } catch {
            rows.append(ProbeRow(label: "AVAssetReader", value: "creation failed → \(describe(error))"))
            return rows
        }

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        if reader.startReading() {
            rows.append(ProbeRow(label: "startReading", value: "true"))
        } else {
            rows.append(ProbeRow(label: "startReading", value: "false → status \(statusName(reader.status)); error \(reader.error.map(describe) ?? "none")"))
            return rows
        }

        var buffersRead = 0
        while let buffer = output.copyNextSampleBuffer(), buffersRead < 2 {
            buffersRead += 1
            let count = CMSampleBufferGetNumSamples(buffer)
            rows.append(ProbeRow(label: "Sample buffer \(buffersRead)", value: "read (\(count) samples)"))
        }
        if buffersRead == 0 {
            rows.append(ProbeRow(label: "Sample buffers", value: "none read → status \(statusName(reader.status)); error \(reader.error.map(describe) ?? "none")"))
        } else {
            rows.append(ProbeRow(label: "Reader status", value: statusName(reader.status)))
        }
        return rows
    }

    // MARK: - Gameplay playback path (AVAudioPlayer)

    private static func playbackRows(url: URL) async -> [ProbeRow] {
        var rows: [ProbeRow] = []
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            rows.append(ProbeRow(label: "AVAudioPlayer load", value: "success (\(String(format: "%.3fs", player.duration)))"))
            rows.append(ProbeRow(label: "AVAudioPlayer prepareToPlay", value: player.prepareToPlay() ? "true" : "false"))
        } catch {
            rows.append(ProbeRow(label: "AVAudioPlayer load", value: "failed → \(describe(error))"))
        }
        return rows
    }

    // MARK: - Helpers

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
}