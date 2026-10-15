import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/create-icon.swift <output.iconset>\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func gradient(_ path: NSBezierPath, _ colors: [NSColor], angle: CGFloat = 90) {
    NSGradient(colors: colors)!.draw(in: path, angle: angle)
}

func shape(_ points: [NSPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: points[0])
    points.dropFirst().forEach { path.line(to: $0) }
    path.close()
    return path
}

/// Draw each output size directly; strengthen the brackets and sun at small sizes.
func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setShouldAntialias(true)
    let small = pixels <= 32
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x071B46, 0.28)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x245DB7).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    gradient(tile, [color(0x102C68), color(0x366BE3), color(0x759BF6)], angle: 72)
    let glow = NSGradient(colors: [color(0xC1DCFF, 0.5), color(0xC1DCFF, 0)])!
    glow.draw(fromCenter: NSPoint(x: 205, y: 940), radius: 0,
              toCenter: NSPoint(x: 205, y: 940), radius: 850, options: [])

    let sunSize: CGFloat = small ? 156 : 132
    let sun = NSBezierPath(ovalIn: NSRect(x: 628 - sunSize / 2, y: 696 - sunSize / 2, width: sunSize, height: sunSize))
    NSGraphicsContext.saveGraphicsState()
    let sunShadow = NSShadow()
    sunShadow.shadowColor = color(0xFFD189, 0.3)
    sunShadow.shadowBlurRadius = 36
    sunShadow.shadowOffset = .zero
    sunShadow.set()
    gradient(sun, [color(0xFFB766), color(0xFFE3A1)], angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    let distant = shape([NSPoint(x: -40, y: 140), NSPoint(x: -40, y: 297),
                         NSPoint(x: 235, y: 548), NSPoint(x: 450, y: 341),
                         NSPoint(x: 683, y: 568), NSPoint(x: 1064, y: 240), NSPoint(x: 1064, y: 0)])
    gradient(distant, [color(0x1961A4), color(0x71CDE3)], angle: 100)

    let mountain = shape([NSPoint(x: 0, y: 0), NSPoint(x: 0, y: 225), NSPoint(x: 410, y: 624),
                          NSPoint(x: 700, y: 328), NSPoint(x: 1024, y: 130), NSPoint(x: 1024, y: 0)])
    gradient(mountain, [color(0x087FA1), color(0x4AE1D1)], angle: 105)
    let shadedFace = shape([NSPoint(x: 410, y: 624), NSPoint(x: 700, y: 328),
                            NSPoint(x: 1024, y: 130), NSPoint(x: 1024, y: 0), NSPoint(x: 563, y: 0)])
    gradient(shadedFace, [color(0x075C8E), color(0x26B7C3)], angle: 120)

    let foreground = NSBezierPath()
    foreground.move(to: NSPoint(x: -20, y: 0)); foreground.line(to: NSPoint(x: -20, y: 174))
    foreground.curve(to: NSPoint(x: 524, y: 232), controlPoint1: NSPoint(x: 196, y: 316), controlPoint2: NSPoint(x: 316, y: 126))
    foreground.curve(to: NSPoint(x: 1044, y: 268), controlPoint1: NSPoint(x: 780, y: 365), controlPoint2: NSPoint(x: 863, y: 219))
    foreground.line(to: NSPoint(x: 1044, y: 0)); foreground.close()
    gradient(foreground, [color(0x075586), color(0x128FB2)], angle: 75)

    // Open viewfinder corners leave the landscape unobstructed.
    let bounds = NSRect(x: 220, y: 230, width: 584, height: 568)
    let corner: CGFloat = 44, arm: CGFloat = small ? 112 : 102
    for (x, y, dx, dy) in [(bounds.minX, bounds.minY, 1.0, 1.0),
                           (bounds.maxX, bounds.minY, -1.0, 1.0),
                           (bounds.minX, bounds.maxY, 1.0, -1.0),
                           (bounds.maxX, bounds.maxY, -1.0, -1.0)] {
        let bracket = NSBezierPath()
        bracket.move(to: NSPoint(x: x, y: y + dy * arm))
        bracket.line(to: NSPoint(x: x, y: y + dy * corner))
        bracket.curve(to: NSPoint(x: x + dx * corner, y: y),
                      controlPoint1: NSPoint(x: x, y: y + dy * corner * 0.45),
                      controlPoint2: NSPoint(x: x + dx * corner * 0.45, y: y))
        bracket.line(to: NSPoint(x: x + dx * arm, y: y))
        bracket.lineWidth = small ? 42 : 28
        bracket.lineCapStyle = .round
        color(0xFFFFFF, 0.97).setStroke(); bracket.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    let edge = NSBezierPath(roundedRect: NSRect(x: 65.5, y: 65.5, width: 893, height: 893), xRadius: 201, yRadius: 201)
    edge.lineWidth = 3
    color(0xFFFFFF, 0.25).setStroke(); edge.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                       ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                       ("512x512", 512), ("512x512@2x", 1024)] {
    try drawIcon(pixels: pixels).representation(using: .png, properties: [:])!
        .write(to: output.appendingPathComponent("icon_\(name).png"))
}
