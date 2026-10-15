import AppKit
import ImageIO
import BrowserCore

extension ThumbnailChecks {
    static func livePhotoChecks() async throws {
        func require(_ value: Bool, _ label: String) throws {
            guard value else { throw BrowserFailure.message(label) }; print("PASS " + label)
        }
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("LivePhotoChecks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for compressed in [false, true] {
            let url = root.appendingPathComponent(compressed ? "compressed.livp" : "phone backup (1).LIVP")
            try await LivePhotoFixture.create(at: url, compressed: compressed)
            let file = PhotoFile(url: url, kind: .rendered)
            let original = try Data(contentsOf: url)
            let directory = root.appendingPathComponent(UUID().uuidString), live = LivePhotoCache(directory: directory)
            let photo = try live.photoData(file)
            let source = CGImageSourceCreateWithData(photo as CFData, nil)!
            let metadata = ImageMetadataReader.read(source)
            try require(metadata?.camera == "Live Photo Fixture", "stored and deflated LIVP preserve original photo metadata")
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
            try require(props[kCGImagePropertyGPSDictionary as String] != nil, "LIVP original photos retain their GPS dictionary")
            try require(try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).allSatisfy { $0.pathExtension != "mov" },
                        "static browsing extracts no Live Photo video")
            var movie: LivePhotoMovie? = try live.movie(file)
            try require(movie!.url.pathExtension == "mov" && fm.fileExists(atPath: movie!.url.path), "Live Photo movie extracts on demand with wildcard member names treated literally")
            try require(try live.usage().bytes <= live.usage().limit, "Live Photo originals obey the disk budget")
            try live.clear()
            try require(fm.fileExists(atPath: movie!.url.path), "cache clear preserves a pinned playing movie")
            movie = nil; try live.clear()
            try require(try live.usage().bytes == 0, "unpinned Live Photo originals can be fully cleared")
            _ = try live.photoData(file)
            try require(try Data(contentsOf: url) == original, "reading LIVP does not modify the original archive")
            try fm.removeItem(at: url)
            let offline = try LivePhotoCache(directory: directory).photoData(file)
            try require(offline == photo, "a new cache instance reuses extracted photos without reopening an offline archive")
        }
        let archive = root.appendingPathComponent("static only.livp")
        try await LivePhotoFixture.create(at: archive, movie: false)
        let file = PhotoFile(url: archive, kind: .rendered)
        let assets = try DirectoryScanner.scan(root)
        try require(assets.count == 1 && assets[0].isLivePhoto && !assets[0].isVideo, "scanner counts LIVP as one photo without enumerating archive members")
        let cache = ThumbnailCache(directory: root.appendingPathComponent("thumbnails"))
        let thumb = try await cache.image(file, maximum: 60)
        try require(thumb.image.size.height > thumb.image.size.width, "LIVP thumbnails apply original EXIF orientation")
        let large = try await DisplayPhotoCache().image(file, hdr: false, maximum: 2800)
        let full = try await cache.fullResolution(file)
        try require(large.size.width == 80 && large.size.height == 120 && full.image.size.width == 80 && full.image.size.height == 120,
                    "LIVP browsing and fullscreen decode original pixels rather than a small poster")
        let imported = try MetadataReader().read(directory: root, assets: assets)
        try require(imported[assets[0].id]?.captured != nil, "grouping reads LIVP photo capture metadata")
        let tiny = LivePhotoCache(directory: root.appendingPathComponent("tiny"), limit: 16)
        do { _ = try tiny.photoData(file); throw BrowserFailure.message("Over-budget archive unexpectedly succeeded") }
        catch let error as BrowserFailure { try require(error.localizedDescription.contains("LIVP"), "oversized members fail clearly instead of exceeding the budget") }
        try require(try tiny.usage().bytes == 0, "failed oversized extraction leaves no committed cache entry")
        let invalid = root.appendingPathComponent("broken.livp"); try Data([0, 1, 2]).write(to: invalid)
        do { _ = try LivePhotoCache(directory: root.appendingPathComponent("broken-cache")).photoData(PhotoFile(url: invalid, kind: .rendered)); throw BrowserFailure.message("Broken archive unexpectedly succeeded") }
        catch let error as BrowserFailure { try require(error.localizedDescription.contains("LIVP"), "broken archives report a useful error") }
    }
}
