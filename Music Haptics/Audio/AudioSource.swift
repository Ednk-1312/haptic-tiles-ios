import Foundation

/// Thrown when a song's audio is protected/unavailable (e.g. DRM or an
/// undownloaded cloud item).
enum AudioUnavailableError: Error {
    case protected
}

/// Converts internal failures into concise player-facing copy. UI code should
/// never display `Error.localizedDescription` directly: decoder/framework
/// errors can contain implementation details, paths, or opaque error codes.
enum UserFacingError {
    static func message(for error: Error, fallback: String) -> String {
        switch error {
        case let error as ImportError:
            return error.errorDescription ?? fallback
        case let error as AnalysisError:
            return error.errorDescription ?? fallback
        case let error as ChartGenerationError:
            return error.errorDescription ?? fallback
        default:
            return fallback
        }
    }
}

/// Where a song's playable audio comes from.
/// The analyzer, chart pipeline and game engine only ever see a URL — they
/// don't care about the source kind.
enum AudioSourceKind: String, Codable, Sendable {
    case mediaLibrary
    case file

    var displayName: String {
        switch self {
        case .mediaLibrary: return "My Music"
        case .file: return "Imported File"
        }
    }
}

/// Abstraction over song audio so the DSP pipeline is source-agnostic.
protocol AudioSource: Sendable {
    var kind: AudioSourceKind { get }

    /// Resolves to a URL that can be decoded/played, or nil when the audio is
    /// protected or otherwise unavailable to this app.
    func resolveAudioURL() -> URL?
}

/// Audio stored in the app sandbox (Files import).
struct FileAudioSource: AudioSource {
    let url: URL

    var kind: AudioSourceKind { .file }

    func resolveAudioURL() -> URL? { url }
}