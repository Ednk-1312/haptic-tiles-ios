import Foundation

/// On-device persistence for gameplay results (one per song + difficulty,
/// latest wins). Automatic queue transitions save results here before the next
/// song starts, so nothing played is ever lost.
enum ResultsStorage {
    private static var directory: URL {
        let dir = AppDirectories.documentsDirectory.appendingPathComponent("Results", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(songID: UUID, difficulty: DifficultyLevel) -> URL {
        directory.appendingPathComponent(songID.uuidString + "." + difficulty.rawValue + ".result.json")
    }

    static func save(_ result: GameplayResult, songID: UUID) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(result).write(to: url(songID: songID, difficulty: result.difficulty),
                                         options: .atomic)
    }

    static func load(songID: UUID, difficulty: DifficultyLevel) -> GameplayResult? {
        let file = url(songID: songID, difficulty: difficulty)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GameplayResult.self, from: Data(contentsOf: file))
    }

    static func deleteAll(for songID: UUID) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.lastPathComponent.hasPrefix(songID.uuidString + ".") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}