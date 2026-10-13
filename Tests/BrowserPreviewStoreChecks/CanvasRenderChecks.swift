import AppKit
import CoreImage
import Metal
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func canvasRenderChecks(root: URL) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BrowserFailure.message("Metal unavailable for canvas checks")
        }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let source = CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.7, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 6000, height: 4000))
        let url = root.appendingPathComponent("canvas.png")
        try CIContext().writePNGRepresentation(of: source, to: url, format: .RGBA8, colorSpace: space)
        let cache = DisplayPhotoCache(memoryBudget: 0), file = PhotoFile(url: url, kind: .rendered)
        let photo = try await cache.image(file, hdr: true)
        let browsing = try await cache.image(file, hdr: true, maximum: 2800)
        let canvas = CanvasView()
        canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        canvas.configure(photo: photo, identity: url.path, hdr: true, zoom: 1)
        // During resizing, a drawable may still be from the preceding surface size.
        // Every pixel in that actual surface must be written before it is presented.
        canvas.drawableSize = CGSize(width: 640, height: 480)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1536, height: 1024, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw BrowserFailure.message("Canvas texture unavailable") }
        let zero = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        zero.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
                                               withBytes: $0.baseAddress!, bytesPerRow: texture.width * 8) }
        guard let command = canvas.makeFrameCommandBuffer() else { throw BrowserFailure.message("Canvas command unavailable") }
        let sample = PreviewDiagnostics.shared.begin(file)
        PreviewDiagnostics.shared.loaded(sample, cached: false, timing: photo.timing)
        let drawStarted = ProcessInfo.processInfo.systemUptime
        try canvas.encodeFrame(to: texture, command: command)
        canvas.trackFrameMetrics(command, started: drawStarted)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }; command.commit()
        }
        if let error = command.error { throw error }
        try expect(PreviewDiagnostics.shared.snapshot().samples.last(where: { $0.id == sample })?.render != nil,
                   "render diagnostics complete only after the actual Metal command buffer finishes")
        for y in stride(from: 16, to: texture.height, by: 128) {
            for x in stride(from: 16, to: texture.width, by: 128) {
                var pixel = [UInt16](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes {
                    texture.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
                }
                guard Float(Float16(bitPattern: pixel[0])) > 0.1 else {
                    throw BrowserFailure.message("Canvas left a black block at (\(x), \(y))")
                }
            }
        }
        try expect(true, "canvas writes the entire actual drawable when its size differs from the requested size")
        for index in 0..<12 {
            let empty = index % 4 == 0
            canvas.frame = CGRect(x: 0, y: 0, width: index % 2 == 0 ? 600 : 640, height: 400)
            canvas.drawableSize = CGSize(width: 1024, height: 768)
            canvas.configure(photo: empty ? nil : (index % 2 == 0 ? photo : browsing), identity: "frame-\(index)",
                             hdr: index % 3 == 0, zoom: index % 2 == 0 ? 1 : 2)
            guard let next = canvas.makeFrameCommandBuffer() else { throw BrowserFailure.message("Canvas command unavailable") }
            try canvas.encodeFrame(to: texture, command: next)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                next.addCompletedHandler { _ in continuation.resume() }; next.commit()
            }
            if let error = next.error { throw error }
            for point in [(16, 16), (1500, 16), (16, 1000), (1500, 1000), (768, 512)] {
                var pixel = [UInt16](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes {
                    texture.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(point.0, point.1, 1, 1), mipmapLevel: 0)
                }
                let red = Float(Float16(bitPattern: pixel[0]))
                guard empty ? red < 0.001 : red > 0.1 else { throw BrowserFailure.message("Incomplete canvas frame \(index)") }
            }
        }
        try expect(true, "switching preview resolutions, zoom, HDR mode and view size fully rewrites reused pixels; empty selections clear the surface")
    }
}
