import AppKit
import ImageIO
import BrowserCore

@main struct PreviewStoreChecks {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do { try await warmQueueChecks(); try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }

    @MainActor static func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw BrowserFailure.message("Store check timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw BrowserFailure.message(message) }
        print("PASS \(message)")
    }

    static func waitForStart(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
    }

    @MainActor static func run() async throws {
        try await cullingChecks()
        try await directoryObserverChecks()
        try mapChecks()
        try await coordinatorChecks()
        try await folderDeletionChecks()
        try await permanentMediaDeletionChecks()
        try await previewSortingChecks()
        try await continuityChecks()
        try await videoPlaybackChecks()
        try await livePhotoPlaybackChecks()
        let fm = FileManager.default, defaults = UserDefaults.standard
        let lastDirectory = defaults.object(forKey: "lastDirectory")
        defer {
            if let lastDirectory { defaults.set(lastDirectory, forKey: "lastDirectory") }
            else { defaults.removeObject(forKey: "lastDirectory") }
        }
        let root = fm.temporaryDirectory.appendingPathComponent("PhotoBrowser-Prefetch-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        let cg = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        let data = NSMutableData(), dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw BrowserFailure.message("Cannot create test JPEG") }
        for n in 0..<64 { try (data as Data).write(to: old.appendingPathComponent(String(format: "old%03d.jpg", n))) }
        for n in 0..<3 {
            let name = String(format: "new%03d", n)
            try (data as Data).write(to: new.appendingPathComponent(name + ".jpg"))
            try Data("RAW must not be decoded instead of paired JPEG".utf8).write(to: new.appendingPathComponent(name + ".arw"))
        }
        try Data("invalid image".utf8).write(to: new.appendingPathComponent("bad.hif"))
        let workers = PreviewWorkQueue(), cacheDirectory = root.appendingPathComponent("cache")
        let thumbnails = ThumbnailCache(directory: cacheDirectory, workers: workers)
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"), thumbnails: thumbnails)
        let started = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let blocker = Task.detached { try await workers.run(background: true) { check in
            started.signal()
            guard gate.wait(timeout: .now() + 8) == .success else { throw BrowserFailure.message("Gate timeout") }
            try check()
        } }
        defer { gate.signal(); store.cancelPreviewGeneration() }
        let didStart = await Task.detached { waitForStart(started) }.value
        guard didStart else { throw BrowserFailure.message("Start timeout") }
        store.load(old)
        try await until { !store.isLoading && store.isGeneratingPreviews }
        try expect(store.previewTotal == 64 && !store.isMoving, "opening directory starts prefetch without disabling browsing")
        try await Task.sleep(for: .milliseconds(30))
        store.load(new)
        try await until { !store.isLoading && store.isGeneratingPreviews && store.directory?.path == new.path }
        try expect(store.previewTotal == 4 && store.previewCompleted == 0, "directory switch resets progress and cancels old work")
        store.scope = "ungrouped"; store.changeScope()
        gate.signal(); try await blocker.value
        try await until { !store.isGeneratingPreviews }
        try expect(store.previewCompleted == 4 && store.previewFailures == 1, "background continues past a bad image and reports failure count")
        try expect(store.previewFailureDetails.contains("bad.hif"), "failure details identify the unreadable photo")
        let caches = try fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }
        try expect(caches.count == 3, "only current directory preferred formats were generated")
        try expect(store.assets.count == 4 && store.totalFiles == 7 && store.visibleAssets.count == 4,
                   "RAW/JPEG pairing and scope remain correct during prefetch")
        let before = try Dictionary(uniqueKeysWithValues: caches.map { ($0.path, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) })
        store.load(new)
        try await until { !store.isLoading && !store.isGeneratingPreviews }
        let after = try Dictionary(uniqueKeysWithValues: caches.map { ($0.path, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) })
        try expect(before == after, "reopening directory reuses disk entries without rewriting them")
        try expect(store.previewCompleted == 4 && store.previewFailures == 1, "repeated scan finishes with accurate counts")
        try await navigationChecks(root: root)
        try formatPreferenceChecks(root: root)
        try await previewPreferenceChecks(root: root, jpeg: data as Data)
        try await adjacentDecodeChecks(root: root, jpeg: data as Data)
        try await deletionChecks(root: root, jpeg: data as Data)
        try await canvasRenderChecks(root: root)
        print("PASS all preview store and navigation checks")
    }


}
