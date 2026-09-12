import Foundation

/// One RGB color in 0…1 space (pure — no UIKit).
struct RGB: Equatable, Sendable {
    let r: Double
    let g: Double
    let b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = min(1, max(0, r))
        self.g = min(1, max(0, g))
        self.b = min(1, max(0, b))
    }

    /// Rec.709 luma 0…1.
    var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// 0…1 saturation (max−min over max; 0 for achromatic).
    var saturation: Double {
        let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
        return maxC > 0.02 ? (maxC - minC) / maxC : 0
    }

    /// Warm/cool tendency: −1 (cool/blue) … +1 (warm/red-orange).
    var warmCool: Double { r - b }

    /// Hue in degrees 0…360 (0 red, 120 green, 240 blue); nil for achromatic.
    var hueDegrees: Double? {
        let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
        let delta = maxC - minC
        guard delta > 0.02 else { return nil }
        var h: Double
        if maxC == r { h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { h = 60 * ((b - r) / delta + 2) }
        else { h = 60 * ((r - g) / delta + 4) }
        if h < 0 { h += 360 }
        return h
    }

    /// Boosted for high-energy presentation (more saturation + lightness).
    /// Saturate first, then lift: lifting after saturation would dilute it.
    var energetic: RGB {
        saturated(by: 1.4).raised(by: 0.06)
    }

    /// Calmed for quiet sections (desaturated + slightly darkened).
    var quiet: RGB {
        let l = luma * 0.82
        let desat = 0.55
        return RGB(
            l + (r - l) * desat,
            l + (g - l) * desat,
            l + (b - l) * desat
        )
    }

    private func saturated(by factor: Double) -> RGB {
        let l = luma
        return RGB(
            l + (r - l) * factor,
            l + (g - l) * factor,
            l + (b - l) * factor
        )
    }

    private func raised(by delta: Double) -> RGB {
        RGB(r + delta, g + delta, b + delta)
    }
}

/// The analysis result for one artwork: dominant/secondary/accent colors plus
/// global brightness, saturation and warm/cool tendency. Everything is
/// deterministic — identical pixels always produce identical metrics.
struct ArtworkMetrics: Equatable, Sendable {
    let dominant: RGB
    let secondary: RGB
    let accent: RGB
    let brightness: Double   // 0…1 mean luma
    let saturation: Double   // 0…1 mean saturation
    let warmCool: Double     // −1…+1
}

/// Pure palette analysis over an RGBA pixel buffer (used by the theme factory;
/// kept UIKit-free so it is fully unit-testable).
enum ArtworkPaletteAnalyzer {
    /// Analyzes RGBA8 pixels. `width` is the row width; height is implied by
    /// the buffer length. Returns nil for empty/misaligned input.
    static func analyze(pixels: [UInt8], width: Int) -> ArtworkMetrics? {
        guard width > 0, pixels.count >= width * 4, pixels.count % 4 == 0 else { return nil }
        let count = pixels.count / 4
        let colors = (0..<count).map { i -> RGB in
            RGB(Double(pixels[i * 4]) / 255,
                Double(pixels[i * 4 + 1]) / 255,
                Double(pixels[i * 4 + 2]) / 255)
        }
        return analyze(colors: colors)
    }

    /// Analyzes an array of colors directly (tests can skip the buffer).
    static func analyze(colors: [RGB]) -> ArtworkMetrics? {
        guard !colors.isEmpty else { return nil }
        let brightness = colors.map(\.luma).reduce(0, +) / Double(colors.count)
        let saturation = colors.map(\.saturation).reduce(0, +) / Double(colors.count)
        let warmCool = colors.map(\.warmCool).reduce(0, +) / Double(colors.count)
        let (dominant, secondary) = dominantColors(colors)
        return ArtworkMetrics(dominant: dominant,
                              secondary: secondary,
                              accent: accent(colors),
                              brightness: brightness,
                              saturation: saturation,
                              warmCool: warmCool)
    }

    /// Most common hue-family (12 hue bins, deterministically weighted by
    /// saturation) and the runner-up family. All-achromatic input falls back
    /// to luminance-banded clusters so grayscale artwork still gets a theme.
    private static func dominantColors(_ colors: [RGB]) -> (RGB, RGB) {
        var hueSums = [Int: (r: Double, g: Double, b: Double, weight: Double)]()
        var lumaSums = [Int: (r: Double, g: Double, b: Double, weight: Double)]()
        for c in colors {
            if let h = c.hueDegrees {
                let bin = Int(h / 30) % 12
                let w = 0.35 + 0.65 * c.saturation
                var s = hueSums[bin] ?? (0, 0, 0, 0)
                s.r += c.r * w; s.g += c.g * w; s.b += c.b * w; s.weight += w
                hueSums[bin] = s
            }
            let lumaBin = min(3, Int(c.luma * 4))
            var ls = lumaSums[lumaBin] ?? (0, 0, 0, 0)
            ls.r += c.r; ls.g += c.g; ls.b += c.b; ls.weight += 1
            lumaSums[lumaBin] = ls
        }
        let hueCluster = hueSums.max { $0.value.weight < $1.value.weight }
        if let first = hueCluster {
            let dominant = average(of: first.value)
            // Runner-up: highest-weight hue bin that isn't adjacent to the
            // dominant one (avoids near-identical neighbors).
            let second = hueSums
                .filter { bin(_: $0.key, notAdjacentTo: first.key) }
                .max { $0.value.weight < $1.value.weight }
                .map { average(of: $0.value) }
            return (dominant, second ?? dominant.quiet)
        }
        // Achromatic: brightest vs. darkest luminance bands.
        let bright = lumaSums.filter { $0.key >= 2 }.max { $0.value.weight < $1.value.weight }
        let dark = lumaSums.filter { $0.key < 2 }.max { $0.value.weight < $1.value.weight }
        return (average(of: bright?.value ?? (0.2, 0.2, 0.2, 1)),
                average(of: dark?.value ?? (0.08, 0.08, 0.08, 1)))
    }

    private static func bin(_ a: Int, notAdjacentTo b: Int) -> Bool {
        let diff = abs(a - b)
        return diff > 1 && diff < 11
    }

    private static func average(of cluster: (r: Double, g: Double, b: Double, weight: Double)) -> RGB {
        guard cluster.weight > 0 else { return RGB(0.2, 0.2, 0.2) }
        return RGB(cluster.r / cluster.weight, cluster.g / cluster.weight, cluster.b / cluster.weight)
    }

    /// Most saturated pixel (drums/lead instruments often stand out); falls
    /// back to a warm-ish mid color for achromatic art.
    private static func accent(_ colors: [RGB]) -> RGB {
        let mostSaturated = colors.max { $0.saturation < $1.saturation } ?? RGB(0.3, 0.6, 1.0)
        if mostSaturated.saturation > 0.18 { return mostSaturated }
        let l = colors.map(\.luma).reduce(0, +) / Double(colors.count)
        return RGB(min(1, l + 0.25), min(1, l + 0.12), min(1, l + 0.35))
    }

    // MARK: - Fallback

    /// Deterministic fallback theme for songs without artwork: hue derived
    /// from the song seed (same song → same theme, no broken images ever).
    /// Bright values (0.5–0.6 range): the gameplay field is a vivid
    /// blue→purple/pink environment in the reference style, and near-black
    /// tiles need a bright field behind them to read.
    static func fallback(seed: UInt64) -> (top: RGB, bottom: RGB, accent: RGB) {
        var rng = SplitMix64(state: seed)
        let hue = rng.uniform() * 360
        let top = hsv(hue: hue, saturation: 0.62, value: 0.52)
        let bottom = hsv(hue: (hue + 40).truncatingRemainder(dividingBy: 360), saturation: 0.70, value: 0.42)
        let accent = hsv(hue: (hue + 180).truncatingRemainder(dividingBy: 360), saturation: 0.85, value: 0.9)
        return (top, bottom, accent)
    }

    private static func hsv(hue: Double, saturation: Double, value: Double) -> RGB {
        let c = value * saturation
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c
        let sector = Int(hue / 60) % 6
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return RGB(r + m, g + m, b + m)
    }
}