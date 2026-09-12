import XCTest
@testable import Music_Haptics

/// Deterministic tests for the pure palette analyzer: dominant/secondary/
/// accent extraction, brightness/saturation/warm-cool metrics, energy/quiet
/// variants, fallbacks, and edge cases. No images or UIKit involved.
final class ArtworkPaletteTests: XCTestCase {

    // MARK: - Helpers

    private func buffer(colors: [RGB]) -> [UInt8] {
        var out: [UInt8] = []
        for c in colors {
            out.append(UInt8(c.r * 255))
            out.append(UInt8(c.g * 255))
            out.append(UInt8(c.b * 255))
            out.append(255)
        }
        return out
    }

    // MARK: - Dominant / secondary

    func testDominantColorFromHueMajority() {
        // Mostly warm red-orange, some green → dominant is warm.
        let warm = RGB(0.85, 0.25, 0.1)
        let green = RGB(0.15, 0.7, 0.2)
        let colors = [warm, warm, warm, warm, warm, green, green, green]
        let metrics = ArtworkPaletteAnalyzer.analyze(colors: colors)!
        XCTAssertGreaterThan(metrics.dominant.r, metrics.dominant.g)
        XCTAssertGreaterThan(metrics.dominant.r, metrics.dominant.b)
        // Secondary leans green.
        XCTAssertGreaterThan(metrics.secondary.g, metrics.secondary.r)
    }

    func testAccentIsMostSaturatedPixel() {
        let muted = RGB(0.2, 0.2, 0.2)
        let vivid = RGB(0.1, 0.9, 0.4)
        let colors = [muted, muted, muted, vivid]
        let metrics = ArtworkPaletteAnalyzer.analyze(colors: colors)!
        XCTAssertEqual(metrics.accent, vivid)
    }

    // MARK: - Metrics

    func testBrightnessSaturationWarmCool() {
        // Pure blue: luma 0.0722, saturation 1, warmCool -1.
        let blue = RGB(0, 0, 1)
        let metrics = ArtworkPaletteAnalyzer.analyze(colors: [blue, blue])!
        XCTAssertEqual(metrics.brightness, 0.0722, accuracy: 0.0001)
        XCTAssertEqual(metrics.saturation, 1, accuracy: 0.0001)
        XCTAssertEqual(metrics.warmCool, -1, accuracy: 0.0001)
        // Pure red is fully warm.
        let red = ArtworkPaletteAnalyzer.analyze(colors: [RGB(1, 0, 0)])!
        XCTAssertEqual(red.warmCool, 1, accuracy: 0.0001)
        // Gray is neutral.
        let gray = ArtworkPaletteAnalyzer.analyze(colors: [RGB(0.5, 0.5, 0.5)])!
        XCTAssertEqual(gray.saturation, 0, accuracy: 0.0001)
        XCTAssertEqual(gray.warmCool, 0, accuracy: 0.0001)
    }

    func testMixedWarmCoolAverages() {
        // One red + one blue → warmCool ≈ 0.
        let metrics = ArtworkPaletteAnalyzer.analyze(colors: [RGB(1, 0, 0), RGB(0, 0, 1)])!
        XCTAssertEqual(metrics.warmCool, 0, accuracy: 0.0001)
    }

    // MARK: - Variants

    func testEnergeticVariantBoostsSaturationAndLightness() {
        let base = RGB(0.2, 0.35, 0.5)
        let energetic = base.energetic
        XCTAssertGreaterThan(energetic.saturation, base.saturation)
        XCTAssertGreaterThan(energetic.luma, base.luma)
        // Hue family is preserved (blue stays blue).
        XCTAssertGreaterThan(energetic.b, energetic.r)
    }

    func testQuietVariantDesaturates() {
        let base = RGB(0.9, 0.3, 0.2)
        let quiet = base.quiet
        XCTAssertLessThan(quiet.saturation, base.saturation)
        XCTAssertLessThan(quiet.luma, base.luma)
    }

    func testEnergeticAndQuietClampToValidRange() {
        let white = RGB(1, 1, 1).energetic
        XCTAssertLessThanOrEqual(white.r, 1)
        XCTAssertLessThanOrEqual(white.g, 1)
        XCTAssertLessThanOrEqual(white.b, 1)
        let black = RGB(0, 0, 0).quiet
        XCTAssertGreaterThanOrEqual(black.r, 0)
        XCTAssertGreaterThanOrEqual(black.g, 0)
    }

    // MARK: - Fallback

    func testFallbackIsDeterministicPerSeed() {
        let a = ArtworkPaletteAnalyzer.fallback(seed: 42)
        let b = ArtworkPaletteAnalyzer.fallback(seed: 42)
        XCTAssertEqual(a.top, b.top)
        XCTAssertEqual(a.bottom, b.bottom)
        XCTAssertEqual(a.accent, b.accent)
    }

    func testFallbackVariesAcrossSeeds() {
        let a = ArtworkPaletteAnalyzer.fallback(seed: 1)
        let b = ArtworkPaletteAnalyzer.fallback(seed: 2)
        XCTAssertNotEqual(a.top, b.top, "different songs must get different fallback hues")
    }

    func testFallbackColorsAreValid() {
        let (top, bottom, accent) = ArtworkPaletteAnalyzer.fallback(seed: 7)
        for c in [top, bottom, accent] {
            XCTAssertTrue(c.r >= 0 && c.r <= 1)
            XCTAssertTrue(c.g >= 0 && c.g <= 1)
            XCTAssertTrue(c.b >= 0 && c.b <= 1)
        }
        XCTAssertGreaterThan(accent.saturation, 0.5, "fallback accent stays vivid for notes")
    }

    // MARK: - Edge cases

    func testEmptyInputReturnsNil() {
        XCTAssertNil(ArtworkPaletteAnalyzer.analyze(pixels: [], width: 12))
        XCTAssertNil(ArtworkPaletteAnalyzer.analyze(colors: []))
    }

    func testMalformedBufferReturnsNil() {
        XCTAssertNil(ArtworkPaletteAnalyzer.analyze(pixels: [1, 2, 3], width: 1))
    }

    func testAllBlackArtworkStillProducesTheme() {
        let black = RGB(0, 0, 0)
        let metrics = ArtworkPaletteAnalyzer.analyze(colors: [black, black, black, black])!
        XCTAssertEqual(metrics.brightness, 0, accuracy: 0.0001)
        // Accent falls back to a vivid-enough mid color (never pure black).
        XCTAssertGreaterThan(metrics.accent.luma, 0.1)
    }

    func testSinglePixelBuffer() {
        let colors = [RGB(0.4, 0.6, 0.8)]
        let metrics = ArtworkPaletteAnalyzer.analyze(colors: colors)!
        XCTAssertEqual(metrics.dominant, RGB(0.4, 0.6, 0.8))
        XCTAssertEqual(metrics.brightness, RGB(0.4, 0.6, 0.8).luma, accuracy: 0.0001)
    }

    func testGrayscaleArtworkGetsLumaBasedDominants() {
        // 3 light grays + 1 dark gray: dominant bright-ish, secondary dark.
        let light = RGB(0.8, 0.8, 0.8)
        let dark = RGB(0.1, 0.1, 0.1)
        let metrics = ArtworkPaletteAnalyzer.analyze(colors: [light, light, light, dark])!
        XCTAssertGreaterThan(metrics.dominant.luma, metrics.secondary.luma)
    }

    // MARK: - Determinism

    func testAnalysisIsDeterministic() {
        var rng = SplitMix64(state: 123)
        let colors = (0..<200).map { _ in
            RGB(rng.uniform(), rng.uniform(), rng.uniform())
        }
        let a = ArtworkPaletteAnalyzer.analyze(colors: colors)
        let b = ArtworkPaletteAnalyzer.analyze(colors: colors)
        XCTAssertEqual(a, b)
    }
}