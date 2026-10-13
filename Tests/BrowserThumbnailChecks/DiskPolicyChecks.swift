import AppKit
import ImageIO
import BrowserCore

extension ThumbnailChecks {
    static func diskPolicyChecks() async throws {
        func require(_ value: Bool, _ label: String) throws {
            guard value else { throw BrowserFailure.message(label) }; print("PASS " + label)
        }
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("DiskPolicy-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let image = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        var files: [PhotoFile] = []
        for n in 0..<3 {
            let url = root.appendingPathComponent("\(n).jpg")
            let output = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(output, image, nil)
            try require(CGImageDestinationFinalize(output), "disk policy fixture created")
            files.append(PhotoFile(url: url, kind: .rendered))
        }
        let directory = root.appendingPathComponent("cache"), cache = ThumbnailCache(directory: directory)
        for file in files { _ = try await cache.image(file, maximum: 520) }
        _ = try await cache.image(files[0], maximum: 520) // Oldest-created entry becomes most recently accessed.
        let initial = try await cache.diskUsage(), quota = initial.bytes * 2 / 3
        try require(initial.entries == 3 && initial.bytes > 0, "disk usage counts actual thumbnail bytes")
        try cache.persistAccesses()
        try require(fm.fileExists(atPath: directory.appendingPathComponent("Accesses.json").path), "quit-time access persistence does not depend on the maintenance timer firing")
        try await cache.setDiskLimit(quota)
        let limited = try await cache.diskUsage()
        func saved(_ file: PhotoFile) -> Bool {
            let key = ThumbnailCache.digest("v1|\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)|520")
            return fm.fileExists(atPath: directory.appendingPathComponent(key + ".jpg").path)
        }
        try require(limited.bytes <= quota && saved(files[0]) && !saved(files[1]), "quota evicts the least recently accessed thumbnail rather than the oldest-created one")
        let reopened = ThumbnailCache(directory: directory)
        try await reopened.setDiskLimit(quota / 2)
        try require(saved(files[0]) && !saved(files[2]), "access order survives a new cache instance")
        let outside = root.appendingPathComponent("outside.jpg")
        try Data("original".utf8).write(to: outside)
        let link = directory.appendingPathComponent(String(repeating: "a", count: 64) + ".jpg")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let unknown = directory.appendingPathComponent("keep.json")
        try Data("unrelated".utf8).write(to: unknown)
        try await reopened.clear()
        try require(try await reopened.diskUsage().bytes == 0 && fm.fileExists(atPath: outside.path) && fm.fileExists(atPath: unknown.path), "clear removes only regular cache files and preserves originals, unrelated files, and symlink targets")

        let workers = PreviewWorkQueue(), blocked = ThumbnailCache(directory: root.appendingPathComponent("blocked"), workers: workers)
        let began = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let blocker = Task { try await workers.run(background: true) { _ in
            began.signal(); guard gate.wait(timeout: .now() + 5) == .success else { throw BrowserFailure.message("disk clear gate timed out") }
        } }
        defer { gate.signal() }
        let didStart = await Task.detached { began.wait(timeout: .now() + 5) == .success }.value
        guard didStart else { throw BrowserFailure.message("disk clear did not start") }
        let old = Task { try await blocked.image(files[0], maximum: 77, background: true) }
        try await Task.sleep(for: .milliseconds(30))
        let clearing = Task { try await blocked.clear() }
        do { _ = try await old.value; throw BrowserFailure.message("old generation survived clear") }
        catch is CancellationError { print("PASS clear cancels existing waiters before a blocked decoder finishes") }
        try await clearing.value
        try require(try await blocked.diskUsage().entries == 0, "local cache management does not wait for a blocked source decode lane")
        gate.signal(); try await blocker.value
        try require(try await blocked.diskUsage().entries == 0, "cancelled old work cannot repopulate a cleared cache")
        _ = try await blocked.image(files[0], maximum: 77)
        try require(try await blocked.diskUsage().entries == 1, "new requests can regenerate after clear")
    }
}
