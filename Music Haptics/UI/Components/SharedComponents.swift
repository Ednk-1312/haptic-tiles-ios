import SwiftUI
import UIKit

/// Small shared visual pieces.

struct StatusBadge: View {
    let state: AnalysisState

    var body: some View {
        Text(state.displayName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.18), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch state {
        case .ready: return .green
        case .analyzing, .generatingChart: return .orange
        case .imported: return .secondary
        case .protected: return .gray
        case .failed: return .red
        }
    }
}

/// Marks where a song's audio comes from.
struct SourceBadge: View {
    let kind: AudioSourceKind

    var body: some View {
        Label(kind.displayName, systemImage: kind == .mediaLibrary ? "music.note" : "folder")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct DifficultyBadge: View {
    let difficulty: DifficultyLevel

    var body: some View {
        Text(difficulty.displayName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(difficultyColor.opacity(0.18), in: Capsule())
            .foregroundStyle(difficultyColor)
    }

    private var difficultyColor: Color {
        switch difficulty {
        case .easy: return .green
        case .casual: return .teal
        case .medium: return .blue
        case .hard: return .orange
        case .expert: return .red
        case .extreme: return .purple
        }
    }
}

/// Artwork or a gradient placeholder (no bundled assets needed).
struct ArtworkView: View {
    let image: UIImage?

    init(data: Data?) {
        self.image = data.flatMap(UIImage.init(data:))
    }

    init(image: UIImage?) {
        self.image = image
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.indigo, .purple.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        // Artwork is decorative: the title/artist text beside it carries the
        // meaning, and album art has no accessible content of its own.
        .accessibilityHidden(true)
    }
}