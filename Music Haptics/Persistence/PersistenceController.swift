import Foundation
import SwiftData

/// Owns the SwiftData container. Songs are metadata-only; charts and analysis
/// live in JSON files under Application Support (see ChartStorage).
@MainActor
final class PersistenceController {
    // Workaround for swiftlang/swift#87316 (see StatsManager).
    deinit {}
    static let shared = PersistenceController()

    let container: ModelContainer

    init() {
        container = Self.makeContainer()
    }

    /// Disk store first; on a corrupt/unreadable store, remove ONLY the
    /// SwiftData store files (the Charts/Analysis/AIDiagnostics JSON
    /// subdirectories are never touched) and retry once on disk so the app
    /// recovers WITH persistence; in-memory is the final fallback so the app
    /// always launches.
    private static func makeContainer() -> ModelContainer {
        if let container = try? ModelContainer(for: SongRecord.self) { return container }
        let storeURL = URL.applicationSupportDirectory.appendingPathComponent("default.store")
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
        }
        if let container = try? ModelContainer(for: SongRecord.self) { return container }
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        if let container = try? ModelContainer(for: SongRecord.self, configurations: config) { return container }
        // Unreachable in practice (in-memory container for one trivial model);
        // kept as an explicit terminal point rather than an optional container
        // rippling through the app.
        preconditionFailure("SwiftData container unavailable in every mode")
    }
}