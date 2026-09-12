import Foundation

/// Persists replay files as versioned JSON. Mirrors ChartStorage's style:
/// corrupt or future-versioned files are refused (never decoded into garbage)
/// and missing files simply return nil — nothing here can crash the app.
enum ReplayStorage {
    /// Test hook: overrides the storage directory (defaults to
    /// Application Support/Replays). Must be set before first use.
    nonisolated(unsafe) static var customDirectory: URL?

    static var directory: URL {
        if let customDirectory { return customDirectory }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Replays", isDirectory: true)
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).replay.json")
    }

    // MARK: - Write

    /// Saves atomically (temp file + rename). Returns false on any failure.
    @discardableResult
    static func save(_ replay: ReplayFile) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let url = url(for: replay.id)
            let data = try encoder.encode(replay)
            let tmp = directory.appendingPathComponent("\(replay.id.uuidString).tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Read

    /// Loads a replay. Returns nil for: missing file, undecodable/corrupt
    /// data, or a version newer than the app understands. The replay is
    /// deleted when it's unreadable (it can never be shown anyway).
    static func load(id: UUID) -> ReplayFile? {
        let url = url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let replay = try decoder.decode(ReplayFile.self, from: Data(contentsOf: url))
            guard replay.isCurrentVersion else {
                // Future/unknown schema: never misread. Leave the file for a
                // future app version that understands it.
                return nil
            }
            return replay
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Every saved replay for a song, newest first.
    static func savedReplays(songID: UUID) -> [ReplayFile] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { file -> ReplayFile? in
                guard let data = try? Data(contentsOf: file) else { return nil }
                guard let replay = try? decoder.decode(ReplayFile.self, from: data),
                      replay.isCurrentVersion,
                      replay.songID == songID else { return nil }
                return replay
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Delete

    @discardableResult
    static func delete(id: UUID) -> Bool {
        do {
            try FileManager.default.removeItem(at: url(for: id))
            return true
        } catch {
            return false
        }
    }

    /// Removes unreadable/corrupt replay files. Returns the count removed.
    static func purgeInvalid() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let replay = try? decoder.decode(ReplayFile.self, from: data),
               replay.isCurrentVersion {
                continue
            }
            if (try? FileManager.default.removeItem(at: file)) != nil {
                removed += 1
            }
        }
        return removed
    }
}