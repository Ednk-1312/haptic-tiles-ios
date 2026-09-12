import Foundation

/// What a media-library lookup can tell us about a song's audio accessibility.
struct MediaAssetInfo: Sendable {
    var assetURL: URL?
    var isCloudOnly: Bool
    var hasProtectedAsset: Bool

    init(assetURL: URL?, isCloudOnly: Bool, hasProtectedAsset: Bool = false) {
        self.assetURL = assetURL
        self.isCloudOnly = isCloudOnly
        self.hasProtectedAsset = hasProtectedAsset
    }
}

/// Why a library item's audio can (or can't) be reached.
/// The three MediaPlayer facts are kept separate — DRM, cloud state and URL
/// presence are NOT interchangeable, and a decode failure never implies DRM.
enum AudioAccessState: String, Sendable, Equatable {
    /// assetURL is present → raw audio is reachable; attempt decode.
    case accessible
    /// FairPlay/DRM (hasProtectedAsset) — iOS never gives us raw audio.
    case protected
    /// iCloud item that isn't downloaded (isCloudItem with no asset URL).
    case cloudUnavailable
    /// No asset URL and no known flag — report honestly, don't guess DRM.
    case unavailable
}

/// Abstraction over MPMediaLibrary lookups so tests can mock the library.
/// The real iOS-backed implementation lives in MPMediaLibraryProvider.swift.
protocol MediaLibraryProviding: Sendable {
    func mediaAssetInfo(persistentID: UInt64) -> MediaAssetInfo?
}

/// Classifies whether a library item's audio can be analyzed.
///
/// `assetURL != nil` is the ONLY signal that raw audio is reachable, and it
/// wins even when `isCloudItem` is true: a downloaded Apple Music item exposes
/// an asset URL and IS analyzable. `hasProtectedAsset` marks FairPlay audio we
/// can never decode. A missing URL with neither flag is left as `.unavailable`
/// rather than mislabeled DRM.
enum AudioAccessClassifier {
    static func state(_ info: MediaAssetInfo?) -> AudioAccessState {
        guard let info else { return .unavailable }
        if info.assetURL != nil { return .accessible }
        if info.hasProtectedAsset { return .protected }
        if info.isCloudOnly { return .cloudUnavailable }
        return .unavailable
    }

    static func isAccessible(_ info: MediaAssetInfo?) -> Bool {
        state(info) == .accessible
    }
}

/// Audio source for a song in the user's personal Music library.
struct MediaLibraryAudioSource: AudioSource {
    let persistentID: UInt64
    let provider: any MediaLibraryProviding

    var kind: AudioSourceKind { .mediaLibrary }

    init(persistentID: UInt64, provider: any MediaLibraryProviding) {
        self.persistentID = persistentID
        self.provider = provider
    }

    func resolveAudioURL() -> URL? {
        let info = provider.mediaAssetInfo(persistentID: persistentID)
        guard AudioAccessClassifier.isAccessible(info) else { return nil }
        return info?.assetURL
    }
}