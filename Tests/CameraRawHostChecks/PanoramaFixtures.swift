// Deterministic overlapping image fixtures; no user photographs are read or modified.
import AppKit
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let context = CGContext(data: nil, width: 1280, height: 512, bitsPerComponent: 8, bytesPerRow: 1280 * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
var seed: UInt64 = 7654321
func next() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 32) / CGFloat(UInt32.max)
}
context.setFillColor(CGColor(gray: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1280, height: 512))
for _ in 0..<1500 {
    context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
    let rect = CGRect(x: next() * 1260, y: next() * 492, width: 5 + next() * 25, height: 5 + next() * 25)
    context.fillEllipse(in: rect)
}
let whole = context.makeImage()!
for index in 0..<3 {
    let image = whole.cropping(to: CGRect(x: index * 256, y: 0, width: 768, height: 512))!
    let url = output.appendingPathComponent("overlap-\(index + 1).tif")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)!
    let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifFocalLength: 35,
        kCGImagePropertyExifFocalLenIn35mmFilm: 35, kCGImagePropertyExifExposureTime: 0.008,
        kCGImagePropertyExifFNumber: 8, kCGImagePropertyExifISOSpeedRatings: [100]]]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    print(url.path)
}
