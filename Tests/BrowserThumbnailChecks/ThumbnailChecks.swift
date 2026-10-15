import AppKit
import ImageIO
import BrowserCore

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw BrowserFailure.message(message) }
    print("PASS \(message)")
}

private func wait(_ semaphore: DispatchSemaphore) throws {
    guard semaphore.wait(timeout: .now() + 5) == .success else { throw BrowserFailure.message("Worker timed out") }
}

private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var peak = 0
    func enter() { lock.lock(); value += 1; peak = max(peak, value); lock.unlock() }
    func leave() { lock.lock(); value -= 1; lock.unlock() }
    var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@main struct ThumbnailChecks {
    static func main() async {
        do {
            try await workerChecks()
            try await gpsChecks()
            try networkReaderChecks()
            try await livePhotoChecks()
            try await cacheChecks()
            try await displayCacheChecks()
            try await folderSizeChecks()
            try await persistentFolderChecks()
            try await videoChecks()
            try await diskPolicyChecks()
            try await maintenanceChecks()
            print("PASS all thumbnail checks")
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }

    static func folderSizeChecks() async throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("FolderSize-" + UUID().uuidString)
        let root = workspace.appendingPathComponent("photos")
        try fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }
        try Data(repeating: 0, count: 10).write(to: root.appendingPathComponent("photo.jpg"))
        try Data(repeating: 0, count: 20).write(to: root.appendingPathComponent("photo.raw"))
        try Data(repeating: 0, count: 30).write(to: root.appendingPathComponent("nested/photo.xmp"))
        try Data(repeating: 0, count: 4).write(to: root.appendingPathComponent(".metadata"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.jpg"), withDestinationURL: root.appendingPathComponent("photo.jpg"))
        let cache = FolderSizeCache(directory: workspace.appendingPathComponent("cache"), lifetime: 0.15, checkInterval: 0)
        let initial = try await cache.size(of: root)
        try expect(initial == 64, "folder size includes nested files, companion formats and hidden files without following links (\(initial) bytes)")
        try Data(repeating: 0, count: 40).write(to: root.appendingPathComponent("nested/photo.xmp"))
        let reused = try await cache.size(of: root)
        try expect(reused == 64, "recent folder size is cached while scrolling")
        try await Task.sleep(for: .milliseconds(180))
        let refreshed = try await cache.size(of: root)
        try expect(refreshed == 74, "expired folder statistics pick up changes inside nested directories")
        try Data(repeating: 0, count: 8).write(to: root.appendingPathComponent("new.avif"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: root.path)
        let changed = try await cache.size(of: root)
        try expect(changed == 82, "folder modification invalidates a fresh cached size")
        let empty = root.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let zero = try await cache.size(of: empty)
        try expect(zero == 0, "an empty folder has zero file bytes")
        do { _ = try await cache.size(of: root.appendingPathComponent("missing")); throw BrowserFailure.message("Missing folder succeeded") }
        catch is CocoaError { print("PASS missing folder reports an error instead of a partial size") }
        do { _ = try await cache.size(of: root.appendingPathComponent("loop")); throw BrowserFailure.message("Symbolic folder succeeded") }
        catch is CocoaError { print("PASS symbolic folder is not traversed") }

        let workers = PreviewWorkQueue(), blockedCache = FolderSizeCache(directory: workspace.appendingPathComponent("blocked"), workers: workers)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocker = Task { try await workers.run(background: true) { _ in started.signal(); try wait(release) } }
        defer { release.signal() }
        try wait(started)
        let obsolete = Task { try await blockedCache.size(of: root) }
        await Task.yield(); obsolete.cancel()
        do { _ = try await obsolete.value; throw BrowserFailure.message("Cancelled folder scan succeeded") }
        catch is CancellationError { print("PASS offscreen folder scan cancels without waiting for the active scan") }
        release.signal(); try await blocker.value
    }

    static func workerChecks() async throws {
        let workers = PreviewWorkQueue()
        let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let background = Task { try await workers.run(background: true) { check -> Int in
            began.signal(); try wait(release); try check(); return 1
        } }
        try wait(began)
        let visible = try await workers.run { _ in 7 }
        try expect(visible == 7, "visible request completes while background decode is blocked")
        let obsolete = Task { try await workers.run(background: true) { _ in
            throw BrowserFailure.message("Cancelled queued operation executed")
        } as Int }
        await Task.yield(); obsolete.cancel()
        do { _ = try await obsolete.value; throw BrowserFailure.message("Cancellation did not throw") }
        catch is CancellationError { print("PASS obsolete queued job cancels before the current decode finishes") }
        release.signal(); _ = try await background.value

        let counts = Counts(), gate = DispatchSemaphore(value: 0), start = DispatchSemaphore(value: 0)
        let first = (0..<2).map { _ in Task { try await workers.run { _ -> Int in
            counts.enter(); defer { counts.leave() }; start.signal(); try wait(gate); return 1
        } } }
        defer { gate.signal(); gate.signal() }
        try wait(start); try wait(start)
        let rest = (0..<12).map { _ in Task { try await workers.run { _ -> Int in
            counts.enter(); defer { counts.leave() }; return 1
        } } }
        gate.signal(); gate.signal()
        for task in first + rest { _ = try await task.value }
        try expect(counts.maximum == 2, "foreground concurrency is bounded to two decoders")

        let parallel = PreviewWorkQueue(backgroundConcurrency: 1), parallelCounts = Counts()
        let parallelStarted = DispatchSemaphore(value: 0), parallelGate = DispatchSemaphore(value: 0)
        let jobs = (0..<4).map { _ in Task { try await parallel.run(background: true) { _ in
            parallelCounts.enter(); defer { parallelCounts.leave() }
            parallelStarted.signal(); try wait(parallelGate)
        } } }
        defer { for _ in 0..<4 { parallelGate.signal() } }
        try await Task.detached { try wait(parallelStarted) }.value
        parallel.setBackgroundConcurrency(4)
        try await Task.detached { for _ in 0..<3 { try wait(parallelStarted) } }.value
        try expect(parallelCounts.current == 4 && parallelCounts.maximum == 4,
                   "raising background concurrency starts four queued decodes in parallel")
        let foreground = try await parallel.run { _ in 9 }
        try expect(foreground == 9 && parallelCounts.current == 4, "four busy background decoders leave the foreground lane available")
        parallel.setBackgroundConcurrency(1)
        try expect(parallelCounts.current == 4, "lowering concurrency leaves already-running decoders intact")
        let extraStarted = DispatchSemaphore(value: 0), extraGate = DispatchSemaphore(value: 0)
        let next = Task { try await parallel.run(background: true) { _ in
            parallelCounts.enter(); defer { parallelCounts.leave() }; extraStarted.signal(); try wait(extraGate)
        } }
        defer { extraGate.signal() }
        for _ in 0..<4 { parallelGate.signal() }
        for job in jobs { try await job.value }
        try await Task.detached { try wait(extraStarted) }.value
        let laterStarted = DispatchSemaphore(value: 0)
        let later = Task { try await parallel.run(background: true) { _ in laterStarted.signal() } }
        let unexpected = await Task.detached { laterStarted.wait(timeout: .now() + 0.05) == .success }.value
        try expect(!unexpected && parallelCounts.current == 1, "new background decodes respect the reduced one-worker limit")
        later.cancel()
        do { try await later.value; throw BrowserFailure.message("Cancelled reduced-limit job succeeded") }
        catch is CancellationError { print("PASS queued background work still cancels with a changed concurrency limit") }
        extraGate.signal(); try await next.value
    }

    static func cacheChecks() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PhotoBrowser-Thumbnail-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("portrait.jpg")
        let context = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1600,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let destination = CGImageDestinationCreateWithURL(sourceURL as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifFNumber: 8,
                                             kCGImagePropertyExifLensModel: "EF-S55-250mm f/4-5.6 IS STM"]] as CFDictionary)
        try expect(CGImageDestinationFinalize(destination), "synthetic portrait source created")
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let file = PhotoFile(url: sourceURL, kind: .rendered, size: Int64(values.fileSize!), modified: values.contentModificationDate!)
        let directory = root.appendingPathComponent("cache"), workers = PreviewWorkQueue()
        let cache = ThumbnailCache(directory: directory, workers: workers)

        // Block both decode lanes so all eight callers overlap before a cold decode can finish.
        let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blockers = (0..<2).map { _ in Task { try await workers.run { _ in began.signal(); try wait(release) } } }
        defer { release.signal(); release.signal() }
        try wait(began); try wait(began)
        let callers = (0..<8).map { _ in Task { try await cache.image(file, maximum: 520) } }
        try await Task.sleep(for: .milliseconds(50))
        release.signal(); release.signal()
        for blocker in blockers { try await blocker.value }
        var previews: [LoadedPreview] = []
        for caller in callers { previews.append(try await caller.value) }
        let preview = previews[0]
        try expect(previews.allSatisfy { $0.image === preview.image }, "overlapping requests share one decoded image")
        try expect(preview.image.size.height > preview.image.size.width, "EXIF orientation preserved")
        try expect(preview.metadata?.iso == 400 && preview.metadata?.aperture == 8, "preview metadata preserved")
        try expect(preview.metadata?.lensModel == "EF-S55-250mm f/4-5.6 IS STM", "native EXIF lens model is preserved without guessing from focal length")
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try expect(files.filter { $0.pathExtension == "jpg" }.count == 1, "duplicate requests write one cache entry")
        let key = ThumbnailCache.digest("v1|\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)|520")
        try expect(fm.fileExists(atPath: directory.appendingPathComponent(key + ".jpg").path), "existing v1 cache filenames remain compatible")

        let legacy = try JSONDecoder().decode(PhotoMetadata.self, from: Data("{\"iso\":400,\"aperture\":8}".utf8))
        try expect(legacy.lensModel == nil && legacy.iso == 400, "old metadata without a lens model remains decodable")
        try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent(key + ".json"))
        let oldCache = ThumbnailCache(directory: directory)
        let jpegDate = try directory.appendingPathComponent(key + ".jpg").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let oldPreview = try await oldCache.image(file, maximum: 520)
        try expect(oldPreview.metadata?.lensModel == nil, "existing thumbnail metadata can lack the new lens field")
        let enriched = try await oldCache.sourceMetadata(file)
        try expect(enriched?.lensModel == preview.metadata?.lensModel, "original source header enriches old thumbnail metadata with the lens model")
        let headerKey = ThumbnailCache.digest("metadata-v1|\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)")
        try Data("{\"metadata\":null}".utf8).write(to: directory.appendingPathComponent(headerKey + ".json"))
        let recoveredHeader = try await ThumbnailCache(directory: directory).sourceMetadata(file)
        try expect(recoveredHeader?.lensModel == preview.metadata?.lensModel, "unreadable header cache entries are retried instead of treated as a missing lens")
        try expect(try directory.appendingPathComponent(key + ".jpg").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == jpegDate,
                   "lens enrichment does not regenerate or rewrite the thumbnail")
        if MetadataReader.executable != nil {
            let values = try MetadataReader().read(directory: root, assets: [PhotoAsset(id: "portrait", name: "portrait", files: [file])])
            try expect(values["portrait"]?.lensModel == preview.metadata?.lensModel, "ExifTool metadata imports preserve the same lens model")
        }
        let noLensURL = root.appendingPathComponent("no-lens.jpg")
        let noLensDestination = CGImageDestinationCreateWithURL(noLensURL as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(noLensDestination, context.makeImage()!, nil)
        try expect(CGImageDestinationFinalize(noLensDestination), "synthetic source without lens metadata created")
        let noLensFile = PhotoFile(url: noLensURL, kind: .rendered)
        let noLens = try await cache.sourceMetadata(noLensFile)
        try expect(noLens?.lensModel == nil, "photos without lens tags keep an unknown lens")
        try fm.removeItem(at: noLensURL)
        let noLensReloaded = try await ThumbnailCache(directory: directory).sourceMetadata(noLensFile)
        try expect(noLensReloaded?.lensModel == nil, "missing lens results persist without repeatedly accessing the source")

        let warmingStarted = DispatchSemaphore(value: 0), warmingGate = DispatchSemaphore(value: 0)
        let hold = Task { try await workers.run(background: true) { _ in warmingStarted.signal(); try wait(warmingGate) } }
        defer { warmingGate.signal() }
        try wait(warmingStarted)
        let visibleStarted = DispatchSemaphore(value: 0), visibleGate = DispatchSemaphore(value: 0)
        let visibleHolds = (0..<2).map { _ in Task {
            try await workers.run { _ in visibleStarted.signal(); try wait(visibleGate) }
        } }
        defer { visibleGate.signal(); visibleGate.signal() }
        try wait(visibleStarted); try wait(visibleStarted)
        let warming = Task { try await cache.image(file, maximum: 519, background: true) }
        try await Task.sleep(for: .milliseconds(30))
        let watching = Task { try await cache.image(file, maximum: 519) }
        try await Task.sleep(for: .milliseconds(30))
        warming.cancel()
        do { _ = try await warming.value; throw BrowserFailure.message("Cancelled waiter succeeded") }
        catch is CancellationError { print("PASS cancelling prefetch releases its waiter immediately") }
        visibleGate.signal(); visibleGate.signal()
        for holding in visibleHolds { try await holding.value }
        warmingGate.signal(); try await hold.value
        let shared = try await watching.value
        try expect(shared.image.size == preview.image.size && shared.metadata?.iso == 400,
                   "cancelling prefetch preserves the visible request sharing its decode")

        let modified = PhotoFile(url: file.url, kind: file.kind, size: file.size, modified: file.modified.addingTimeInterval(1))
        _ = try await cache.image(modified, maximum: 520, background: true)
        try expect(try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }.count == 3,
                   "changed source fingerprint invalidates cache")

        let protectedURL = directory.appendingPathComponent(key + ".jpg")
        try fm.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: protectedURL.path)
        for index in 0..<2000 { try Data([0]).write(to: directory.appendingPathComponent("obsolete-\(index).jpg")) }
        try await cache.trim()
        try expect(fm.fileExists(atPath: protectedURL.path), "space-based cleanup retains entries when within the quota")
        try expect(try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }.count == 2003,
                   "cache cleanup leaves files outside the recognized cache namespace untouched")

        try fm.removeItem(at: sourceURL)
        let coldCache = ThumbnailCache(directory: directory)
        let cachedHeader = try await coldCache.sourceMetadata(file)
        try expect(cachedHeader?.lensModel == preview.metadata?.lensModel, "lens metadata survives restarting the cache with the source offline")
        let disk = try await coldCache.image(file, maximum: 520)
        try expect(disk.image.size == preview.image.size && disk.metadata?.iso == 400, "new cache instance reads disk preview without accessing source")
        try fm.removeItem(at: directory)
        let hot = try await coldCache.image(file, maximum: 520)
        try expect(hot.image === disk.image && hot.metadata?.iso == 400, "RAM hit reads neither JPEG nor metadata files")
        let hotHeader = try await coldCache.sourceMetadata(file)
        try expect(hotHeader?.lensModel == preview.metadata?.lensModel, "lens metadata in RAM needs neither the original nor the disk cache")
        let changedHeaderFile = PhotoFile(url: file.url, kind: file.kind, size: file.size + 1, modified: file.modified)
        do { _ = try await coldCache.sourceMetadata(changedHeaderFile); throw BrowserFailure.message("Changed source reused stale lens metadata") }
        catch let failure as BrowserFailure { try expect(failure.localizedDescription.contains("portrait.jpg"), "a changed source fingerprint cannot reuse stale lens metadata") }
        try await coldCache.clear()
        do { _ = try await coldCache.sourceMetadata(file); throw BrowserFailure.message("Cleared metadata remained in RAM") }
        catch let failure as BrowserFailure { try expect(failure.localizedDescription.contains("portrait.jpg"), "clearing preview caches also clears cached lens metadata") }

        let bad = PhotoFile(url: root.appendingPathComponent("missing.hif"), kind: .rendered)
        do { _ = try await cache.image(bad, maximum: 520); throw BrowserFailure.message("Missing image succeeded") }
        catch let failure as BrowserFailure { try expect(failure.localizedDescription.contains("missing.hif"), "bad source reports its filename") }
    }
}
