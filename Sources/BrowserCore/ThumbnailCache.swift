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
    private final class Entry: NSObject {
        let preview: LoadedPreview
        init(_ preview: LoadedPreview) { self.preview = preview }
    }
    private struct Pending {
        let ticket: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<LoadedPreview, Error>]
        var keepInMemory: Bool
    }
    private let memory = NSCache<NSString, Entry>()
    private var pending: [String: Pending] = [:]
    private let directory: URL
    private let workers: PreviewWorkQueue

    public init(directory: URL? = nil, workers: PreviewWorkQueue = .shared) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoBrowser/Thumbnails", isDirectory: true)
        self.workers = workers
        memory.countLimit = 160; memory.totalCostLimit = 180 * 1024 * 1024
    }

    public nonisolated static func digest(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
    private nonisolated static func key(_ file: PhotoFile, maximum: Int) -> String {
        Self.digest("\(file.kind == .video ? "video-v1" : "v1")|\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)|\(maximum)")
    }

    /// Decode the original at native resolution; never substitute a camera's small embedded JPEG.
    public nonisolated func fullResolution(_ file: PhotoFile) async throws -> LoadedPreview {
        try await workers.run { check in
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
            return LoadedPreview(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), metadata: self.nativeMetadata(source))
        }
    }

    /// Visible requests share the same decode with prefetch, but only visible images enter RAM.
    public func image(_ file: PhotoFile, maximum: Int, background: Bool = false) async throws -> LoadedPreview {
        try Task.checkCancellation()
        let key = Self.key(file, maximum: maximum)
        if let cached = memory.object(forKey: key as NSString) { return cached.preview }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var current = pending[key] {
                    current.waiters[waiter] = continuation
                    current.keepInMemory = current.keepInMemory || !background
                    pending[key] = current
                    return
                }
                let ticket = UUID(), directory = directory, workers = workers
                let task = Task {
                    let result: Result<LoadedPreview, Error>
                    do {
                        let preview: LoadedPreview
                        if file.kind == .video {
                            let saved = try await workers.run(background: background) { check in
                                try Self.readCached(key: key, directory: directory, check: check)
                            }
                            if let saved { preview = saved }
                            else {
                                let generated = try await VideoMedia.preview(file, maximum: maximum, background: background)
                                preview = try await workers.run(background: background) { check in
                                    try Self.saveVideo(generated, key: key, directory: directory, check: check)
                                }
                            }
                        } else {
                            preview = try await workers.run(background: background) { check in
                                try Self.readOrGenerate(file, maximum: maximum, key: key, directory: directory, check: check)
                            }
                        }
                        result = .success(preview)
                    } catch { result = .failure(error) }
                    finish(key, ticket: ticket, result: result)
                }
                pending[key] = Pending(ticket: ticket, task: task, waiters: [waiter: continuation], keepInMemory: !background)
            }
        } onCancel: {
            Task { await self.cancel(key, waiter: waiter) }
        }
    }

    private func cancel(_ key: String, waiter: UUID) {
        guard var current = pending[key], let continuation = current.waiters.removeValue(forKey: waiter) else { return }
        if current.waiters.isEmpty { pending.removeValue(forKey: key); current.task.cancel() }
        else { pending[key] = current }
        continuation.resume(throwing: CancellationError())
    }

    private func finish(_ key: String, ticket: UUID, result: Result<LoadedPreview, Error>) {
        guard let current = pending[key], current.ticket == ticket else { return }
        pending.removeValue(forKey: key)
        if case .success(let preview) = result, current.keepInMemory {
            memory.setObject(Entry(preview), forKey: key as NSString,
                             cost: Int(preview.image.size.width * preview.image.size.height) * 4)
        }
        current.waiters.values.forEach { $0.resume(with: result) }
    }

    private nonisolated static func readCached(key: String, directory: URL, check: () throws -> Void) throws -> LoadedPreview? {
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

    private nonisolated static func saveVideo(_ preview: LoadedPreview, key: String, directory: URL,
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (data as Data).write(to: directory.appendingPathComponent(key + ".jpg"), options: .atomic)
        if let metadata = preview.metadata {
            try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
        }
        try check()
        return preview
    }

    private nonisolated static func readOrGenerate(_ file: PhotoFile, maximum: Int, key: String,
                                                   directory: URL, check: () throws -> Void) throws -> LoadedPreview {
        if let saved = try readCached(key: key, directory: directory, check: check) { return saved }
        let cachedURL = directory.appendingPathComponent(key + ".jpg"), metadataURL = directory.appendingPathComponent(key + ".json")
        let context = CIContext(options: [.cacheIntermediates: false])
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
        if source == nil { source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) }
        guard let source else { throw BrowserFailure.message(L10n.text("无法读取 \(file.url.lastPathComponent)")) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maximum,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard var cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw BrowserFailure.message(L10n.text("系统无法生成 \(file.format) 预览：\(file.url.lastPathComponent)。可切换同名其他格式或在 Finder 打开原文件。"))
        }
        if embedded, orientation != 1 {
            let ci = CIImage(cgImage: cg).oriented(forExifOrientation: orientation)
            guard let rotated = context.createCGImage(ci, from: ci.extent) else { throw BrowserFailure.message(L10n.text("无法校正照片方向。")) }
            cg = rotated
        }
        try check()
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutable, "public.jpeg" as CFString, 1, nil) else {
            throw BrowserFailure.message(L10n.text("无法创建预览缓存：\(file.url.lastPathComponent)"))
        }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BrowserFailure.message(L10n.text("无法保存预览缓存：\(file.url.lastPathComponent)")) }
        try check()
        try (mutable as Data).write(to: cachedURL, options: .atomic)
        try check()
        let metadata = ThumbnailCache.shared.nativeMetadata(source)
        if let metadata { try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic) }
        return LoadedPreview(image: image, metadata: metadata)
    }

    /// Maintenance also uses the utility lane; never blocks memory hits or visible decoding.
    public func trim(protecting files: [PhotoFile] = [], maximum: Int = 520) async throws {
        let protected = Set(files.map { Self.key($0, maximum: maximum) })
            .union(pending.keys)
        try await workers.run(background: true) { check in
            try check()
            try Self.trimCache(self.directory, protecting: protected, check: check)
        }
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

    private nonisolated static func trimCache(_ directory: URL, protecting protected: Set<String>, check: () throws -> Void) throws {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]).filter { $0.pathExtension == "jpg" }
        guard urls.count > 2000 else { return }
        let ordered = try urls.map { ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) }.sorted { $0.1 < $1.1 }
        let removable = ordered.filter { !protected.contains($0.0.deletingPathExtension().lastPathComponent) }
        for item in removable.prefix(max(0, ordered.count - max(1600, protected.count))) {
            try check()
            try FileManager.default.removeItem(at: item.0)
            let companion = item.0.deletingPathExtension().appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: companion.path) { try FileManager.default.removeItem(at: companion) }
        }
    }
}
