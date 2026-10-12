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
}

@main struct ThumbnailChecks {
    static func main() async {
        do {
            try await workerChecks()
            try await cacheChecks()
            try await displayCacheChecks()
            print("PASS all thumbnail checks")
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
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
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifFNumber: 8]] as CFDictionary)
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
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try expect(files.filter { $0.pathExtension == "jpg" }.count == 1, "duplicate requests write one cache entry")
        let key = ThumbnailCache.digest("v1|\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)|520")
        try expect(fm.fileExists(atPath: directory.appendingPathComponent(key + ".jpg").path), "existing v1 cache filenames remain compatible")

        let warmingStarted = DispatchSemaphore(value: 0), warmingGate = DispatchSemaphore(value: 0)
        let hold = Task { try await workers.run(background: true) { _ in warmingStarted.signal(); try wait(warmingGate) } }
        defer { warmingGate.signal() }
        try wait(warmingStarted)
        let warming = Task { try await cache.image(file, maximum: 519, background: true) }
        try await Task.sleep(for: .milliseconds(30))
        let watching = Task { try await cache.image(file, maximum: 519) }
        try await Task.sleep(for: .milliseconds(30))
        warming.cancel()
        do { _ = try await warming.value; throw BrowserFailure.message("Cancelled waiter succeeded") }
        catch is CancellationError { print("PASS cancelling prefetch releases its waiter immediately") }
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
        try await cache.trim(protecting: [file])
        try expect(fm.fileExists(atPath: protectedURL.path), "cache cleanup preserves active directory images even when oldest")
        try expect(try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }.count == 1600,
                   "cache cleanup removes obsolete entries to the storage limit")

        try fm.removeItem(at: sourceURL)
        let coldCache = ThumbnailCache(directory: directory)
        let disk = try await coldCache.image(file, maximum: 520)
        try expect(disk.image.size == preview.image.size && disk.metadata?.iso == 400, "new cache instance reads disk preview without accessing source")
        try fm.removeItem(at: directory)
        let hot = try await coldCache.image(file, maximum: 520)
        try expect(hot.image === disk.image && hot.metadata?.iso == 400, "RAM hit reads neither JPEG nor metadata files")

        let bad = PhotoFile(url: root.appendingPathComponent("missing.hif"), kind: .rendered)
        do { _ = try await cache.image(bad, maximum: 520); throw BrowserFailure.message("Missing image succeeded") }
        catch let failure as BrowserFailure { try expect(failure.localizedDescription.contains("missing.hif"), "bad source reports its filename") }
    }
}
