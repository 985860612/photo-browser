import AppKit
import ImageIO
import CoreImage

public struct LoadedPreview {
    public let image: NSImage
    public let metadata: PhotoMetadata?
}

/// Synchronous pixel work; callers run it on their bounded decoding queue.
enum ThumbnailImageDecoder {
    static func fullResolution(_ file: PhotoFile, check: () throws -> Void) throws -> LoadedPreview {
        let context = CIContext(options: [.cacheIntermediates: false])
        try check()
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              var cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw BrowserFailure.message(L10n.text("系统无法解码 \(file.format) 高清原图。请切换同名 HIF/JPG，或在 Camera Raw 中打开。"))
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let orientation = (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
        if orientation != 1 {
            let ci = CIImage(cgImage: cg).oriented(forExifOrientation: orientation)
            guard let rotated = context.createCGImage(ci, from: ci.extent) else { throw BrowserFailure.message(L10n.text("无法校正高清照片方向。")) }
            cg = rotated
        }
        try check()
        return LoadedPreview(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), metadata: ImageMetadataReader.read(source))
    }

    static func readCached(key: String, directory: URL, check: () throws -> Void) throws -> LoadedPreview? {
        try check()
        let cachedURL = directory.appendingPathComponent(key + ".jpg")
        let metadataURL = directory.appendingPathComponent(key + ".json")
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            // Force JPEG decoding here, so drawing the NSImage never reads/decompresses on the UI thread.
            let bytes = try Data(contentsOf: cachedURL)
            if let source = CGImageSourceCreateWithData(bytes as CFData, nil),
               let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                var metadata: PhotoMetadata?
                if FileManager.default.fileExists(atPath: metadataURL.path) {
                    let data = try Data(contentsOf: metadataURL)
                    do { metadata = try JSONDecoder().decode(PhotoMetadata.self, from: data) }
                    catch is DecodingError { /* Older/corrupt metadata must not hide a valid cached image. */ }
                }
                try check()
                return LoadedPreview(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), metadata: metadata)
            }
        }
        return nil
    }

    static func saveVideo(_ preview: LoadedPreview, key: String, disk: ThumbnailDiskStore, token: UUID,
                                             check: () throws -> Void) throws -> LoadedPreview {
        try check()
        var rect = CGRect(origin: .zero, size: preview.image.size)
        guard let cg = preview.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw BrowserFailure.message(L10n.text("无法保存视频封面"))
        }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw BrowserFailure.message(L10n.text("无法保存视频封面"))
        }
        CGImageDestinationAddImage(output, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw BrowserFailure.message(L10n.text("无法保存视频封面")) }
        try check()
        try disk.write(data as Data, key: key, suffix: ".jpg", token: token)
        if let metadata = preview.metadata {
            try disk.write(JSONEncoder().encode(metadata), key: key, suffix: ".json", token: token)
        }
        try check()
        return preview
    }

    static func readOrGenerate(_ file: PhotoFile, maximum: Int, key: String,
                                                   directory: URL, disk: ThumbnailDiskStore, token: UUID, check: () throws -> Void) throws -> LoadedPreview {
        if let saved = try disk.read({ try readCached(key: key, directory: directory, check: check) }) { return saved }
        var source: CGImageSource?
        var orientation: Int32 = 1
        var embedded = false
        if file.kind == .raw, let binary = MetadataReader.executable {
            let p = Process(), pipe = Pipe()
            p.executableURL = binary; p.arguments = ["-fast", "-j", "-b", "-n", "-PreviewImage", "-Orientation", "--", file.url.path]
            p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            try p.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            try check()
            if p.terminationStatus == 0,
               let objects = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]], let object = objects.first,
               let raw = object["PreviewImage"] as? String, raw.hasPrefix("base64:"),
               let data = Data(base64Encoded: String(raw.dropFirst(7))) {
                source = CGImageSourceCreateWithData(data as CFData, nil)
                orientation = (object["Orientation"] as? NSNumber)?.int32Value ?? 1
                embedded = true
            }
        }
        if source == nil { source = try NetworkPhotoReader.open(file, check: check) }
        guard let source else { throw BrowserFailure.message(L10n.text("无法读取 \(file.url.lastPathComponent)")) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maximum,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard var cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw BrowserFailure.message(L10n.text("系统无法生成 \(file.format) 预览：\(file.url.lastPathComponent)。可切换同名其他格式或在 Finder 打开原文件。"))
        }
        if embedded, orientation != 1 {
            let context = CIContext(options: [.cacheIntermediates: false])
            let ci = CIImage(cgImage: cg).oriented(forExifOrientation: orientation)
            guard let rotated = context.createCGImage(ci, from: ci.extent) else { throw BrowserFailure.message(L10n.text("无法校正照片方向。")) }
            cg = rotated
        }
        try check()
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutable, "public.jpeg" as CFString, 1, nil) else {
            throw BrowserFailure.message(L10n.text("无法创建预览缓存：\(file.url.lastPathComponent)"))
        }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BrowserFailure.message(L10n.text("无法保存预览缓存：\(file.url.lastPathComponent)")) }
        try check()
        try disk.write(mutable as Data, key: key, suffix: ".jpg", token: token)
        try check()
        let metadata = ImageMetadataReader.read(source)
        if let metadata { try disk.write(JSONEncoder().encode(metadata), key: key, suffix: ".json", token: token) }
        return LoadedPreview(image: image, metadata: metadata)
    }

}
