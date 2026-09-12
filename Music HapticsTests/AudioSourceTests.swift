import XCTest
@testable import Music_Haptics

/// Mock MediaPlayer library: lets us test accessible / protected / cloud-only /
/// unavailable classification without needing real DRM audio in the test
/// environment.
private struct MockMediaLibraryProvider: MediaLibraryProviding {
    let items: [UInt64: MediaAssetInfo]

    func mediaAssetInfo(persistentID: UInt64) -> MediaAssetInfo? {
        items[persistentID]
    }
}

final class AudioSourceTests: XCTestCase {

    private static let accessibleID: UInt64 = 111
    private static let downloadedCloudID: UInt64 = 121
    private static let protectedID: UInt64 = 222
    private static let cloudOnlyID: UInt64 = 333
    private static let unavailableID: UInt64 = 444

    private func makeProvider() -> MockMediaLibraryProvider {
        MockMediaLibraryProvider(items: [
            Self.accessibleID: MediaAssetInfo(assetURL: URL(string: "ipod-library://item/item.m4a?id=111")!,
                                              isCloudOnly: false, hasProtectedAsset: false),
            // A downloaded Apple Music item: isCloudItem == true BUT an asset
            // URL is present — its audio IS reachable, so it must resolve.
            Self.downloadedCloudID: MediaAssetInfo(assetURL: URL(string: "ipod-library://item/item.m4a?id=121")!,
                                                   isCloudOnly: true, hasProtectedAsset: false),
            Self.protectedID: MediaAssetInfo(assetURL: nil, isCloudOnly: true, hasProtectedAsset: true),
            Self.cloudOnlyID: MediaAssetInfo(assetURL: nil, isCloudOnly: true, hasProtectedAsset: false),
            // No URL and no known flag: report honestly as unavailable,
            // never guess DRM.
            Self.unavailableID: MediaAssetInfo(assetURL: nil, isCloudOnly: false, hasProtectedAsset: false),
        ])
    }

    // MARK: - Files source

    func testFileSourceAlwaysResolves() {
        let url = URL(fileURLWithPath: "/tmp/song.m4a")
        let source = FileAudioSource(url: url)
        XCTAssertEqual(source.kind, .file)
        XCTAssertEqual(source.resolveAudioURL(), url)
    }

    // MARK: - Media-library source

    func testAccessibleLibraryItemResolves() {
        let source = MediaLibraryAudioSource(persistentID: Self.accessibleID, provider: makeProvider())
        XCTAssertEqual(source.kind, .mediaLibrary)
        XCTAssertNotNil(source.resolveAudioURL())
    }

    func testDownloadedCloudItemResolves() {
        // isCloudItem must NOT block resolution when an asset URL exists:
        // downloaded Apple Music items are cloud items with reachable audio.
        let source = MediaLibraryAudioSource(persistentID: Self.downloadedCloudID, provider: makeProvider())
        XCTAssertNotNil(source.resolveAudioURL(), "assetURL presence, not isCloudItem, decides accessibility")
    }

    func testProtectedItemWithoutAssetURLResolvesNil() {
        let source = MediaLibraryAudioSource(persistentID: Self.protectedID, provider: makeProvider())
        XCTAssertNil(source.resolveAudioURL(), "Protected items must never resolve to analyzable audio")
    }

    func testCloudOnlyItemWithoutAssetURLResolvesNil() {
        let source = MediaLibraryAudioSource(persistentID: Self.cloudOnlyID, provider: makeProvider())
        XCTAssertNil(source.resolveAudioURL())
    }

    func testUnavailableItemResolvesNil() {
        let source = MediaLibraryAudioSource(persistentID: Self.unavailableID, provider: makeProvider())
        XCTAssertNil(source.resolveAudioURL())
    }

    func testUnknownItemResolvesNil() {
        let source = MediaLibraryAudioSource(persistentID: 999, provider: makeProvider())
        XCTAssertNil(source.resolveAudioURL())
    }

    // MARK: - Classifier

    func testClassifierDistinguishesAllStates() {
        let provider = makeProvider()
        XCTAssertEqual(AudioAccessClassifier.state(provider.mediaAssetInfo(persistentID: Self.accessibleID)), .accessible)
        XCTAssertEqual(AudioAccessClassifier.state(provider.mediaAssetInfo(persistentID: Self.downloadedCloudID)), .accessible,
                       "A cloud item with an asset URL is accessible")
        XCTAssertEqual(AudioAccessClassifier.state(provider.mediaAssetInfo(persistentID: Self.protectedID)), .protected)
        XCTAssertEqual(AudioAccessClassifier.state(provider.mediaAssetInfo(persistentID: Self.cloudOnlyID)), .cloudUnavailable)
        XCTAssertEqual(AudioAccessClassifier.state(provider.mediaAssetInfo(persistentID: Self.unavailableID)), .unavailable,
                       "Missing URL without flags must not be mislabeled DRM")
        XCTAssertEqual(AudioAccessClassifier.state(nil), .unavailable)
    }

    func testClassifierIsAccessibleMatchesState() {
        let provider = makeProvider()
        XCTAssertTrue(AudioAccessClassifier.isAccessible(provider.mediaAssetInfo(persistentID: Self.accessibleID)))
        XCTAssertTrue(AudioAccessClassifier.isAccessible(provider.mediaAssetInfo(persistentID: Self.downloadedCloudID)))
        XCTAssertFalse(AudioAccessClassifier.isAccessible(provider.mediaAssetInfo(persistentID: Self.protectedID)))
        XCTAssertFalse(AudioAccessClassifier.isAccessible(provider.mediaAssetInfo(persistentID: Self.cloudOnlyID)))
        XCTAssertFalse(AudioAccessClassifier.isAccessible(provider.mediaAssetInfo(persistentID: Self.unavailableID)))
        XCTAssertFalse(AudioAccessClassifier.isAccessible(nil))
    }

    // MARK: - Kind

    func testSourceKindCodableRoundTrip() {
        for kind in [AudioSourceKind.mediaLibrary, .file] {
            let data = try! JSONEncoder().encode(kind)
            XCTAssertEqual(try! JSONDecoder().decode(AudioSourceKind.self, from: data), kind)
        }
    }

    func testSourceKindDisplayNames() {
        XCTAssertEqual(AudioSourceKind.mediaLibrary.displayName, "My Music")
        XCTAssertEqual(AudioSourceKind.file.displayName, "Imported File")
    }
}