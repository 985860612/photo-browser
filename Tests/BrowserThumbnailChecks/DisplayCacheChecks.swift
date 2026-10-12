import Foundation
import ImageIO
import BrowserCore

extension ThumbnailChecks {
    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw BrowserFailure.message(message) }
        print("PASS \(message)")
    }
    private static func gateWait(_ gate: DispatchSemaphore) throws {
        guard gate.wait(timeout: .now() + 5) == .success else { throw BrowserFailure.message("Display cache worker timed out") }
    }
    static func displayCacheChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DisplayCache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1600,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let cg = context.makeImage()!
        var files: [PhotoFile] = []
        for index in 0..<6 {
            let url = root.appendingPathComponent("photo\(index).jpg")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
            try require(CGImageDestinationFinalize(dest), "display fixture \(index) created")
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            files.append(PhotoFile(url: url, kind: .rendered, size: Int64(values.fileSize!), modified: values.contentModificationDate!))
        }
        let cache = DisplayPhotoCache(memoryBudget: 16 * 1024 * 1024)
        let photo = try await cache.image(files[0], hdr: true, maximum: 200)
        try require(photo.size.width == 100 && photo.size.height == 200, "large cache preserves EXIF orientation")
        let reused = try await cache.image(files[0], hdr: true, maximum: 200)
        let reuseStats = await cache.statistics()
        try require(photo.image === reused.image && reuseStats.decodes == 1, "revisiting a large preview reuses decoded pixels")
        _ = try await cache.image(files[0], hdr: false, maximum: 200)
        _ = try await cache.image(files[0], hdr: true)
        _ = try await cache.image(files[0], hdr: true, maximum: 2800)
        try require(await cache.statistics().decodes == 3, "HDR mode has a separate key and native pixels satisfy smaller previews")
        let modified = PhotoFile(url: files[0].url, kind: .rendered, size: files[0].size, modified: files[0].modified.addingTimeInterval(1))
        _ = try await cache.image(modified, hdr: true, maximum: 200)
        try require(await cache.statistics().entries == 1, "source fingerprint changes remove obsolete decoded versions")

        let limited = DisplayPhotoCache(memoryBudget: photo.memoryCost * 3)
        await limited.setWorkingSet(current: files[0], neighbors: Array(files.dropFirst()), hdr: true)
        _ = try await limited.image(files[0], hdr: true, maximum: 200)
        for file in files.dropFirst() { _ = try await limited.image(file, hdr: true, maximum: 200, background: true) }
        try require(await limited.statistics().bytes <= photo.memoryCost * 3, "decoded pixels never exceed the configured memory budget")
        let current = await limited.cached(files[0], hdr: true, maximum: 200)
        let near = await limited.cached(files[1], hdr: true, maximum: 200)
        let next = await limited.cached(files[2], hdr: true, maximum: 200)
        let far = await limited.cached(files[5], hdr: true, maximum: 200)
        try require(current != nil && near != nil && next != nil && far == nil, "current photo and close neighbors survive distant preloading")
        await limited.releaseNeighbors()
        try require(await limited.statistics().entries == 1, "memory pressure releases neighboring pixels while keeping the current photo")

        let workers = PreviewWorkQueue(), shared = DisplayPhotoCache(workers: workers)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocker = Task { try await workers.run(background: true) { _ in started.signal(); try gateWait(release) } }
        defer { release.signal() }
        try gateWait(started)
        let background = Task { try await shared.image(files[1], hdr: true, maximum: 200, background: true) }
        try await Task.sleep(for: .milliseconds(40))
        let cancelled = Task { try await shared.image(files[1], hdr: true, maximum: 200, background: true) }
        try await Task.sleep(for: .milliseconds(20)); cancelled.cancel()
        do { _ = try await cancelled.value; throw BrowserFailure.message("Cancelled preview succeeded") }
        catch is CancellationError { print("PASS cancelled waiter returns without waiting for blocked decode") }
        let visible = try await shared.image(files[1], hdr: true, maximum: 200)
        let warmed = try await background.value
        let sharedStats = await shared.statistics()
        try require(visible.image === warmed.image && sharedStats.decodes == 1,
                    "visible request promotes queued prefetch and shares one decode while the background lane is blocked")
        release.signal(); try await blocker.value

        let uncached = DisplayPhotoCache(memoryBudget: 0)
        _ = try await uncached.image(files[0], hdr: true, maximum: 200)
        try require(await uncached.statistics().bytes == 0, "oversized images remain displayable without exceeding cache capacity")
        let missing = PhotoFile(url: root.appendingPathComponent("missing.hif"), kind: .rendered)
        do { _ = try await shared.image(missing, hdr: true); throw BrowserFailure.message("Missing image succeeded") }
        catch let error as BrowserFailure {
            try require(error.localizedDescription.contains("missing.hif"), "failed decode identifies the source file")
            try require(await shared.statistics().pending == 0, "failed decoding does not leave a pending request")
        }

        let suite = "PhotoBrowser-Preferences-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreviewPreferences(defaults: defaults)
        try require(preferences.before == 2 && preferences.after == 5, "preload defaults are two previous and five next")
        preferences.before = 0; preferences.after = 9
        let reopened = PreviewPreferences(defaults: defaults)
        try require(reopened.before == 0 && reopened.after == 9, "zero and customized preload ranges survive reopening")
        preferences.before = -1; preferences.after = 100
        try require(preferences.before == 0 && preferences.after == 20, "invalid persisted preload settings are bounded")
        try require(PreviewPreferences.neighbors(in: Array(0..<12), index: 4, before: 2, after: 5) == [5,3,6,2,7,8,9],
                    "neighbors follow configured asymmetric counts and load near photos first")
        try require(PreviewPreferences.neighbors(in: [0,1,2], index: 0, before: 2, after: 5) == [1,2]
                    && PreviewPreferences.neighbors(in: [0,1,2], index: 2, before: 0, after: 0).isEmpty,
                    "range boundaries and disabled directions never wrap or preload the current photo")
        let layout = BrowserPanelLayout(available: 1080, directoryWidth: 420, inspectorWidth: 420, showDirectory: true, showInspector: true)
        try require(layout.directory + layout.inspector + 12 <= 530, "restored wide panels leave room for the photo in a smaller window")
        let expanded = BrowserPanelLayout(available: 1800, directoryWidth: 420, inspectorWidth: 420, showDirectory: false, showInspector: true)
        try require(expanded.directory == 0 && expanded.inspector == 420, "collapsed panel frees width without losing the other panel's requested width")
    }
}
