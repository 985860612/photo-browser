import AppKit
import ImageIO
import BrowserCore

extension ThumbnailChecks {
    static func networkReaderChecks() throws {
        func require(_ value: Bool, _ label: String) throws {
            guard value else { throw BrowserFailure.message(label) }; print("PASS " + label)
        }
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("NetworkReader-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("oriented.JPG")
        let context = CGContext(data: nil, width: 100, height: 60, bitsPerComponent: 8, bytesPerRow: 400,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        let output = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Network Reader Fixture"]] as CFDictionary)
        try require(CGImageDestinationFinalize(output), "network fixture writes")
        let original = try Data(contentsOf: url), file = PhotoFile(url: url, kind: .rendered, size: Int64(original.count))
        let native = try NetworkPhotoReader.open(file, buffered: false)!, buffered = try NetworkPhotoReader.open(file, buffered: true)!
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 520, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        let a = CGImageSourceCreateThumbnailAtIndex(native, 0, options)!, b = CGImageSourceCreateThumbnailAtIndex(buffered, 0, options)!
        try require(a.width == 60 && a.height == 100 && a.width == b.width && a.height == b.height
                    && CFEqual(a.dataProvider!.data!, b.dataProvider!.data!), "buffered and URL JPEG readers preserve oriented pixels and preview resolution")
        try require(ImageMetadataReader.read(buffered)?.camera == "Network Reader Fixture", "buffered JPEGs retain original metadata")
        let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 0, count: NetworkPhotoReader.maximumBufferedBytes + 1)); try handle.close()
        var checks = 0
        do {
            _ = try NetworkPhotoReader.open(file, buffered: true) { checks += 1; if checks == 4 { throw CancellationError() } }
            throw BrowserFailure.message("cancelled buffered read succeeded")
        } catch is CancellationError { try require(checks == 4, "buffered network reading checks cancellation between chunks") }
        let grown = try NetworkPhotoReader.open(file, buffered: true)!
        try require(CGImageSourceCreateThumbnailAtIndex(grown, 0, options)?.width == 60, "a JPEG growing beyond the buffer ceiling falls back without losing its preview")
        try original.write(to: url)
        try require(try Data(contentsOf: url) == original, "network reading leaves original bytes unchanged")
        do {
            _ = try NetworkPhotoReader.open(PhotoFile(url: root.appendingPathComponent("missing.jpg"), kind: .rendered), buffered: true)
            throw BrowserFailure.message("missing buffered source succeeded")
        } catch is CocoaError { print("PASS missing network source reports its read error") }
    }
}
