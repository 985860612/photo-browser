import AppKit
import ImageIO
import BrowserCore

extension ThumbnailChecks {
    static func maintenanceChecks() async throws {
        func require(_ value: Bool, _ label: String) throws {
            guard value else { throw BrowserFailure.message(label) }; print("PASS " + label)
        }
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("Maintenance-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("source.jpg")
        let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let output = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, nil)
        try require(CGImageDestinationFinalize(output), "maintenance fixture created")
        let file = PhotoFile(url: url, kind: .rendered)

        let workers = PreviewWorkQueue(), began = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let cache = ThumbnailCache(directory: root.appendingPathComponent("promotion"), workers: workers)
        let blocker = Task { try await workers.run(background: true) { _ in
            began.signal()
            guard gate.wait(timeout: .now() + 5) == .success else { throw BrowserFailure.message("promotion failed to bypass background queue") }
        } }
        defer { gate.signal() }
        func waitForStart() -> Bool { began.wait(timeout: .now() + 5) == .success }
        let started = await Task.detached { waitForStart() }.value
        try require(started, "background lane blocked for promotion check")
        let warming = Task { try await cache.image(file, maximum: 90, background: true) }
        try await Task.sleep(for: .milliseconds(40))
        let visible = try await cache.image(file, maximum: 90)
        let shared = try await warming.value
        // The gate remains closed until both waiters have finished.
        gate.signal(); try await blocker.value
        let promotedUsage = try await cache.diskUsage()
        try require(visible.image === shared.image && promotedUsage.entries == 1,
                    "visible waiter promotes queued thumbnail work and shares one decoded image")

        let repairDirectory = root.appendingPathComponent("repair"), original = ThumbnailCache(directory: repairDirectory)
        _ = try await original.image(file, maximum: 80)
        let key = ThumbnailCache.digest("v1|\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)|80")
        try Data([0]).write(to: repairDirectory.appendingPathComponent(key + ".jpg"))
        let repaired = ThumbnailCache(directory: repairDirectory)
        let damagedUsage = try await repaired.diskUsage()
        _ = try await repaired.image(file, maximum: 80)
        let repairedUsage = try await repaired.diskUsage()
        let repairedBytes = try fm.contentsOfDirectory(at: repairDirectory, includingPropertiesForKeys: [.fileSizeKey]).reduce(Int64(0)) { total, url in
            guard url.lastPathComponent != "Accesses.json" else { return total }
            return total + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        try require(repairedUsage.entries == 1 && repairedUsage.bytes > damagedUsage.bytes && repairedUsage.bytes == repairedBytes,
                    "replacing a damaged JPEG updates its size without double-counting the entry")

        let directory = root.appendingPathComponent("index"), indexed = ThumbnailCache(directory: directory)
        func actualBytes() throws -> Int64 {
            try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).reduce(0) { total, url in
                guard url.lastPathComponent != "Accesses.json" else { return total }
                return total + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
        }
        try require((try await indexed.diskUsage()).bytes == 0, "uncreated cache initializes an empty index")
        _ = try await indexed.image(file, maximum: 80)
        _ = try await indexed.image(file, maximum: 81)
        _ = try await indexed.sourceMetadata(file)
        let usage = try await indexed.diskUsage()
        try require(usage.entries == 2 && usage.bytes == actualBytes(), "incremental statistics include images and source metadata exactly once")
        try indexed.persistAccesses()
        let accesses = directory.appendingPathComponent("Accesses.json")
        let before = try accesses.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        for _ in 0..<3 { _ = try await indexed.image(file, maximum: 80); try await indexed.trim() }
        var fresh = accesses; fresh.removeAllCachedResourceValues()
        try require(try fresh.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == before,
                    "under-quota hits do not repeatedly rewrite the access index")

        // A write failure must invalidate statistics so the next successful request can reconcile.
        let saved = root.appendingPathComponent("saved-index")
        try fm.moveItem(at: directory, to: saved)
        try Data([0]).write(to: directory)
        do { _ = try await indexed.image(file, maximum: 82); throw BrowserFailure.message("cache write failure was hidden") }
        catch let failure as BrowserFailure { throw failure }
        catch { print("PASS cache write failures remain visible") }
        try fm.removeItem(at: directory); try fm.moveItem(at: saved, to: directory)
        _ = try await indexed.image(file, maximum: 82)
        let recovered = try await indexed.diskUsage()
        try require(recovered.entries == 3 && recovered.bytes == actualBytes(), "failed writes reconcile before publishing recovered cache statistics")

        try await indexed.invalidate([file])
        let invalidated = try await indexed.diskUsage()
        try require(invalidated.entries == 0 && invalidated.bytes == 0 && actualBytes() == 0,
                    "invalidation subtracts all known thumbnail resolutions and metadata")
        try indexed.persistAccesses()
        let persisted = try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: accesses))
        try require(persisted.isEmpty, "explicit flush removes invalidated access records")
        let external = directory.appendingPathComponent(String(repeating: "b", count: 64) + ".jpg")
        try Data([1, 2, 3]).write(to: external)
        try require((try await indexed.diskUsage()).bytes == 0, "warm usage reuses statistics instead of rescanning every query")
        try await indexed.clear()
        let cleared = try await indexed.diskUsage()
        try require(!fm.fileExists(atPath: external.path) && cleared.bytes == 0,
                    "explicit clear reconciles and removes externally added valid cache files")
    }
}
