import AppKit
import ImageIO

struct BackgroundWorkOutput: Sendable {
    var preview: URL?
    var data: Data?
    var metadata: RecognitionMetadata?
    var reused = false
}
enum BackgroundWorker {
    static func perform(_ work: BackgroundWork) async throws -> BackgroundWorkOutput {
        try Task.checkCancellation()
        switch work.stage {
        case .preview: return BackgroundWorkOutput(preview: try await prepare(work))
        case .vector:
            guard let preview = work.preview else { throw RecognitionContract.invalid() }
            let data = try await AICatalogRepository.background { try AIImageVector.generate(imageAt: preview).data }
            return BackgroundWorkOutput(data: data)
        case .ai:
            guard let key = try AIModelKeychain.read(work.configuration) else {
                throw AIModelHTTPError(status: 401, retryAfter: nil)
            }
            let metadata = try await retry {
                try await PhotoRecognitionGenerator.shared.generate(work.item.asset, configuration: work.configuration, apiKey: key, previewURL: work.preview, taskItemID: work.token, savedPrompt: work.prompt)
            }
            return BackgroundWorkOutput(metadata: metadata)
        }
    }
    static func retry<T>(_ operation: () async throws -> T) async throws -> T {
        for attempt in 0...2 {
            do { return try await operation() }
            catch {
                try Task.checkCancellation()
                let http = error as? AIModelHTTPError
                let network = error as? URLError
                let transient = http.map { $0.status == 429 || (500...599).contains($0.status) } ?? network.map { [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains($0.code) } ?? false
                guard attempt < 2, transient else { throw error }
                let delay = min(240, max(0, http?.retryAfter ?? (attempt == 0 ? 2 : 8)))
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw RecognitionContract.invalid()
    }
    static func prepare(_ work: BackgroundWork) async throws -> URL {
        guard !work.item.asset.isVideo, work.item.asset.imageFiles.contains(where: { !["psd", "psb"].contains($0.url.pathExtension.lowercased()) }) else { throw RecognitionContract.invalid() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let output = home.appendingPathComponent("Library/Application Support/PhotoBrowser/TaskPreviews")
            .appendingPathComponent(ThumbnailCache.digest(work.item.id + "|" + work.snapshot) + ".jpg")
        var candidates = [output]
        if let preview = work.item.preview, preview.path.hasPrefix(home.path + "/Library/") { candidates.append(preview) }
        let cache = home.appendingPathComponent("Library/Caches/PhotoBrowser/Thumbnails")
        for size in [720, 520] {
            for file in work.item.asset.imageFiles {
                let key = ThumbnailCache.digest("v1|\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)|\(size)")
                candidates.append(cache.appendingPathComponent(key + ".jpg"))
            }
        }
        let inputs = candidates
        let local: URL? = try await AICatalogRepository.background { () -> URL? in
            for url in inputs {
                guard FileManager.default.fileExists(atPath: url.path),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      max(width, height) <= 720,
                      CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 16] as CFDictionary) != nil else { continue }
                return url
            }
            return nil as URL?
        }
        if let local { return local }
        let image = try await ThumbnailCache.shared.image(work.item.asset.preferred, maximum: 720, background: true).image
        let data = try PhotoRecognitionGenerator.jpeg(image).data
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        return output
    }
}
