import Foundation
import os

/// Resolves a song's genre for the gameplay background BEFORE the song
/// starts — never during gameplay.
///
/// Order of preference (each step cached to disk so the same song never
/// re-queries):
/// 1. Local file / media-library metadata genre (`SongRecord.genre`) — free,
///    offline, already on the device.
/// 2. iTunes Search API lookup by title + artist (`term=«title» «artist»`),
///    asking only for the 100-best-match JSON (no auth, no user data beyond
///    the public title/artist strings already shown in the UI).
/// 3. Neutral fallback — the game must never wait on or fail from this.
///
/// Results persist in Application Support/Lookups as tiny JSON files keyed by
/// a stable hash of the normalized query, so offline launches reuse them.
struct GenreLookupService: Sendable {
    /// Process-wide instance: one disk cache, one URL session. Gameplay
    /// screens resolve through it so repeated sessions never re-hit the net.
    static let shared = GenreLookupService()

    struct Config: Sendable {
        var timeout: TimeInterval = 3.0
        /// In-memory TTL; disk cache is permanent (genres are stable).
        var memoryTTL: TimeInterval = 7 * 24 * 3600
        var endpoint: URL = URL(string: "https://itunes.apple.com/search?media=music&entity=song&limit=1")!
    }

    /// Disk cache entry. `genre` nil = looked up and NOT found (negative
    /// cache so an unavailable song doesn't re-hit the network each launch).
    struct Entry: Codable, Sendable, Equatable {
        var genre: String?
        var fetchedAt: Date
    }

    private let config: Config
    private let session: URLSession
    private let cacheDirectory: URL
    private let log = Logger(subsystem: "com.eshannandakumarpersonalteam.MusicHaptics", category: "GenreLookup")

    init(config: Config = Config(), session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = config.timeout
            cfg.timeoutIntervalForResource = config.timeout + 2
            cfg.waitsForConnectivity = false
            cfg.allowsCellularAccess = true
            self.session = URLSession(configuration: cfg)
        }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        self.cacheDirectory = support.appendingPathComponent("Lookups", isDirectory: true)
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Resolves the mood for a song. Never throws, never blocks long: local
    /// metadata is synchronous; the network step is timeout-bounded.
    func resolveMood(title: String?, artist: String?, localGenre: String?) async -> GenreMood {
        // 1. Local metadata wins — free and offline.
        let local = GenreMood.resolve(from: localGenre)
        if local != .neutral { return local }

        // 2. Cached lookup (disk; genres are stable so the cache is
        // permanent — the TTL field is retained in the file format for
        // future invalidation but no longer expires entries).
        let query = normalizedQuery(title: title, artist: artist)
        if let entry = cachedEntry(for: query) {
            if let genre = entry.genre {
                return GenreMood.resolve(from: genre)
            }
            return .neutral // negative-cached miss
        }

        // 3. Network lookup, timeout-bounded by the session configuration.
        let genre = await fetchGenre(title: title, artist: artist, query: query)
        store(Entry(genre: genre, fetchedAt: Date()), for: query)
        if let genre {
            log.info("genre lookup hit: \(query, privacy: .public) → \(genre, privacy: .public)")
        }
        return GenreMood.resolve(from: genre)
    }

    /// Test hook: drops the disk cache for deterministic tests.
    func clearCacheForTesting() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("genre-") {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Query

    /// Stable, deterministic key: lowercase collapsed-whitespace
    /// "title artist". Falls back to title-only.
    private func normalizedQuery(title: String?, artist: String?) -> String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let a = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let collapsed = { (s: String) in s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let tt = collapsed(t), aa = collapsed(a)
        if tt.isEmpty { return "unknown" }
        return aa.isEmpty ? tt : "\(tt) \(aa)"
    }

    private func cacheFileURL(for query: String) -> URL {
        cacheDirectory.appendingPathComponent("genre-\(Self.stableDigest(query)).json")
    }

    private func cachedEntry(for query: String) -> Entry? {
        let url = cacheFileURL(for: query)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        return entry
    }

    private func store(_ entry: Entry, for query: String) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: cacheFileURL(for: query), options: .atomic)
    }

    // MARK: - Network

    /// Returns the primary genre name, nil when not found/unreachable.
    private func fetchGenre(title: String?, artist: String?, query: String) async -> String? {
        var components = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false)
        let existing = components?.queryItems ?? []
        components?.queryItems = existing + [URLQueryItem(name: "term", value: query)]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = config.timeout
        request.allowsCellularAccess = true
        do {
            let (data, _) = try await session.data(for: request)
            struct SearchResponse: Decodable { var results: [Result] }
            struct Result: Decodable { var primaryGenreName: String? }
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            return decoded.results.first?.primaryGenreName
        } catch let error as URLError where error.code == .cancelled {
            log.info("genre lookup cancelled: \(query, privacy: .public)")
            return nil
        } catch {
            // Offline, timeout, decode failure — all the same: neutral.
            log.info("genre lookup unavailable (\(error.localizedDescription, privacy: .public)): \(query, privacy: .public)")
            return nil
        }
    }

    /// FNV-1a digest (stable across launches; no crypto needed for a cache key).
    private static func stableDigest(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }
}
