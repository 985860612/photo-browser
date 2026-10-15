import AppKit
import Foundation

guard CommandLine.arguments.count > 1 else { exit(1) }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let outer = NSBezierPath(roundedRect: NSRect(x: 34, y: 34, width: 956, height: 956), xRadius: 205, yRadius: 205)
let gradient = NSGradient(starting: NSColor(red: 0.1, green: 0.28, blue: 0.43, alpha: 1), ending: NSColor(red: 0.025, green: 0.1, blue: 0.2, alpha: 1))!
gradient.draw(in: outer, angle: -55)
for (offset, alpha) in [(105.0, 0.18), (55.0, 0.36), (0.0, 1.0)] {
    let card = NSBezierPath(roundedRect: NSRect(x: 210 + offset, y: 230 + offset, width: 520, height: 390), xRadius: 38, yRadius: 38)
    NSColor.white.withAlphaComponent(alpha).setFill(); card.fill()
}
let inside = NSRect(x: 237, y: 257, width: 466, height: 336)
let clip = NSBezierPath(roundedRect: inside, xRadius: 19, yRadius: 19)
NSGraphicsContext.saveGraphicsState(); clip.addClip()
NSColor(red: 0.035, green: 0.43, blue: 0.7, alpha: 1).setFill(); inside.fill()
let mountains = NSBezierPath()
mountains.move(to: NSPoint(x: 237, y: 257)); mountains.line(to: NSPoint(x: 237, y: 342))
mountains.line(to: NSPoint(x: 385, y: 483)); mountains.line(to: NSPoint(x: 502, y: 377))
mountains.line(to: NSPoint(x: 573, y: 438)); mountains.line(to: NSPoint(x: 703, y: 323)); mountains.line(to: NSPoint(x: 703, y: 257)); mountains.close()
NSColor(red: 0.65, green: 0.91, blue: 0.98, alpha: 1).setFill(); mountains.fill()
NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 566, y: 494, width: 61, height: 61)).fill()
NSGraphicsContext.restoreGraphicsState()
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let original = NSBitmapImageRep(data: tiff), let cg = original.cgImage else { exit(1) }
for (name, pixels) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.cgContext.interpolationQuality = .high
    NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(name).png"))
}
