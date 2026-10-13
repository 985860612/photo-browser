import AVFoundation
import CoreGraphics

enum VideoFixture {
    static func create(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        input.expectsMediaDataInRealTime = false
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        let limit = Date().addingTimeInterval(10)
        for n in 0..<20 {
            while !input.isReadyForMoreMediaData {
                guard Date() < limit else { writer.cancelWriting(); throw NSError(domain: "VideoFixture", code: 1) }
                try await Task.sleep(for: .milliseconds(10))
            }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                writer.cancelWriting(); throw NSError(domain: "VideoFixture", code: 2)
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 64, height: 48, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(red: 0.25, green: CGFloat(n + 1) / 20, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(n), timescale: 10)) else {
                writer.cancelWriting(); throw writer.error ?? NSError(domain: "VideoFixture", code: 3)
            }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "VideoFixture", code: 4) }
    }
}
