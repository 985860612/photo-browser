import AppKit
import ImageIO
@testable import BrowserCore

extension ThumbnailChecks {
    private static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw BrowserFailure.message(message) }
        print("PASS \(message)")
    }
    static func persistentFolderChecks() async throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("FolderCache-" + UUID().uuidString)
        let library = workspace.appendingPathComponent("library"), source = library.appendingPathComponent("album")
        let sibling = library.appendingPathComponent("album2")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let jpeg = source.appendingPathComponent("A.jpg")
        let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try check(CGImageDestinationFinalize(destination), "folder cover fixture created")
        try Data([1, 2]).write(to: source.appendingPathComponent("A.arw"))
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("B.avif"))
        try Data([4]).write(to: source.appendingPathComponent(".hidden.jpg"))
        try fm.createDirectory(at: source.appendingPathComponent("fake.jpg"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: source.appendingPathComponent("link.jpg"), withDestinationURL: jpeg)
        try Data([8]).write(to: sibling.appendingPathComponent("C.jpg"))
        let summaryDirectory = workspace.appendingPathComponent("summaries"), sizeDirectory = workspace.appendingPathComponent("sizes")
        let summaries = FolderSummaryCache(directory: summaryDirectory, checkInterval: 0)
        let sizes = FolderSizeCache(directory: sizeDirectory, checkInterval: 0)
        let first = try await summaries.summary(of: source), bytes = try await sizes.size(of: source)
        try check(first.count == 2 && first.cover?.url.resolvingSymlinksInPath().path == jpeg.resolvingSymlinksInPath().path,
                  "folder summary pairs formats and excludes hidden files, directories and links (\(first.count), \(first.cover?.url.lastPathComponent ?? "nil"))")
        let thumbnailsDirectory = workspace.appendingPathComponent("thumbnails")
        let thumbnail = try await ThumbnailCache(directory: thumbnailsDirectory).image(first.cover!, maximum: 720)
        let summaryPath = summaryDirectory.appendingPathComponent(ThumbnailCache.digest(source.path) + ".json")
        let sizePath = sizeDirectory.appendingPathComponent(ThumbnailCache.digest(source.path) + ".json")
        let savedSummary = try Data(contentsOf: summaryPath), savedSize = try Data(contentsOf: sizePath)
        let reopenedSummaries = FolderSummaryCache(directory: summaryDirectory, checkInterval: 0)
        let reopenedSizes = FolderSizeCache(directory: sizeDirectory, checkInterval: 0)
        _ = try await reopenedSummaries.summary(of: source); _ = try await reopenedSizes.size(of: source)
        try check(try Data(contentsOf: summaryPath) == savedSummary && Data(contentsOf: sizePath) == savedSize,
                  "unchanged directories reuse persisted summaries and sizes without rewriting them")

        let offline = library.appendingPathComponent("offline")
        try fm.moveItem(at: source, to: offline)
        let offlineSummary = try await FolderSummaryCache(directory: summaryDirectory).cached(of: source)
        let offlineSize = try await FolderSizeCache(directory: sizeDirectory).cached(of: source)
        try check(offlineSummary?.value.count == 2 && offlineSize?.value == bytes,
                  "a new cache instance loads cover, count and size without any access to the source directory")
        let restoredCover = try await ThumbnailCache(directory: thumbnailsDirectory).image(offlineSummary!.value.cover!, maximum: 720)
        try check(restoredCover.image.size == thumbnail.image.size, "saved cover fingerprints find the existing local thumbnail while the source is offline")
        do { _ = try await FolderSizeCache(directory: sizeDirectory).size(of: source); throw BrowserFailure.message("Offline validation succeeded") }
        catch is CocoaError { print("PASS offline validation reports its error rather than pretending cached data is fresh") }
        try fm.moveItem(at: offline, to: source)

        let workers = PreviewWorkQueue(), blocked = FolderSizeCache(directory: sizeDirectory, workers: workers)
        let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let hold = Task { try await workers.run(background: true) { _ in
            began.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw BrowserFailure.message("Folder worker timed out") }
        } }
        defer { release.signal() }
        guard began.wait(timeout: .now() + 5) == .success else { throw BrowserFailure.message("Folder worker did not start") }
        let immediate = try await blocked.cached(of: source)
        try check(immediate?.value == bytes, "local cached size is available while the recursive scanning lane is blocked")
        release.signal(); try await hold.value

        try Data(repeating: 0, count: 12).write(to: source.appendingPathComponent("D.jpg"))
        let modifiedSummary = try await reopenedSummaries.summary(of: source)
        try check(modifiedSummary.count == 3, "changed directory stamps refresh the persisted photo count")
        _ = try await sizes.size(of: library); _ = try await sizes.size(of: sibling)
        try await sizes.invalidate([source])
        let removed = try await FolderSizeCache(directory: sizeDirectory).cached(of: source)
        let parent = try await sizes.cached(of: library), unaffected = try await sizes.cached(of: sibling)
        try check(removed == nil && parent == nil && unaffected != nil,
                  "invalidation removes persisted source and ancestor sizes while preserving similarly named siblings")
        _ = try await sizes.size(of: source)
        try await sizes.invalidate([library], descendants: true)
        try check(try await sizes.cached(of: sibling) == nil, "forced refresh invalidates cached descendants")

        try Data([0]).write(to: summaryPath)
        let corrupt = FolderSummaryCache(directory: summaryDirectory)
        do { _ = try await corrupt.cached(of: source); throw BrowserFailure.message("Corrupt JSON succeeded") }
        catch is DecodingError { print("PASS corrupt saved metadata is reported to the cached-first caller") }
        let rebuilt = try await corrupt.summary(of: source)
        try check(rebuilt.count == 3, "background validation rebuilds a damaged cache without changing photo files")

        _ = try await sizes.size(of: source)
        var record = try JSONSerialization.jsonObject(with: Data(contentsOf: sizePath)) as! [String: Any]
        var snapshot = record["snapshot"] as! [String: Any]
        snapshot["computedAt"] = Date().addingTimeInterval(-6 * 3600 - 1).timeIntervalSinceReferenceDate
        record["snapshot"] = snapshot
        try JSONSerialization.data(withJSONObject: record).write(to: sizePath)
        let nested = source.appendingPathComponent("fake.jpg/file.xmp")
        try Data(repeating: 0, count: 17).write(to: nested)
        let expired = FolderSizeCache(directory: sizeDirectory)
        let prior = try await expired.cached(of: source), recomputed = try await expired.size(of: source)
        try check(recomputed == prior!.value + 17, "six-hour expiry recomputes changes inside nested directories")

        let storage = FolderCacheStorage<Int64>(directory: workspace.appendingPathComponent("generations"))
        let ticket = storage.token(source)
        try storage.write(1, for: source, modified: nil, token: ticket)
        try storage.invalidate([source], descendants: false)
        do { try storage.write(2, for: source, modified: nil, token: ticket); throw BrowserFailure.message("Obsolete scan overwrote cache") }
        catch is CancellationError { print("PASS a scan started before invalidation cannot republish its obsolete result") }

        let invalidDirectory = workspace.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: invalidDirectory)
        do { _ = try await FolderSizeCache(directory: invalidDirectory).size(of: source); throw BrowserFailure.message("Cache write failure succeeded") }
        catch is CocoaError { print("PASS cache storage failures propagate instead of silently falling back") }
    }
}
