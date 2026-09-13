import Foundation

/// A user-visible snapshot of one song's preparation pipeline. This is kept
/// separate from SwiftData's `SongRecord` lifecycle so the UI can show a
/// truthful, cancellable operation without polling or guessing from a spinner.
enum PipelineStage: String, Sendable, Equatable {
    case idle
    case resolvingAudio
    case analyzing
    case designingChart
    case ready
    case failed
    case cancelled

    var title: String {
        switch self {
        case .idle: return "Ready to prepare"
        case .resolvingAudio: return "Opening audio"
        case .analyzing: return "Listening to the song"
        case .designingChart: return "Designing the chart"
        case .ready: return "Ready to play"
        case .failed: return "Couldn't prepare this song"
        case .cancelled: return "Preparation cancelled"
        }
    }
}

struct PipelineStatus: Sendable, Equatable {
    let stage: PipelineStage
    let progress: Double
    let message: String
    let errorMessage: String?

    static let idle = PipelineStatus(stage: .idle, progress: 0,
                                     message: "Ready to prepare", errorMessage: nil)

    var isActive: Bool {
        switch stage {
        case .resolvingAudio, .analyzing, .designingChart: return true
        case .idle, .ready, .failed, .cancelled: return false
        }
    }

    static func active(_ stage: PipelineStage, progress: Double, message: String) -> PipelineStatus {
        PipelineStatus(stage: stage, progress: min(1, max(0, progress)),
                       message: message, errorMessage: nil)
    }

    static func failed(_ message: String) -> PipelineStatus {
        PipelineStatus(stage: .failed, progress: 1, message: "Couldn't prepare this song",
                       errorMessage: message)
    }
}

enum PipelineCoordinatorError: LocalizedError {
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .cancelled: return "Preparation was cancelled."
        }
    }
}
