import SwiftUI
import UIKit

/// Visual theme derived from the song's artwork: palette analysis (dominant,
/// secondary, accent, brightness, saturation, warm/cool), energy/quiet color
/// variants for section evolution, plus the blurred and hero-cropped images.
/// Built once per artwork (cached), never per frame.
///
/// `nonisolated`: the theme is assembled from heavy image work (decode +
/// blur + palette) that must run OFF the main actor — gameplay opening used
/// to stall while this ran synchronously on the UI thread. The struct is
/// immutable after construction, so it is safe to share across threads;
/// UIImages are display-only, hence @unchecked Sendable.
struct SongBackgroundTheme: @unchecked Sendable {
    let topColor: Color
    let bottomColor: Color
    let accent: Color
    let metrics: ArtworkMetrics?
    /// High-energy gradient variant (brighter/more saturated).
    let energyTop: Color
    let energyBottom: Color
    /// Quiet-section gradient variant (desaturated/darker).
    let quietTop: Color
    let quietBottom: Color
    let blurredArtwork: UIImage?
    /// Aspect-filled crop at ~1.15× for the atmospheric hero layer.
    let heroArtwork: UIImage?
    /// Deterministic particle seed (song-derived; fallback themes too).
    let particleSeed: UInt64
    /// Deterministic fallback (no artwork, or analysis failure).
    let isFallback: Bool
}

enum SongBackgroundThemeFactory {
    /// NSCache requires a class; the box keeps the value-type theme cacheable.
    private final class ThemeBox {
        let theme: SongBackgroundTheme
        init(_ theme: SongBackgroundTheme) { self.theme = theme }
    }

    /// Analyzed theme cache keyed by artwork bytes — repeated sessions on the
    /// same artwork never re-extract or re-blur.
    // NSCache is internally synchronized but not annotated Sendable in the
    // Xcode 16 SDK. The wrapper makes that ownership explicit without changing
    // the cache's behavior or lifetime.
    private static let cache = SendableThemeCache()

    static func make(artworkData: Data?, seed: UInt64 = 0) -> SongBackgroundTheme {
        guard let data = artworkData, let image = UIImage(data: data) else {
            let key = "fallback-\(seed)" as NSString
            if let cached = cache.object(forKey: key)?.theme { return cached }
            let theme = buildFallback(seed: seed)
            cache.setObject(ThemeBox(theme), forKey: key)
            return theme
        }
        let key = "art-\(data.count)-\(stableHash(data))" as NSString
        if let cached = cache.object(forKey: key)?.theme { return cached }
        let theme = build(from: image, seed: seed)
        cache.setObject(ThemeBox(theme), forKey: key)
        return theme
    }

    static func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - Build

    private static func build(from image: UIImage, seed: UInt64) -> SongBackgroundTheme {
        let pixels = rgbaPixels(image: image, target: CGSize(width: 24, height: 24))
        let metrics = pixels.flatMap { ArtworkPaletteAnalyzer.analyze(pixels: $0, width: 24) }
        let theme: SongBackgroundTheme
        if let metrics {
            let top = liftForReadability(metrics.dominant)
            let bottom = liftForReadability(metrics.secondary)
            let accent = liftForReadability(metrics.accent)
            theme = SongBackgroundTheme(
                topColor: Color(top),
                bottomColor: Color(bottom),
                accent: Color(accent),
                metrics: metrics,
                energyTop: Color(liftForReadability(metrics.dominant.energetic)),
                energyBottom: Color(liftForReadability(metrics.secondary.energetic)),
                quietTop: Color(liftForReadability(metrics.dominant.quiet)),
                quietBottom: Color(liftForReadability(metrics.secondary.quiet)),
                blurredArtwork: blurred(image),
                heroArtwork: heroCrop(image),
                particleSeed: seed != 0 ? seed : stableHash(image),
                isFallback: false)
        } else {
            theme = buildFallback(seed: seed)
        }
        return theme
    }

    /// No-artwork or analysis-failure path: fully deterministic per song,
    /// never a broken image.
    private static func buildFallback(seed: UInt64) -> SongBackgroundTheme {
        let (top, bottom, accent) = ArtworkPaletteAnalyzer.fallback(seed: seed)
        return SongBackgroundTheme(
            topColor: Color(liftForReadability(top)),
            bottomColor: Color(liftForReadability(bottom)),
            accent: Color(liftForReadability(accent)),
            metrics: nil,
            energyTop: Color(liftForReadability(top.energetic)),
            energyBottom: Color(liftForReadability(bottom.energetic)),
            quietTop: Color(liftForReadability(top.quiet)),
            quietBottom: Color(liftForReadability(bottom.quiet)),
            blurredArtwork: nil,
            heroArtwork: nil,
            particleSeed: seed,
            isFallback: true)
    }

    /// Dark colors are lifted so notes always read against the wash.
    private static func liftForReadability(_ c: RGB) -> UIColor {
        let lift: CGFloat = c.luma < 0.12 ? 0.12 - CGFloat(c.luma) : 0
        return UIColor(red: CGFloat(c.r) + lift, green: CGFloat(c.g) + lift,
                       blue: CGFloat(c.b) + lift, alpha: 1)
    }



    // MARK: - Image sampling / processing (runs once per artwork)

    /// Downscales + reads RGBA bytes from an image (feeds the pure analyzer).
    private static func rgbaPixels(image: UIImage, target: CGSize) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        let width = Int(target.width), height = Int(target.height)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &buffer, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(origin: .zero, size: target))
        return buffer
    }

    /// Blur is expensive, so it runs once here on a modest downscale; the
    /// screen shows it scaled up, which is fine for a soft backdrop.
    private static func blurred(_ image: UIImage) -> UIImage? {
        let targetSize = CGSize(width: 320, height: 320)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let down = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let ci = CIImage(image: down) else { return nil }
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(ci, forKey: kCIInputImageKey)
        filter?.setValue(38.0, forKey: kCIInputRadiusKey)
        guard let output = filter?.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(output, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Enlarged/cropped aspect-fill variant for the atmospheric hero layer.
    private static func heroCrop(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        // Portrait-ish crop: center, 4:5, slightly zoomed (1.15× of the fit).
        let targetAspect: CGFloat = 4.0 / 5.0
        let imageAspect = CGFloat(cg.width) / CGFloat(cg.height)
        var crop: CGRect
        if imageAspect > targetAspect {
            let cropWidth = CGFloat(cg.height) * targetAspect * 0.87
            crop = CGRect(x: (CGFloat(cg.width) - cropWidth) / 2, y: 0,
                          width: cropWidth, height: CGFloat(cg.height))
        } else {
            let cropHeight = CGFloat(cg.width) / targetAspect * 0.87
            crop = CGRect(x: 0, y: (CGFloat(cg.height) - cropHeight) / 2,
                          width: CGFloat(cg.width), height: cropHeight)
        }
        guard let cropped = cg.cropping(to: crop.intersection(full)) else { return nil }
        return UIImage(cgImage: cropped)
    }

    /// FNV-1a — stable across launches for the cache key and particle seed.
    private static func stableHash(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }

    private static func stableHash(_ image: UIImage) -> UInt64 {
        guard let data = image.pngData() else { return 0xDEAD_BEEF }
        return stableHash(data)
    }

    /// A small @unchecked Sendable owner for the thread-safe NSCache used by
    /// detached artwork analysis tasks.
    private final class SendableThemeCache: @unchecked Sendable {
        private let storage = NSCache<NSString, ThemeBox>()

        func object(forKey key: NSString) -> ThemeBox? {
            storage.object(forKey: key)
        }

        func setObject(_ object: ThemeBox, forKey key: NSString) {
            storage.setObject(object, forKey: key)
        }

        func removeAllObjects() {
            storage.removeAllObjects()
        }
    }
}

/// Interpolate between two colors (used for energy/quiet section evolution).
func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
    let t = min(1, max(0, t))
    func comp(_ c1: CGFloat, _ c2: CGFloat) -> CGFloat { c1 + (c2 - c1) * CGFloat(t) }
    let ua = UIColor(a), ub = UIColor(b)
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    ua.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    ub.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return Color(red: comp(r1, r2), green: comp(g1, g2), blue: comp(b1, b2)).opacity(comp(a1, a2))
}

/// Full-screen background stack: blurred artwork + hero crop + extracted-color
/// gradient + atmospheric lighting + subtle particles + vignette + beat pulse.
/// Energy-driven color evolution and section transitions animate slowly —
/// the screen never flashes, and notes always stay the brightest layer.
struct GameBackgroundView: View {
    let theme: SongBackgroundTheme
    let pulse: Double          // 0…1, follows strong detected beats
    let energy: Double         // 0…1 current section energy
    let sectionIndex: Int      // current section; changes evolve the tint
    let effects: VisualEffectLevel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var particlePositions: [Particle] = []
    @State private var bokehDots: [BokehDot] = []

    /// Everything that MOVES is gated behind this: with the system's Reduce
    /// Motion accessibility preference on, the environment is a calm,
    /// essentially static backdrop (colors still evolve with sections, but
    /// nothing drifts, breathes or pulses).
    private var motionAllowed: Bool { !reduceMotion && effects != .off }

    private struct Particle: Equatable {
        var x: Double
        var y: Double
        var radius: Double
        var speed: Double
        var opacity: Double
    }

    /// Soft light circles in the reference style (Piano Tiles 2 vibe):
    /// deterministic per song, drifting gently upward.
    private struct BokehDot: Equatable {
        var x: Double
        var y: Double
        var radius: Double
        var speed: Double
        var opacity: Double
    }

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.045, blue: 0.10)
            // Blurred artwork kept subtle so the bright reference gradient
            // stays dominant while the song still tints the room.
            if motionAllowed, let art = theme.blurredArtwork {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.26)
                    .scaleEffect(1.0 + 0.03 * pulse)
                    .accessibilityHidden(true)
            }
            // Hero layer: enlarged/cropped artwork, slowly reacting to energy.
            if effects != .off, let hero = theme.heroArtwork {
                Image(uiImage: hero)
                    .resizable()
                    .scaledToFill()
                    .opacity(reduceMotion ? 0.12 : 0.12 + 0.05 * energy)
                    .scaleEffect(reduceMotion ? 1.12 : 1.12 + 0.05 * energy)
                    .offset(y: reduceMotion ? 0 : CGFloat((energy - 0.5) * 10))
                    .accessibilityHidden(true)
            }
            // Reference-style wash: vivid blue at the top-left melting into
            // purple/pink at the bottom-right, blended with the song's own
            // extracted colors so every track keeps its own atmosphere.
            LinearGradient(colors: [washTop, washMid, washBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Accent ambience: color bleeds from the corners, more in lively sections.
            RadialGradient(colors: [theme.accent.opacity(0.16 + 0.10 * energy), .clear],
                           center: UnitPoint(x: 0.5, y: 0.22), startRadius: 40, endRadius: 420)
            // Soft readability base behind the playfield. Whisper-light: the
            // bright reference field must stay dominant.
            LinearGradient(colors: [.black.opacity(0.07), .clear, .black.opacity(0.10)],
                           startPoint: .top, endPoint: .bottom)
            // Vignette (restrained so the bright field stays bright).
            RadialGradient(colors: [.clear, .black.opacity(0.14)],
                           center: .center, startRadius: 170, endRadius: 520)
            // Reference bokeh: soft light dots, deterministic per song.
            if motionAllowed {
                bokehLayer
            }
            // Subtle particles (deterministic positions per song).
            if motionAllowed {
                particlesLayer
            }
            // Beat pulse: a restrained bloom on strong beats only.
            if motionAllowed, pulse > 0.02 {
                RadialGradient(colors: [theme.accent.opacity(0.30 * pulse), .clear],
                               center: UnitPoint(x: 0.5, y: 0.82),
                               startRadius: 10, endRadius: 500 * pulse + 140)
                Color(theme.accent).opacity(0.08 * pulse)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 1.4), value: sectionIndex)
        .animation(.easeInOut(duration: 0.9), value: energyRounded)
        .onAppear {
            if particlePositions.isEmpty {
                particlePositions = Self.makeParticles(seed: theme.particleSeed)
            }
            if bokehDots.isEmpty {
                bokehDots = Self.makeBokeh(seed: theme.particleSeed)
            }
        }
    }

    /// Reference palette (Piano Tiles 2-style): vivid blue melting into
    /// purple/pink. Song colors tint it (weighted strongly toward the
    /// reference so every chart gets the bright energetic field).
    private static let referenceTop = Color(red: 0.04, green: 0.55, blue: 1.0)
    private static let referenceMid = Color(red: 0.34, green: 0.42, blue: 0.95)
    private static let referenceBottom = Color(red: 0.95, green: 0.36, blue: 0.80)

    /// Section-aware gradient: quiet sections lean on the calm palette,
    /// high-energy sections on the vivid one — transitions are gradual.
    /// The reference blue→purple/pink field is the base; the song's own
    /// extracted colors tint it, and energy lifts it further.
    private var washTop: Color {
        // Reference-dominant: the song tints the field but never swallows it.
        Self.liftBrightness(mix(mix(Self.referenceTop, mix(theme.quietTop, theme.topColor, Double(sectionTint)), 0.26),
                               theme.energyTop, energy * 0.18), floor: 0.42)
    }

    private var washMid: Color {
        Self.liftBrightness(mix(mix(Self.referenceMid, theme.topColor, 0.20), theme.energyTop, energy * 0.16),
                            floor: 0.36)
    }

    private var washBottom: Color {
        Self.liftBrightness(mix(mix(Self.referenceBottom, theme.bottomColor, 0.32), theme.energyBottom, energy * 0.18),
                            floor: 0.30)
    }

    /// Raise a color's luma to at least `floor` (0…1) by pulling every
    /// channel toward white — the bright reference field must never be
    /// darkened by a dark song artwork.
    private static func liftBrightness(_ c: Color, floor: CGFloat) -> Color {
        let ui = UIColor(c)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard luma < floor else { return c }
        let lift = (floor - luma) / max(0.001, 1 - luma)
        return Color(red: r + (1 - r) * lift, green: g + (1 - g) * lift, blue: b + (1 - b) * lift)
            .opacity(a)
    }

    /// Deterministic 0/1 tint stepping so each new section slowly re-tints.
    private var sectionTint: Double {
        // Stable, deterministic function of the section index (no random).
        let h = (UInt64(bitPattern: Int64(sectionIndex)) &* 0x9E37_79B9_7F4A_7C15) >> 56
        return Double(h % 256) / 255
    }

    /// Quantized energy so gentle energy wobbles don't animate every frame.
    private var energyRounded: Double {
        (energy * 8).rounded() / 8
    }

    // MARK: - Particles

    private var particlesLayer: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let driftScale = 0.35 + 0.65 * energyRounded
                for p in particlePositions {
                    let y = (p.y + t * p.speed * driftScale).truncatingRemainder(dividingBy: 1)
                    let x = p.x
                    let rect = CGRect(x: x * size.width - p.radius,
                                      y: y * size.height - p.radius,
                                      width: p.radius * 2, height: p.radius * 2)
                    let alpha = p.opacity * (0.4 + 0.6 * energyRounded)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(theme.accent.opacity(alpha)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Deterministic per-song particle field (seeded) — same song, same field.
    private static func makeParticles(seed: UInt64) -> [Particle] {
        var rng = SplitMix64(state: seed &+ 0x51AB_51AB)
        return (0..<16).map { _ in
            Particle(x: rng.uniform(),
                     y: rng.uniform(),
                     radius: 1.2 + rng.uniform() * 2.4,
                     speed: 0.004 + rng.uniform() * 0.012,
                     opacity: 0.10 + rng.uniform() * 0.22)
        }
    }

    /// Deterministic per-song bokeh dots (seeded, distinct salt) — same song,
    /// same dots. Soft white light circles, sparse, drifting upward; the
    /// reference leans right-side, so dots are weighted that way.
    private static func makeBokeh(seed: UInt64) -> [BokehDot] {
        var rng = SplitMix64(state: seed &+ 0xB0BE_11A5)
        return (0..<18).map { _ in
            // x weighted toward the right half (0.55–0.98) with a few left.
            let x = rng.uniform() < 0.7 ? 0.55 + rng.uniform() * 0.43 : rng.uniform() * 0.4
            return BokehDot(x: x,
                            y: rng.uniform(),
                            radius: 14 + rng.uniform() * 52,
                            speed: 0.003 + rng.uniform() * 0.009,
                            opacity: 0.08 + rng.uniform() * 0.10)
        }
    }

    /// Soft white bokeh circles (reference look). Three concentric circles
    /// cheaply fake a radial falloff — no per-frame filters.
    private var bokehLayer: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                for dot in bokehDots {
                    let rawY = (dot.y - t * dot.speed).truncatingRemainder(dividingBy: 1)
                    let y = rawY < 0 ? rawY + 1 : rawY
                    let c = CGPoint(x: dot.x * size.width, y: y * size.height)
                    let r = dot.radius
                    context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                 with: .color(.white.opacity(dot.opacity * 0.30)))
                    context.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.62, y: c.y - r * 0.62,
                                                        width: r * 1.24, height: r * 1.24)),
                                 with: .color(.white.opacity(dot.opacity * 0.55)))
                    context.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.30, y: c.y - r * 0.30,
                                                        width: r * 0.60, height: r * 0.60)),
                                 with: .color(.white.opacity(dot.opacity)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}