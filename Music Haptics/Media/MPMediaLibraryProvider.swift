import Foundation
import MediaPlayer

/// Real provider backed by MPMediaLibrary / MPMediaQuery (iOS only — kept in
/// its own file so the platform-neutral `AudioSource` abstraction can also be
/// compiled on macOS for logic tests).
struct MPMediaLibraryProvider: MediaLibraryProviding {
    func mediaAssetInfo(persistentID: UInt64) -> MediaAssetInfo? {
        guard let item = Self.item(persistentID: persistentID) else { return nil }
        return MediaAssetInfo(assetURL: item.assetURL,
                              isCloudOnly: item.isCloudItem,
                              hasProtectedAsset: item.hasProtectedAsset)
    }

    /// Raw MPMediaItem lookup (also used by the audio diagnostics probe).
    static func item(persistentID: UInt64) -> MPMediaItem? {
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: persistentID),
                                                 forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery(filterPredicates: [predicate])
        return query.items?.first
    }
}

extension MediaLibraryAudioSource {
    /// Convenience initializer using the real library (iOS only).
    init(persistentID: UInt64) {
        self.init(persistentID: persistentID, provider: MPMediaLibraryProvider())
    }
}