import AppKit
import ImageIO
import CoreImage
import CryptoKit

public struct LoadedPreview {
    public let image: NSImage
    public let metadata: PhotoMetadata?
}

public actor ThumbnailCache {
    public static let shared = ThumbnailCache()
    private let memory = NSCache<NSString, NSImage>()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var writes = 0
    private let directory: URL

    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoBrowser/Thumbnails", isDirectory: true)
        memory.countLimit = 160; memory.totalCostLimit = 180 * 1024 * 1024
    }

    public nonisolated static func digest(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Decode the original at native resolution; never substitute a camera's small embedded JPEG.
    public func fullResolution(_ file: PhotoFile) throws -> LoadedPreview {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              var cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw BrowserFailure.message("系统无法解码 \(file.format) 高清原图。请切换同名 HIF/JPG，或在 Camera Raw 中打开。")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let orientation = (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
        if orientation != 1 {
            let ci = CIImage(cgImage: cg).oriented(forExifOrientation: orientation)
            guard let rotated = context.createCGImage(ci, from: ci.extent) else { throw BrowserFailure.message("无法校正高清照片方向。") }
            cg = rotated
        }
        try Task.checkCancellation()
        return LoadedPreview(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), metadata: nativeMetadata(source))
    }

    public func image(_ file: PhotoFile, maximum: Int) throws -> LoadedPreview {
        try Task.checkCancellation()
        let key = Self.digest("v1|\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)|\(maximum)")
        let cachedURL = directory.appendingPathComponent(key + ".jpg")
        let metadataURL = directory.appendingPathComponent(key + ".json")
        var cachedMetadata: PhotoMetadata?
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            cachedMetadata = try JSONDecoder().decode(PhotoMetadata.self, from: Data(contentsOf: metadataURL))
        }
        if let cached = memory.object(forKey: key as NSString) { return LoadedPreview(image: cached, metadata: cachedMetadata) }
        if FileManager.default.fileExists(atPath: cachedURL.path), let image = NSImage(contentsOf: cachedURL) {
            memory.setObject(image, forKey: key as NSString)
            return LoadedPreview(image: image, metadata: cachedMetadata)
        }
        var source: CGImageSource?
        var orientation: Int32 = 1
        var embedded = false
        if file.kind == .raw, let binary = MetadataReader.executable {
            let p = Process(), pipe = Pipe()
            p.executableURL = binary; p.arguments = ["-fast", "-j", "-b", "-n", "-PreviewImage", "-Orientation", "--", file.url.path]
            p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            try p.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            if p.terminationStatus == 0,
               let objects = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]], let object = objects.first,
               let raw = object["PreviewImage"] as? String, raw.hasPrefix("base64:"),
               let data = Data(base64Encoded: String(raw.dropFirst(7))) {
                source = CGImageSourceCreateWithData(data as CFData, nil)
                orientation = (object["Orientation"] as? NSNumber)?.int32Value ?? 1
                embedded = true
            }
        }
        if source == nil { source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) }
        guard let source else { throw BrowserFailure.message("无法读取 \(file.url.lastPathComponent)") }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maximum,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard var cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw BrowserFailure.message("系统无法生成 \(file.format) 预览：\(file.url.lastPathComponent)。可切换同名其他格式或在 Finder 打开原文件。")
        }
        if embedded, orientation != 1 {
            let ci = CIImage(cgImage: cg).oriented(forExifOrientation: orientation)
            guard let rotated = context.createCGImage(ci, from: ci.extent) else { throw BrowserFailure.message("无法校正照片方向。") }
            cg = rotated
        }
        try Task.checkCancellation()
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        memory.setObject(image, forKey: key as NSString, cost: cg.width * cg.height * 4)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Cache writes are optional optimizations; decode failures are always reported.
        let mutable = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(mutable, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(destination) { try (mutable as Data).write(to: cachedURL, options: .atomic) }
        }
        let metadata = nativeMetadata(source)
        if let metadata { try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic) }
        writes += 1
        if writes % 100 == 0 { try trimCache() }
        return LoadedPreview(image: image, metadata: metadata)
    }

    nonisolated func nativeMetadata(_ source: CGImageSource) -> PhotoMetadata? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return nil }
        var value = PhotoMetadata()
        value.focalLength = (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue
        value.aperture = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue
        value.iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue
        if let seconds = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue {
            value.shutter = seconds < 1 && seconds > 0 ? "1/\(Int((1 / seconds).rounded()))" : String(format: "%.2f", seconds)
        }
        value.width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
        value.height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        value.camera = tiff?[kCGImagePropertyTIFFModel as String] as? String
        if let captured = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            value.captured = formatter.date(from: captured)
        }
        return value
    }

    private func trimCache() throws {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]).filter { $0.pathExtension == "jpg" }
        guard urls.count > 2000 else { return }
        let ordered = try urls.map { ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) }.sorted { $0.1 < $1.1 }
        for item in ordered.prefix(ordered.count - 1600) {
            try FileManager.default.removeItem(at: item.0)
            let companion = item.0.deletingPathExtension().appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: companion.path) { try FileManager.default.removeItem(at: companion) }
        }
    }
}
