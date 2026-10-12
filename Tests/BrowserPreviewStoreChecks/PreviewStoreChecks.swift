import AppKit
import ImageIO
import BrowserCore

@main struct PreviewStoreChecks {
    @MainActor static func main() async {
        do { try await run() }
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
        print("PASS all preview store and navigation checks")
    }

    @MainActor static func formatPreferenceChecks(root: URL) throws {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "preferRawPreview")
        defer { if let previous { defaults.set(previous, forKey: "preferRawPreview") } else { defaults.removeObject(forKey: "preferRawPreview") } }
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("format-support"))
        let raw = PhotoFile(url: root.appendingPathComponent("paired.ARW"), kind: .raw)
        let hif = PhotoFile(url: root.appendingPathComponent("paired.HIF"), kind: .rendered)
        let jpg = PhotoFile(url: root.appendingPathComponent("paired.JPG"), kind: .rendered)
        let pair = PhotoAsset(id: "pair", name: "pair", files: [raw, hif, jpg])
        let rawOnly = PhotoAsset(id: "raw-only", name: "raw-only", files: [raw])
        let jpgOnly = PhotoAsset(id: "jpg-only", name: "jpg-only", files: [jpg])
        store.assets = [pair, rawOnly, jpgOnly]; store.select(pair, modifiers: [])
        store.preferRawPreview = false
        try expect(store.focusedFile?.id == hif.id, "rendered preference previews the paired HIF")
        store.preferRawPreview = true
        try expect(store.focusedFile?.id == raw.id, "RAW preference selects the RAW original")
        store.preferredFileID = jpg.id
        try expect(store.focusedFile?.id == jpg.id, "manual format selection overrides the global preference for this photo")
        store.preferRawPreview = false
        try expect(store.preferredFileID == nil && store.focusedFile?.id == hif.id, "changing preference clears the current format override")
        store.select(rawOnly, modifiers: [])
        try expect(store.focusedFile?.id == raw.id, "rendered preference falls back to RAW when no rendered photo exists")
        store.preferRawPreview = true; store.select(jpgOnly, modifiers: [])
        try expect(store.focusedFile?.id == jpg.id, "RAW preference falls back to JPEG when no RAW exists")
        store.select(pair, modifiers: [])
        try expect(store.focusedFile?.id == raw.id, "navigation uses the global preference for the next photo")
        try expect(BrowserStore(supportDirectory: root.appendingPathComponent("format-reload")).preferRawPreview,
                   "RAW preference is remembered by a new browser")
    }

    @MainActor static func navigationChecks(root: URL) async throws {
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("navigation-support"))
        let folders = [root.appendingPathComponent("folder-a"), root.appendingPathComponent("folder-b")]
        let photos = (0..<3).map { n in
            PhotoAsset(id: "photo-\(n)", name: "photo-\(n)", files: [
                PhotoFile(url: root.appendingPathComponent("photo-\(n).jpg"), kind: .rendered)
            ])
        }
        store.assets = photos; store.subdirectories = folders
        store.select(photos[0], modifiers: [])
        store.step(-1)
        try expect(store.selectedFolderID == folders[1].path && store.selection.isEmpty,
                   "left from first photo selects the preceding folder and clears photo selection")
        store.step(-1); store.step(-1)
        try expect(store.selectedFolderID == folders[0].path && store.selectedItemID == "folder:" + folders[0].path,
                   "folder navigation stops at the first folder and provides its scroll identity")
        try expect(store.navigationScrollTarget == store.selectedItemID, "keyboard selection scrolls its card into view")
        store.selectFolder(folders[0])
        try expect(store.navigationScrollTarget == nil, "mouse selection keeps the card still for a second click")
        store.step(1); store.step(1)
        try expect(store.selectedFolderID == nil && store.focusedID == photos[0].id && store.selection == [photos[0].id],
                   "right from last folder returns to the first photo even when its preview was already focused")
        store.step(1); store.step(1); store.step(1)
        try expect(store.focusedID == photos[2].id, "photo navigation stops at the last photo")
        store.select(photos[0], modifiers: [])
        store.step(1, extendingSelection: true); store.step(1, extendingSelection: true)
        try expect(store.selection == Set(photos.map(\.id)), "Shift-right extends selection across photos")
        store.step(-1, extendingSelection: true); store.step(-1, extendingSelection: true); store.step(-1, extendingSelection: true)
        try expect(store.selection == [photos[0].id] && store.selectedFolderID == nil,
                   "Shift-left contracts the range and stops before folders")
        store.scope = "ungrouped"; store.changeScope(); store.step(-1)
        try expect(store.selectedFolderID == nil && store.focusedID == photos[0].id,
                   "ungrouped scope does not navigate hidden folder cards")
        store.groups = [PhotoGroup(id: "group", name: "group", assetIDs: [photos[2].id, photos[0].id])]
        store.scope = "group"; store.changeScope(); store.step(1)
        try expect(store.focusedID == photos[0].id && store.selectedFolderID == nil,
                   "group navigation follows group order and excludes folders")
        store.scope = "all"; store.changeScope(); store.isFullscreenPreview = true; store.step(-1)
        try expect(store.focusedID == photos[0].id && store.selectedFolderID == nil,
                   "fullscreen navigation remains within photos")
        store.isFullscreenPreview = false; store.assets = []; store.focusedID = nil; store.selection = []
        store.step(1); store.step(1)
        try expect(store.selectedFolderID == folders[1].path, "directories without photos remain keyboard navigable")
        try FileManager.default.createDirectory(at: folders[1], withIntermediateDirectories: true)
        store.openSelectedFolder()
        try await until { !store.isLoading }
        try expect(store.directory?.path == folders[1].path && store.selectedFolderID == nil && store.errorMessage == nil,
                   "opening selected folder loads it and clears the old selection")
        store.cancelPreviewGeneration()
    }
}
