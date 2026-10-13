import Foundation
import CoreImage
import ImageIO
import Metal
import BrowserCore

@main struct HDRCheck {
    static func main() async {
        do {
            let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
            let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoBrowser-HDR-Check-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var values: [Float] = []
            for _ in 0..<64 { values += [4, 4, 4, 1] }
            let data = values.withUnsafeBytes { Data($0) }
            var source = CIImage(bitmapData: data, bytesPerRow: 8 * 16, size: CGSize(width: 8, height: 8), format: .RGBAf, colorSpace: space)
            // Runtime availability alone cannot type-check APIs absent from an older SDK.
            #if compiler(>=6.2)
            if #available(macOS 26, *) { source = source.settingContentHeadroom(4) }
            #endif
            let url = directory.appendingPathComponent("highlights.heic")
            try context.writeHEIF10Representation(of: source, to: url, colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!, options: [:])
            let file = PhotoFile(url: url, kind: .rendered)
            let hdr = try await ThumbnailCache.shared.displayPhoto(file, hdr: true)
            let sdr = try await ThumbnailCache.shared.displayPhoto(file, hdr: false)
            func pixel(_ image: CIImage) -> Float {
                var rgba = [Float](repeating: 0, count: 4)
                rgba.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 3, y: 3, width: 1, height: 1), format: .RGBAf, colorSpace: space) }
                return rgba[0]
            }
            let high = pixel(hdr.image), standard = pixel(sdr.image)
            print("HDR headroom=\(hdr.headroom) bits=\(hdr.bitsPerComponent) pixel=\(high), SDR pixel=\(standard)")
            guard hdr.isHDR, high > 1.5, standard <= 1.01 else { throw BrowserFailure.message("HDR highlights or SDR tone mapping failed") }
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw BrowserFailure.message("Metal device unavailable") }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 8, height: 8, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else { throw BrowserFailure.message("Metal texture unavailable") }
            let metalContext = CIContext(mtlDevice: device, options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh])
            let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
            destination.colorSpace = space; destination.isFlipped = true
            _ = try metalContext.startTask(toRender: hdr.image, to: destination)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in continuation.resume() }; command.commit()
            }
            if let error = command.error { throw error }
            var pixels = [UInt16](repeating: 0, count: 8 * 8 * 4)
            pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 8 * 8, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0) }
            guard Float(Float16(bitPattern: pixels[0])) > 1.5 else { throw BrowserFailure.message("Metal clipped HDR highlights") }
            let top = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 4, width: 8, height: 4))
            let bottom = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 4))
            let orientationCommand = queue.makeCommandBuffer()!
            let orientationDestination = CIRenderDestination(mtlTexture: texture, commandBuffer: orientationCommand)
            orientationDestination.colorSpace = space; orientationDestination.isFlipped = true
            let background = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            _ = try metalContext.startTask(toRender: top.composited(over: bottom.composited(over: background)), to: orientationDestination)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                orientationCommand.addCompletedHandler { _ in continuation.resume() }; orientationCommand.commit()
            }
            pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 8 * 8, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0) }
            let firstRed = Float(Float16(bitPattern: pixels[0])), firstBlue = Float(Float16(bitPattern: pixels[2]))
            let lastRed = Float(Float16(bitPattern: pixels[7 * 8 * 4])), lastBlue = Float(Float16(bitPattern: pixels[7 * 8 * 4 + 2]))
            print("Metal first-row RGB=\(firstRed),…,\(firstBlue), last-row RGB=\(lastRed),…,\(lastBlue)")
            guard firstBlue > 0.6, firstBlue > firstRed * 2, lastRed > 0.6, lastRed > lastBlue * 2 else {
                throw BrowserFailure.message("Metal display flipped image orientation")
            }
            print("PASS HDR HEIC decode, SDR tone mapping, 16-bit float Metal highlights and display orientation")
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
}
