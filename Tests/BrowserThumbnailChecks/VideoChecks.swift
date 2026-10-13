import AppKit
import BrowserCore

extension ThumbnailChecks {
    static func videoChecks() async throws {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw BrowserFailure.message(message) }; print("PASS \(message)")
        }
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("VideoChecks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("同名.MP4")
        try await VideoFixture.create(at: videoURL)
        try Data([1]).write(to: root.appendingPathComponent("同名.arw"))
        try Data([2]).write(to: root.appendingPathComponent("同名.jpg"))
        try Data([3]).write(to: root.appendingPathComponent("同名.MP4.xmp"))
        try Data([4]).write(to: root.appendingPathComponent("同名.xmp"))
        let assets = try DirectoryScanner.scan(root)
        try check(assets.count == 2 && assets.filter(\.isVideo).count == 1, "videos remain separate from matching RAW/JPEG photo families")
        let video = assets.first(where: \.isVideo)!, photo = assets.first { !$0.isVideo }!
        try check(video.imageFiles.isEmpty && video.mediaFiles.count == 1 && video.files.count == 2 && photo.files.count == 3,
                  "video sidecars attach only to their matching media family")
        let values = try videoURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let file = PhotoFile(url: videoURL, kind: .video, size: Int64(values.fileSize!), modified: values.contentModificationDate!)
        let cacheDirectory = root.appendingPathComponent("cache"), cache = ThumbnailCache(directory: cacheDirectory)
        let first = try await cache.image(file, maximum: 32)
        try check(first.image.size.width == 24 && first.image.size.height == 32 && first.metadata?.width == 48 && first.metadata?.height == 64,
                  "video covers apply rotation and keep native resolution metadata")
        try check((first.metadata?.duration ?? 0) > 1 && (first.metadata?.frameRate ?? 0) > 0, "video duration and frame rate are available")
        let summaries = FolderSummaryCache(directory: root.appendingPathComponent("summaries"), checkInterval: 0)
        let summary = try await summaries.summary(of: root)
        try check(summary.count == 1 && summary.videoCount == 1, "folder summaries count video and photo families separately")
        for ext in ["mov", "m4v"] { try fm.copyItem(at: videoURL, to: root.appendingPathComponent("同名." + ext)) }
        let formats = try DirectoryScanner.scan(root)
        try check(formats.filter(\.isVideo).count == 3 && Set(formats.map(\.id)).count == formats.count,
                  "MP4, MOV and M4V are recognized as independent files even with identical basenames")
        try fm.moveItem(at: videoURL, to: root.appendingPathComponent("offline.bin"))
        let disk = try await ThumbnailCache(directory: cacheDirectory).image(file, maximum: 32)
        try check(disk.image.size == first.image.size && disk.metadata?.duration == first.metadata?.duration,
                  "video covers and metadata survive a cache restart without reading the original")
        let time = Date()
        let captures = (0..<6).map { index in
            PhotoAsset(id: "capture-\(index)", name: "capture-\(index)", files: index < 3 ? photo.files : video.files,
                       metadata: PhotoMetadata(captured: time.addingTimeInterval(Double(index)), sequence: index, focalLength: 30))
        }
        let candidates = Grouping.candidates(captures)
        try check(candidates.count == 1 && candidates[0].assetIDs == ["capture-0", "capture-1", "capture-2"],
                  "panorama grouping preserves consecutive photos while excluding consecutive videos")
        try check(VideoMedia.durationLabel(3661) == "1:01:01" && VideoMedia.durationLabel(.infinity) == "—", "video duration labels handle long and unavailable durations")
        do { _ = try await cache.image(PhotoFile(url: root.appendingPathComponent("missing.mp4"), kind: .video), maximum: 32)
            throw BrowserFailure.message("missing video succeeded")
        } catch let error as BrowserFailure {
            if error.localizedDescription == "missing video succeeded" { throw error }
        } catch { print("PASS unreadable video reports an error") }
    }
}
