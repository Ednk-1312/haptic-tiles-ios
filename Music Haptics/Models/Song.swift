import Foundation
import SwiftData

/// Lifecycle state of a song's analysis/chart pipeline.
enum AnalysisState: String, Codable, Sendable {
    case imported
    case analyzing
    case generatingChart
    case ready
    case protected
    case failed

    var displayName: String {
        switch self {
        case .imported: return "Imported"
        case .analyzing: return "Analyzing"
        case .generatingChart: return "Generating Chart"
        case .ready: return "Ready"
        case .protected: return "Audio Unavailable"
        case .failed: return "Failed"
        }
    }
}

/// SwiftData record for one imported song.
/// Heavy artifacts (analysis, chart) live in JSON files, not here, so the
/// metadata store stays small and fast.
@Model
final class SongRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var artist: String
    var fileName: String            // e.g. "ABC123.m4a" inside Documents/Songs
    var duration: Double
    var importDate: Date
    var analysisStateRaw: String    // AnalysisState raw value (SwiftData-friendly)
    var errorMessage: String?
    var tempoBPM: Double?
    var tempoConfidence: Double?
    var chartDifficultyRaw: String?
    var chartVersion: Int?
    var chartNotesCount: Int?
    var difficultyScore: Double?
    var artworkData: Data?

    // Music-library source fields. Optional raws keep SwiftData lightweight
    // migration trivial for records created before library support existed.
    var sourceKindRaw: String?            // AudioSourceKind raw value; nil = legacy file import
    var mediaLibraryID: Int64?            // bitPattern of the UInt64 persistent ID
    var albumTitle: String?
    var genre: String?
    var libraryBPM: Int?                  // metadata BPM from MediaPlayer, kept separate from DSP BPM

    init(id: UUID = UUID(),
         title: String,
         artist: String,
         fileName: String,
         duration: Double,
         importDate: Date = Date(),
         artworkData: Data? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.fileName = fileName
        self.duration = duration
        self.importDate = importDate
        self.analysisStateRaw = AnalysisState.imported.rawValue
        self.artworkData = artworkData
    }

    var sourceKind: AudioSourceKind {
        get { AudioSourceKind(rawValue: sourceKindRaw ?? "") ?? .file }
        set { sourceKindRaw = newValue.rawValue }
    }

    var mediaLibraryPersistentID: UInt64? {
        get { mediaLibraryID.map { UInt64(bitPattern: $0) } }
        set { mediaLibraryID = newValue.map { Int64(bitPattern: $0) } }
    }

    var analysisState: AnalysisState {
        get { AnalysisState(rawValue: analysisStateRaw) ?? .imported }
        set { analysisStateRaw = newValue.rawValue }
    }

    var chartDifficulty: DifficultyLevel? {
        get { chartDifficultyRaw.flatMap(DifficultyLevel.init(rawValue:)) }
        set { chartDifficultyRaw = newValue?.rawValue }
    }

    /// Absolute URL of the copied audio file inside the app sandbox.
    var audioURL: URL {
        AppDirectories.songsDirectory.appendingPathComponent(fileName)
    }
}