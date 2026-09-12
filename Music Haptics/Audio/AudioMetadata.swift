import AVFoundation
import Foundation

/// Title / artist / artwork / duration extracted from an imported file.
struct AudioMetadata: Sendable {
    var title: String?
    var artist: String?
    var artworkData: Data?
    var duration: Double
}

/// Loads metadata with AVFoundation. Runs off the main thread.
enum AudioMetadataLoader {
    static func load(from url: URL) async -> AudioMetadata {
        let asset = AVURLAsset(url: url)
        var title: String?
        var artist: String?
        var artwork: Data?
        var duration = 0.0
        do {
            let loaded = try await asset.load(.duration, .commonMetadata)
            duration = loaded.0.seconds
            for item in loaded.1 {
                switch item.commonKey {
                case .commonKeyTitle:
                    title = (try? await item.load(.stringValue)) ?? title
                case .commonKeyArtist:
                    artist = (try? await item.load(.stringValue)) ?? artist
                case .commonKeyArtwork:
                    artwork = (try? await item.load(.dataValue)) ?? artwork
                default:
                    break
                }
            }
        } catch {
            // Metadata is best-effort; the UI falls back to the file name.
        }
        if duration.isNaN { duration = 0 }
        return AudioMetadata(title: title, artist: artist, artworkData: artwork, duration: duration)
    }
}