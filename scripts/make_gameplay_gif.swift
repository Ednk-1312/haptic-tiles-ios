import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Usage: mkgif <input.mp4> <output.gif> <startSec> <endSec> <fps> <width>
let args = CommandLine.arguments
guard args.count >= 6 else {
    FileHandle.standardError.write("usage: mkgif in.mp4 out.gif start end fps width\n".data(using: .utf8)!)
    exit(2)
}
let input = args[1], output = args[2]
let start = Double(args[3]) ?? 0
let end = Double(args[4]) ?? 10
let fps = Double(args[5]) ?? 8
let targetW = Int(args[6]) ?? 270

let url = URL(fileURLWithPath: input)
let asset = AVURLAsset(url: url)

let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
gen.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
gen.maximumSize = CGSize(width: targetW, height: targetW * 3)

var frames: [(CGImage, Double)] = []
var t = start
while t < end {
    let time = CMTime(seconds: t, preferredTimescale: 600)
    do {
        let img = try gen.copyCGImage(at: time, actualTime: nil)
        frames.append((img, t))
    } catch {
        FileHandle.standardError.write("frame error at \(t): \(error)\n".data(using: .utf8)!)
    }
    t += 1.0 / fps
}
print("extracted \(frames.count) frames")

func stats(_ img: CGImage) -> (Double, Double) {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var sum = 0.0, sumSq = 0.0
    let n = w * h
    for i in stride(from: 0, to: n * 4, by: 16) { // sample every 4th pixel
        let lum = 0.299 * Double(px[i]) + 0.587 * Double(px[i+1]) + 0.114 * Double(px[i+2])
        sum += lum; sumSq += lum * lum
    }
    let m = sum / Double(n / 4)
    let varr = sumSq / Double(n / 4) - m * m
    return (m, varr.squareRoot())
}

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                           UTType.gif.identifier as CFString, frames.count, nil)
// Extracts real gameplay frames from a `simctl recordVideo` capture and encodes them as an animated GIF.
// See README "Media" for usage.
guard let dest else { print("ERROR: cannot create gif destination"); exit(1) }
let delay = 1.0 / fps
for (img, at) in frames {
    let (m, sd) = stats(img)
    print(String(format: "frame @%.2fs lum=%.1f sd=%.1f", at, m, sd))
    CGImageDestinationAddImage(dest, img, [
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay
        ]
    ] as CFDictionary)
}
CGImageDestinationFinalize(dest)
print("wrote \(output)")
