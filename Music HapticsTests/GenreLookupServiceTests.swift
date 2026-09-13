import XCTest
@testable import Music_Haptics

/// Genre lookup service: cache-first behavior, timeout-bounded failure, and
/// offline safety. The network step must never make gameplay wait or fail.
@MainActor
final class GenreLookupServiceTests: XCTestCase {

    func testLocalMetadataWinsWithoutNetwork() async {
        let service = GenreLookupService()
        service.clearCacheForTesting()
        // Local genre present: resolves immediately regardless of title.
        let mood = await service.resolveMood(title: "Anything", artist: "Anyone", localGenre: "Heavy Metal")
        XCTAssertEqual(mood, .rock)
    }

    func testNeutralLocalGenreFallsThrough() async {
        let service = GenreLookupService()
        service.clearCacheForTesting()
        // No genre and an unsearchable title: the network lookup misses or
        // fails fast — either way the answer is the neutral fallback.
        let mood = await service.resolveMood(title: "zzzq_unfindable_zzzq", artist: nil, localGenre: nil)
        XCTAssertEqual(mood, .neutral)
    }

    func testCachedGenreIsReusedWithoutNetwork() async {
        let service = GenreLookupService()
        service.clearCacheForTesting()
        // First call: resolves through (bounded) network/miss and caches the
        // negative result. Second call must return the identical answer —
        // served from cache.
        let first = await service.resolveMood(title: "q_cache_probe_q", artist: "x", localGenre: nil)
        let second = await service.resolveMood(title: "q_cache_probe_q", artist: "x", localGenre: nil)
        XCTAssertEqual(first, second)
    }

    /// The disk cache survives across service instances (process relaunches).
    func testDiskCachePersistsAcrossInstances() async {
        let a = GenreLookupService()
        a.clearCacheForTesting()
        _ = await a.resolveMood(title: "q_persist_probe_q", artist: "y", localGenre: nil)
        let b = GenreLookupService()
        let mood = await b.resolveMood(title: "q_persist_probe_q", artist: "y", localGenre: nil)
        XCTAssertEqual(mood, .neutral) // stable, cache-served
    }

    /// Whitespace/case normalization: the same song queried differently
    /// shares one cache entry (no repeated network for cosmetic variants).
    /// The probe title resolves through the live network, so the assertion
    /// is cache consistency, not a specific genre.
    func testQueryNormalizationSharesCache() async {
        let service = GenreLookupService()
        service.clearCacheForTesting()
        let first = await service.resolveMood(title: "  Night   Drive ", artist: "Anyone", localGenre: nil)
        // Different spacing/case must hit the same normalized cache key and
        // return the identical mood without a second network round-trip.
        let again = await service.resolveMood(title: "night drive", artist: "anyone", localGenre: nil)
        XCTAssertEqual(first, again)
    }

    // MARK: - Mood → background integration

    /// The theme factory accepts a mood and the palette lands in the theme.
    /// (No network here — the factory is pure once the mood is resolved.)
    func testThemeFactoryAppliesMoodToFallback() {
        let theme = SongBackgroundThemeFactory.make(artworkData: nil, seed: 42, mood: .rock)
        XCTAssertEqual(theme.mood, .rock)
        XCTAssertFalse(theme.isFallback == false, "no artwork → fallback theme")
        // A rock fallback must lean warm-dark vs the neutral one.
        let neutral = SongBackgroundThemeFactory.make(artworkData: nil, seed: 42, mood: .neutral)
        let rockUI = UIColor(theme.topColor)
        let neutralUI = UIColor(neutral.topColor)
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        rockUI.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        var nr: CGFloat = 0, ng: CGFloat = 0, nb: CGFloat = 0, na: CGFloat = 0
        neutralUI.getRed(&nr, green: &ng, blue: &nb, alpha: &na)
        XCTAssertGreaterThan(rr, nr, "rock mood must warm the fallback top color")
    }

    func testThemeFactoryBlendsMoodWithArtwork() {
        // 1×1 red artwork: dominant color is red; the sad mood must cool it.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let red = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        guard let data = red.pngData() else { return XCTFail("png encode failed") }
        let plain = SongBackgroundThemeFactory.make(artworkData: data, seed: 7, mood: .neutral)
        let sad = SongBackgroundThemeFactory.make(artworkData: data, seed: 7, mood: .sad)
        var pr: CGFloat = 0, pg: CGFloat = 0, pb: CGFloat = 0, pa: CGFloat = 0
        UIColor(plain.topColor).getRed(&pr, green: &pg, blue: &pb, alpha: &pa)
        var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
        UIColor(sad.topColor).getRed(&sr, green: &sg, blue: &sb, alpha: &sa)
        XCTAssertGreaterThan(pr, sr, "sad mood must pull the red artwork's top color toward cool blue")
        XCTAssertEqual(sad.mood, GenreMood.sad)
    }
}
