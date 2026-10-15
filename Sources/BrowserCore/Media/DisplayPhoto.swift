import Foundation
import CoreImage
import ImageIO

public struct DisplayPhoto {
    public let image: CIImage
    public let metadata: PhotoMetadata?
    public let headroom: Float
    public let bitsPerComponent: Int
    public let colorSpaceName: String
    public let memoryCost: Int
    public var timing: DecodeTiming? = nil
    public var isHDR: Bool { headroom > 1.01 }
    public var size: CGSize { image.extent.size }
}

extension ThumbnailCache {
    /// Keep the source color profile and precision through to the floating point display surface.
    public func displayPhoto(_ file: PhotoFile, hdr: Bool, maximum: Int? = nil) async throws -> DisplayPhoto {
        // Yield this cache actor while decoding originals so cached thumbnails stay responsive.
        try await DisplayPhotoCache.shared.image(file, hdr: hdr, maximum: maximum)
    }
}

enum OriginalPhotoDecoder {
    static func decode(_ file: PhotoFile, hdr: Bool, maximum: Int?, queuedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
                       check: () throws -> Void) throws -> DisplayPhoto {
        try check()
        let started = ProcessInfo.processInfo.systemUptime
        guard let source = try PhotoMediaSource.open(file, check: check) else {
            throw BrowserFailure.message(L10n.text("无法读取原图：\(file.url.lastPathComponent)"))
        }
        var options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true,
                                       kCGImageSourceShouldAllowFloat: true,
                                       kCGImageSourceDecodeRequest: hdr ? kCGImageSourceDecodeToHDR : kCGImageSourceDecodeToSDR]
        let opened = ProcessInfo.processInfo.systemUptime
        let cg: CGImage?
        if let maximum {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = maximum
            // Rotate the CI image below so both paths use the same orientation handling.
            options[kCGImageSourceCreateThumbnailWithTransform] = false
            cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else { cg = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) }
        guard let cg else { throw BrowserFailure.message(L10n.text("系统无法解码 \(file.format) 原图。请切换同名格式，或在 Camera Raw 中打开。")) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let orientation = (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
        let sourceImage = CIImage(cgImage: cg, options: [.toneMapHDRtoSDR: !hdr])
        var image = sourceImage.oriented(forExifOrientation: orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        var headroom: Float = cg.colorSpace?.isHDR() == true ? 4 : 1
        if #available(macOS 15, *) { headroom = max(1, cg.contentHeadroom, sourceImage.contentHeadroom) }
        try check()
        return DisplayPhoto(image: image, metadata: ImageMetadataReader.read(source), headroom: headroom,
                            bitsPerComponent: cg.bitsPerComponent, colorSpaceName: cg.colorSpace?.name.map { $0 as String } ?? L10n.text("系统色彩配置"),
                            memoryCost: cg.bytesPerRow * cg.height,
                            timing: DecodeTiming(queue: (started - queuedAt) * 1000, source: (opened - started) * 1000,
                                                 decode: (ProcessInfo.processInfo.systemUptime - opened) * 1000))
    }
}
