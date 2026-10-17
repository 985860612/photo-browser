import AppKit
import CoreImage
import Metal
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func focusRenderChecks(root: URL) async throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let image = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.4, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let url = root.appendingPathComponent("focus-canvas.png")
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: space)
        let photo = try await DisplayPhotoCache(memoryBudget: 0).image(PhotoFile(url: url, kind: .rendered), hdr: true)
        let canvas = CanvasView()
        canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        canvas.drawableSize = CGSize(width: 400, height: 300)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1200, height: 800, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .shared
        guard let texture = canvas.device?.makeTexture(descriptor: descriptor) else { throw BrowserFailure.message("Focus texture unavailable") }
        let region = FocusRegion(rect: CGRect(x: 0.4, y: 0.35, width: 0.2, height: 0.2), kind: .inFocus)

        func render() async throws {
            guard let command = canvas.makeFrameCommandBuffer() else { throw BrowserFailure.message("Focus render command unavailable") }
            try canvas.encodeFrame(to: texture, command: command)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in done.resume() }; command.commit()
            }
            if let error = command.error { throw error }
        }
        func pixel(_ x: Int, _ y: Int) -> [Float] {
            var value = [UInt16](repeating: 0, count: 4)
            value.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0) }
            return value.map { Float(Float16(bitPattern: $0)) }
        }
        func red(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y); return p[0] > 0.6 && p[0] > p[1] * 3
        }
        canvas.configure(photo: photo, identity: "focus", hdr: true, zoom: 1, focusRegions: [region])
        try await render()
        try expect(red(600, 280) && !red(600, 400), "Focus border uses top-left normalized coordinates and does not fill the frame")
        try expect(red(600, 281) && !red(600, 287), "Focus line width follows Retina scale rather than image resolution")
        canvas.configure(photo: photo, identity: "focus", hdr: false, zoom: 2, focusRegions: [region])
        try await render()
        try expect(red(600, 160) && !red(600, 280), "Focus frame tracks zoom and survives switching HDR display mode")
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 1, clickCount: 1, pressure: 0.5)!
        }
        canvas.mouseDown(with: event(.leftMouseDown, CGPoint(x: 300, y: 200)))
        canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 330, y: 220)))
        canvas.mouseUp(with: event(.leftMouseUp, CGPoint(x: 330, y: 220)))
        try await render()
        try expect(red(660, 120) && !red(600, 160), "Focus overlay follows drag pan using the same image transform")
        canvas.configure(photo: photo, identity: "focus", hdr: false, zoom: 2)
        try await render()
        try expect(!red(660, 120), "Turning the focus switch off clears a reused Metal surface without reloading its photo")
        for kind in [FocusRegion.Kind.selected, .recorded] {
            canvas.configure(photo: photo, identity: "colors", hdr: true, zoom: 1, focusRegions: [FocusRegion(rect: region.rect, kind: kind)])
            try await render()
            let color = pixel(600, 280)
            try expect(kind == .selected ? color[0] > 0.6 && color[1] > 0.4 && color[2] < 0.1
                       : color[0] < color[2] * 0.35 && color[1] > 0.4 && color[2] > 0.6, "Selected and recorded focus regions retain distinct legend colors: \(kind), \(color)")
        }
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh])
        let values = Array(repeating: [Float(4), 4, 4, 1], count: 64).flatMap { $0 }
        let bytes = values.withUnsafeBytes { Data($0) }
        var highlights = CIImage(bitmapData: bytes, bytesPerRow: 8 * 16, size: CGSize(width: 8, height: 8), format: .RGBAf, colorSpace: space)
            .transformed(by: CGAffineTransform(scaleX: 75, y: 50))
        #if compiler(>=6.2)
        if #available(macOS 26, *) { highlights = highlights.settingContentHeadroom(4) }
        #endif
        let hdrURL = root.appendingPathComponent("focus-highlights.heic")
        try context.writeHEIF10Representation(of: highlights, to: hdrURL, colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!, options: [:])
        let hdr = try await DisplayPhotoCache(memoryBudget: 0).image(PhotoFile(url: hdrURL, kind: .rendered), hdr: true)
        try expect(hdr.isHDR, "Focus overlay fixture has real HDR headroom")
        for enabled in [true, false] {
            canvas.configure(photo: hdr, identity: "hdr-focus", hdr: enabled, zoom: 1, focusRegions: [region])
            try await render()
            try expect(red(600, 280), "Focus border stays visible after HDR tone mapping with HDR switch \(enabled)")
        }
        canvas.configure(photo: nil, identity: "empty", hdr: true, zoom: 1, focusRegions: [region])
        try await render()
        try expect(pixel(600, 280)[0] < 0.001, "No focus rectangles remain when no image is displayed")
    }
}
