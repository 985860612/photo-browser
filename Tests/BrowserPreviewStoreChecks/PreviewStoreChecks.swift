import AppKit
import ImageIO
import BrowserCore

@main struct PreviewStoreChecks {
    @MainActor static func main() async {
        _ = NSApplication.shared
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
        try await previewSortingChecks()
        try await continuityChecks()
        try await videoPlaybackChecks()
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

    @MainActor static func previewSortingChecks() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("PreviewSorting-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "PreviewSorting-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"), thumbnails: ThumbnailCache(directory: root.appendingPathComponent("cache")), defaults: defaults, monitoringEnabled: false)
        defer { store.cancelPreviewGeneration() }
        func file(_ name: String, _ kind: PhotoKind, _ size: Int64, _ modified: Double) -> PhotoFile {
            PhotoFile(url: root.appendingPathComponent(name), kind: kind, size: size, modified: Date(timeIntervalSince1970: modified))
        }
        let a = PhotoAsset(id: "shot2", name: "shot2", files: [file("shot2.jpg", .rendered, 10, 300), file("shot2.arw", .raw, 50, 400), file("shot2.xmp", .sidecar, 5, 999)], metadata: PhotoMetadata(captured: Date(timeIntervalSince1970: 20)))
        let b = PhotoAsset(id: "shot10", name: "shot10", files: [file("shot10.jpg", .rendered, 100, 100)], metadata: PhotoMetadata(captured: Date(timeIntervalSince1970: 10)))
        let c = PhotoAsset(id: "shot1", name: "shot1", files: [file("shot1.jpg", .rendered, 20, 200), file("shot1.xmp", .sidecar, 10, 999)])
        store.assets = [a, b, c]; store.focusedID = a.id; store.selection = [a.id, b.id]
        try expect(store.visibleAssets.map(\.id) == [a.id, b.id, c.id], "default sorting preserves existing preview order")
        store.previewSortField = .name
        try expect(store.visibleAssets.map(\.id) == [c.id, a.id, b.id], "name sorting uses natural numeric filename order")
        let request = store.previewRequestID
        store.previewSortDescending = true
        try expect(store.visibleAssets.map(\.id) == [b.id, a.id, c.id] && store.focusedID == a.id && store.selection == [a.id, b.id], "descending sort preserves focus and multi-selection")
        try expect(store.previewRequestID != request && store.adjacentPreviewFiles.map(\.id) == [c.preferred.id, b.preferred.id], "preloading follows the newly sorted neighbors")
        store.step(-1)
        try expect(store.focusedID == b.id, "arrow navigation follows descending order")
        store.step(1, extendingSelection: true)
        try expect(store.selection == [a.id, b.id], "shift-arrow selection extends along the sorted sequence")
        let reopened = BrowserStore(supportDirectory: root.appendingPathComponent("reopened"), defaults: defaults, monitoringEnabled: false)
        try expect(reopened.previewSortField == .name && reopened.previewSortDescending, "sort field and direction survive reopening")
        store.previewSortDescending = false; store.previewSortField = .captured
        try expect(store.visibleAssets.map(\.id) == [b.id, a.id, c.id], "capture sorting uses metadata with modification time as the missing-date fallback")
        store.previewSortField = .modified
        try expect(store.visibleAssets.map(\.id) == [b.id, c.id, a.id], "modification sort takes the newest paired media file and ignores sidecar timestamps")
        store.previewSortField = .size
        try expect(store.visibleAssets.map(\.id) == [c.id, a.id, b.id], "size sorting totals companion RAW, JPEG and XMP files")
        let group = PhotoGroup(name: "manual order", assetIDs: [b.id, a.id])
        store.groups = [group]; store.scope = group.id; store.previewSortField = .original
        try expect(store.visibleAssets.map(\.id) == group.assetIDs, "default group sorting preserves manual member order")
        store.previewSortField = .name
        try expect(store.visibleAssets.map(\.id) == [a.id, b.id] && store.groups[0].assetIDs == group.assetIDs, "preview sorting leaves saved group membership and order intact")
        store.search = "10"
        try expect(store.visibleAssets.map(\.id) == [b.id], "sort cache invalidates when search changes")
        store.search = ""; store.scope = "all"; store.assets = [a, b]
        try expect(store.visibleAssets.map(\.id) == [a.id, b.id], "sort cache invalidates when external assets change")

        let photos = root.appendingPathComponent("exif")
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        let cg = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        for (name, date) in [("a", "2023:01:02 12:00:00"), ("z", "2023:01:01 12:00:00")] {
            let output = CGImageDestinationCreateWithURL(photos.appendingPathComponent(name + ".jpg") as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(output, cg, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date]] as CFDictionary)
            try expect(CGImageDestinationFinalize(output), "capture sort EXIF fixture created")
        }
        store.groups = []; store.assets = try DirectoryScanner.scan(photos); store.directory = photos
        store.previewSortField = .captured
        try await until { !store.isReadingSortDates }
        try expect(store.visibleAssets.map(\.id) == ["z", "a"] && store.assets.allSatisfy { $0.metadata?.captured != nil },
                   "capture sort reads actual cached/native EXIF dates in the background")
        store.assets[0].metadata?.captured = Date(timeIntervalSince1970: 1)
        try expect(store.visibleAssets.first?.id == store.assets[0].id, "capture sort cache invalidates when metadata is refreshed")
        store.previewSortField = .name
        let rawURL = photos.appendingPathComponent("raw.dng")
        try fm.copyItem(at: photos.appendingPathComponent("z.jpg"), to: rawURL)
        let values = try rawURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let raw = PhotoFile(url: rawURL, kind: .raw, size: Int64(values.fileSize!), modified: values.contentModificationDate!)
        let key = ThumbnailCache.digest("v1|\(raw.url.path)|\(raw.size)|\(raw.modified.timeIntervalSince1970)|520")
        // Simulate a camera's embedded-preview disk cache without capture metadata.
        try Data(contentsOf: photos.appendingPathComponent("z.jpg")).write(to: root.appendingPathComponent("cache/" + key + ".jpg"))
        store.assets = [PhotoAsset(id: "raw", name: "raw", files: [raw])]
        store.previewSortField = .captured; try await until { !store.isReadingSortDates }
        try expect(store.assets[0].metadata?.captured != nil, "cached RAW previews without date metadata use the original source-header capture date")
    }

    @MainActor static func adjacentDecodeChecks(root: URL, jpeg: Data) async throws {
        let workers = PreviewWorkQueue(), cache = DisplayPhotoCache(memoryBudget: 16 * 1024 * 1024, workers: workers)
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("neighbor-support"), displayCache: cache)
        let oldRaw = store.preferRawPreview
        defer { store.cancelAdjacentPreviews(); store.preferRawPreview = oldRaw }
        store.preferRawPreview = false
        store.assets = try (0..<12).map { index in
            let url = root.appendingPathComponent("neighbor-\(index).jpg")
            try jpeg.write(to: url)
            return PhotoAsset(id: "neighbor-\(index)", name: "neighbor-\(index)", files: [PhotoFile(url: url, kind: .rendered)])
        }
        store.focusedID = store.assets[4].id; store.previewBefore = 2; store.previewAfter = 5
        let started = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let blockers = (0..<2).map { _ in Task.detached { try await workers.run { _ in
            started.signal()
            guard gate.wait(timeout: .now() + 8) == .success else { throw BrowserFailure.message("Foreground gate timed out") }
        } } }
        defer { gate.signal(); gate.signal() }
        try expect(await Task.detached { waitForStart(started) && waitForStart(started) }.value,
                   "foreground lanes are blocked while independent neighbor warming starts")
        await store.preparePreviewCache()
        let current = PreviewPresentation(cache: cache)
        let currentLoad = Task { await current.load(store.focusedFile, hdr: store.hdrPreview, maximum: 2800) { _ in } }
        defer { currentLoad.cancel() }
        try await waitForCached(store.adjacentPreviewFiles, cache: cache, hdr: store.hdrPreview, maximum: 2800)
        try expect(current.loading && current.photo == nil, "all two previous and five next photos warm before current HD decoding finishes")
        for offset in 1...5 {
            try expect(await cache.cached(store.assets[4 + offset].preferred, hdr: store.hdrPreview, maximum: 2800) != nil,
                       "next +\(offset) has decoded browsing pixels")
        }
        currentLoad.cancel(); await currentLoad.value
        gate.signal(); gate.signal()
        for blocker in blockers { try await blocker.value }

        store.isFullscreenPreview = true
        await store.preparePreviewCache()
        try await waitForCached(store.adjacentPreviewFiles, cache: cache, hdr: store.hdrPreview, maximum: nil)
        let before = await cache.statistics().decodes
        await current.load(store.assets[9].preferred, hdr: store.hdrPreview, maximum: nil) { _ in }
        try expect(await cache.statistics().decodes == before && current.photo != nil && !current.loading,
                   "fullscreen next +5 hits preloaded native pixels without another decode")

        await cache.removeAll()
        store.isFullscreenPreview = false
        let bgStarted = DispatchSemaphore(value: 0), bgGate = DispatchSemaphore(value: 0)
        let bgBlocker = Task.detached { try await workers.run(background: true) { _ in
            bgStarted.signal()
            guard bgGate.wait(timeout: .now() + 8) == .success else { throw BrowserFailure.message("Background gate timed out") }
        } }
        defer { bgGate.signal() }
        try expect(await Task.detached { waitForStart(bgStarted) }.value, "background lane held for rapid navigation")
        await store.preparePreviewCache()
        try await waitForPending(cache, count: 7)
        store.focusedID = store.assets[5].id
        await store.preparePreviewCache()
        try await waitForPending(cache, count: 8)
        let joinedBefore = await cache.statistics().decodes
        _ = try await cache.image(store.focusedFile!, hdr: store.hdrPreview, maximum: 2800)
        try expect(await cache.statistics().decodes == joinedBefore,
                   "navigation retains an overlapping prefetch and promotes it instead of decoding again")
        store.selectFolder(root)
        await store.preparePreviewCache()
        try await waitForPending(cache, count: 0)
        bgGate.signal(); try await bgBlocker.value
        try expect(await cache.statistics().pending == 0, "folder selection cancels obsolete neighboring work")
        store.selectedFolderID = nil
        let cancelledPreparation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.preparePreviewCache()
        }
        await cancelledPreparation.value
        try expect(await cache.statistics().pending == 0, "cancelled viewer cannot restart neighboring tasks after disappearing")
        store.previewBefore = 0; store.previewAfter = 0
        await cache.removeAll(); await store.preparePreviewCache()
        try await Task.sleep(for: .milliseconds(30))
        let cacheStatistics = await cache.statistics()
        try expect(cacheStatistics.pending == 0 && cacheStatistics.entries == 0,
                   "zero configured directions do not schedule any neighboring decode")
    }

    static func waitForCached(_ files: [PhotoFile], cache: DisplayPhotoCache, hdr: Bool, maximum: Int?) async throws {
        let deadline = Date().addingTimeInterval(8)
        while true {
            var complete = true
            for file in files where await cache.cached(file, hdr: hdr, maximum: maximum) == nil { complete = false }
            if complete { return }
            guard Date() < deadline else { throw BrowserFailure.message("Neighbor cache warming timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func waitForPending(_ cache: DisplayPhotoCache, count: Int) async throws {
        let deadline = Date().addingTimeInterval(8)
        while await cache.statistics().pending != count {
            guard Date() < deadline else { throw BrowserFailure.message("Pending neighbor count timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func previewPreferenceChecks(root: URL, jpeg: Data) async throws {
        let suite = "PhotoBrowser-Store-Preferences-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("preferences-support"), defaults: defaults)
        try expect(store.previewBefore == 2 && store.previewAfter == 5, "store uses the configured two-before five-after defaults")
        store.previewBefore = 0; store.previewAfter = 8; store.thumbnailSize = 240
        let reopened = BrowserStore(supportDirectory: root.appendingPathComponent("preferences-reopened"), defaults: defaults)
        try expect(reopened.previewBefore == 0 && reopened.previewAfter == 8 && reopened.thumbnailSize == 240,
                   "reopened store preserves preload settings and filmstrip height")
        let url = root.appendingPathComponent("presentation.jpg"); try jpeg.write(to: url)
        let captures = (0..<12).map { index in
            PhotoAsset(id: "capture\(index)", name: "capture\(index)", files: [
                PhotoFile(url: root.appendingPathComponent("capture\(index).arw"), kind: .raw),
                PhotoFile(url: url, kind: .rendered)
            ])
        }
        store.assets = captures; store.focusedID = "capture4"; store.previewBefore = 2; store.previewAfter = 5
        let oldRaw = store.preferRawPreview
        defer { store.preferRawPreview = oldRaw }
        store.preferRawPreview = true
        try expect(store.adjacentPreviewFiles.map { $0.url.lastPathComponent } == ["capture5.arw", "capture3.arw", "capture6.arw", "capture2.arw", "capture7.arw", "capture8.arw", "capture9.arw"],
                   "store preloads the requested range using the RAW preference")
        store.groups = [PhotoGroup(id: "preview-group", name: "Preview", assetIDs: ["capture4", "capture6", "capture9"])]
        store.scope = "preview-group"
        try expect(store.adjacentPreviewFiles.map { $0.url.lastPathComponent } == ["capture6.arw", "capture9.arw"],
                   "preloading stays inside the current group")
        store.search = "capture4"
        try expect(store.adjacentPreviewFiles.isEmpty, "preloading respects filtered results")
        store.scope = "all"; store.search = ""; store.selectFolder(root)
        try expect(store.adjacentPreviewFiles.isEmpty, "folder selection stops photo preloading")

        let file = PhotoFile(url: url, kind: .rendered)
        let cached = try await DisplayPhotoCache.shared.image(file, hdr: true, maximum: 2800)
        let before = await DisplayPhotoCache.shared.statistics()
        let presentation = PreviewPresentation()
        await presentation.load(file, hdr: true, maximum: 2800) { _ in }
        let after = await DisplayPhotoCache.shared.statistics()
        try expect(presentation.photo?.image === cached.image && !presentation.loading && presentation.thumbnail == nil && before.decodes == after.decodes,
                   "presentation displays a memory hit without thumbnail loading or another decode")
        let canvas = CanvasView()
        canvas.configure(photo: cached, identity: file.id, hdr: true, zoom: 1)
        canvas.configure(photo: nil, identity: "next", hdr: true, zoom: 1)
        canvas.configure(photo: cached, identity: file.id, hdr: true, zoom: 1)
        try expect(canvas.device != nil, "one Metal canvas survives image changes and an empty loading state")
        await presentation.load(nil, hdr: true, maximum: 2800) { _ in }
        try expect(presentation.photo == nil && presentation.fileID == nil && !presentation.loading,
                   "empty selection clears previous photo state")

        let workers = PreviewWorkQueue(), isolated = DisplayPhotoCache(workers: workers)
        let browsing = try await isolated.image(file, hdr: true, maximum: 2800)
        let started = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let blockers = (0..<2).map { _ in Task.detached { try await workers.run { _ in
            started.signal()
            guard gate.wait(timeout: .now() + 5) == .success else { throw BrowserFailure.message("Native preview gate timed out") }
        } } }
        defer { gate.signal(); gate.signal() }
        let lanesReady = await Task.detached { waitForStart(started) && waitForStart(started) }.value
        try expect(lanesReady, "both native decode lanes are held for progressive preview checks")
        let fullscreen = PreviewPresentation(cache: isolated)
        let nativeLoad = Task { await fullscreen.load(file, hdr: true, maximum: nil) { _ in } }
        try await until { fullscreen.photo != nil }
        try expect(fullscreen.photo?.image === browsing.image && fullscreen.loading,
                   "fullscreen displays the cached browsing pixels before the blocked native original loads")
        let secondURL = root.appendingPathComponent("presentation-next.jpg"); try jpeg.write(to: secondURL)
        let secondFile = PhotoFile(url: secondURL, kind: .rendered)
        nativeLoad.cancel(); await nativeLoad.value
        gate.signal(); gate.signal()
        for blocker in blockers { try await blocker.value }
        await fullscreen.load(secondFile, hdr: true, maximum: 2800) { _ in }
        try expect(fullscreen.fileID == secondFile.id && fullscreen.photo != nil && !fullscreen.loading,
                   "cancelling an original load allows the latest photo to replace the cached fallback")

        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.identifier = NSUserInterfaceItemIdentifier("PhotoBrowser.Settings")
        defer { window.close() }
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
                                  charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        try expect(store.handleKeyDown(key, in: window) === key, "settings window keystrokes cannot operate on browser photos")
    }

    @MainActor static func deletionChecks(root: URL, jpeg: Data) async throws {
        let fm = FileManager.default, directory = root.appendingPathComponent("delete-photos")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        for name in ["A.jpg", "B.jpg", "C.jpg", "D.jpg"] { try jpeg.write(to: directory.appendingPathComponent(name)) }
        for name in ["A.arw", "A.hif", "A.xmp", "A.arw.xmp"] {
            try Data("original \(name)".utf8).write(to: directory.appendingPathComponent(name))
        }
        let cache = ThumbnailCache(directory: root.appendingPathComponent("deletion-cache"))
        let folderSummaries = FolderSummaryCache(directory: root.appendingPathComponent("deletion-summaries"))
        let folderSizes = FolderSizeCache(directory: root.appendingPathComponent("deletion-sizes"))
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("deletion-support"), thumbnails: cache,
                                 folderSummaries: folderSummaries, folderSizes: folderSizes)
        defer { store.cancelPreviewGeneration() }
        store.load(directory)
        try await until { !store.isLoading }
        let original = store.assets
        _ = try await folderSummaries.summary(of: directory); _ = try await folderSizes.size(of: directory)
        let firstGroup = PhotoGroup(id: "first-group", name: "First", assetIDs: ["a", "c", "d"])
        let secondGroup = PhotoGroup(id: "second-group", name: "Second", assetIDs: ["b"])
        store.groups = [firstGroup, secondGroup]
        try expect(store.directorySummary == L10n.text("\(4) 张照片 · \(6) 个图像文件 · \(2) 个分组"),
                   "directory summary counts paired captures and groups independently of operation messages")
        store.scope = secondGroup.id; store.changeScope()
        try expect(store.visibleAssets.count == 1 && store.directorySummary == L10n.text("\(4) 张照片 · \(6) 个图像文件 · \(2) 个分组"),
                   "viewing one group does not reduce the whole-directory totals")
        store.scope = "all"; store.changeScope()
        store.select(original[0], modifiers: []); store.select(original[1], modifiers: [.command])
        store.showGroupOverview = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func key(_ code: UInt16 = 51, repeating: Bool = false, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil,
                             characters: code == 117 ? "\u{f728}" : "\u{7f}",
                             charactersIgnoringModifiers: code == 117 ? "\u{f728}" : "\u{7f}",
                             isARepeat: repeating, keyCode: code)!
        }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        editor.isFieldEditor = true; editor.string = "path123"
        window.contentView = editor
        try expect(window.makeFirstResponder(editor), "text editor accepts focus for keyboard checks")
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        let backspace = key()
        try expect(store.handleKeyDown(backspace, in: window) === backspace && !store.isMoving,
                   "Backspace in an input field is not consumed by photo deletion")
        editor.keyDown(with: backspace)
        try expect(editor.string == "path12" && store.assets.count == 4,
                   "native Backspace deletes text and leaves every photo untouched")
        window.contentView = NSView(); window.makeFirstResponder(nil)
        let commandDelete = key(modifiers: [.command])
        try expect(store.handleKeyDown(commandDelete, in: window) === commandDelete && !store.isMoving,
                   "modified Delete does not trigger the plain deletion shortcut")
        try expect(store.handleKeyDown(backspace, in: nil) === backspace && !store.isMoving,
                   "keyboard events without a browser window cannot delete photos")
        store.isLoading = true
        try expect(store.handleKeyDown(backspace, in: window) === backspace && !store.isMoving,
                   "Delete does not operate while a folder is loading")
        store.isLoading = false
        store.selectFolder(root)
        _ = store.handleKeyDown(backspace, in: window)
        try expect(!store.canDeleteSelection && !store.isMoving && store.assets.count == 4,
                   "selecting a folder never deletes its contents or the previously focused photo")
        store.select(original[0], modifiers: []); store.select(original[1], modifiers: [.command])
        try expect(store.handleKeyDown(backspace, in: window) == nil && store.isMoving,
                   "Apple Backspace starts the selected photo move immediately")
        try await until { !store.isMoving }
        try expect(store.errorMessage == nil && store.assets.map(\.id) == ["c", "d"],
                   "Backspace moves both selected captures and removes them from the browser")
        let deletedSummary = try await folderSummaries.cached(of: directory), deletedSize = try await folderSizes.cached(of: directory)
        try expect(deletedSummary == nil && deletedSize == nil, "deletion invalidates cached source cover, count and size")
        let target = directory.appendingPathComponent("_del")
        let expectedFiles = original.filter { ["a", "b"].contains($0.id) }.flatMap(\.files)
        try expect(expectedFiles.count == 6 && expectedFiles.allSatisfy {
            !fm.fileExists(atPath: $0.url.path) && fm.fileExists(atPath: target.appendingPathComponent($0.url.lastPathComponent).path)
        }, "deletion includes RAW, HIF, JPEG, both XMP sidecar names, and the second capture")
        try expect(store.focusedID == "c" && store.selection == ["c"] && store.showGroupOverview,
                   "after deletion the next photo is selected without changing the browsing layout")
        try expect(store.groups.count == 1 && store.groups[0].assetIDs == ["c", "d"],
                   "deleted membership is removed and empty groups disappear")
        try expect(store.directorySummary == L10n.text("\(2) 张照片 · \(2) 个图像文件 · \(1) 个分组") && !store.status.isEmpty,
                   "directory counts update after deletion while its undo message remains visible")
        let firstRecord = store.history.first!
        _ = store.handleKeyDown(key(repeating: true), in: window)
        try expect(!store.isMoving && store.assets.count == 2,
                   "holding Backspace does not delete the automatically selected next photo")
        store.rename(store.groups[0], to: "Renamed while pending")
        store.scope = firstGroup.id; store.changeScope()
        try expect(store.directorySummary == L10n.text("\(2) 张照片 · \(2) 个图像文件 · \(1) 个分组"),
                   "directory summary remains the whole-directory count when a group is selected")
        try expect(store.handleKeyDown(key(117, modifiers: [.function]), in: window) == nil && store.isMoving,
                   "forward Delete / Fn-Backspace uses the same pending deletion action")
        try await until { !store.isMoving }
        try expect(store.errorMessage == nil && store.assets.map(\.id) == ["d"] && store.scope == firstGroup.id,
                   "consecutive deletion reuses _del and preserves the current group scope")
        let secondRecord = store.history.first!
        _ = try await folderSummaries.summary(of: directory); _ = try await folderSizes.size(of: directory)
        store.undo(firstRecord)
        try await until { !store.isMoving && !store.isLoading }
        try expect(store.errorMessage == nil && store.assets.map(\.id) == ["a", "b", "d"],
                   "undoing an earlier batch restores only that batch")
        let undoSummary = try await folderSummaries.cached(of: directory), undoSize = try await folderSizes.cached(of: directory)
        try expect(undoSummary == nil && undoSize == nil, "undo invalidates cached directory statistics before restoring the browser")
        try expect(store.groups.first { $0.id == firstGroup.id }?.assetIDs == ["a", "d"]
                   && store.groups.first { $0.id == firstGroup.id }?.name == "Renamed while pending"
                   && store.groups.first { $0.id == secondGroup.id }?.assetIDs == ["b"],
                   "undo restores original membership without reviving later deletions or overwriting group renames")
        try expect(fm.fileExists(atPath: target.appendingPathComponent("C.jpg").path),
                   "undo of one batch leaves other pending files in _del")
        store.undo(secondRecord)
        try await until { !store.isMoving && !store.isLoading }
        try expect(store.errorMessage == nil && store.assets.count == 4
                   && store.groups.first { $0.id == firstGroup.id }?.assetIDs == ["a", "c", "d"],
                   "undo of the remaining batch restores group order and all captures")
        try expect(store.directorySummary == L10n.text("\(4) 张照片 · \(6) 个图像文件 · \(2) 个分组"),
                   "undo restores the directory photo, file and group totals")
        try expect(store.groups.allSatisfy { $0.id != firstRecord.group.id && $0.id != secondRecord.group.id },
                   "undo does not create artificial deletion groups")
        _ = try await folderSummaries.summary(of: directory); _ = try await folderSizes.size(of: directory)
        let revision = store.folderCacheRevision
        store.refreshDirectory()
        try await until { store.folderCacheRevision != revision && !store.isLoading }
        let refreshedSummary = try await folderSummaries.cached(of: directory), refreshedSize = try await folderSizes.cached(of: directory)
        try expect(refreshedSummary == nil && refreshedSize == nil, "explicit refresh clears persisted folder caches without requiring the six-hour expiry")

        let marker = target.appendingPathComponent("a.XMP")
        try Data("existing pending sidecar".utf8).write(to: marker)
        store.select(store.assets[0], modifiers: [])
        _ = store.handleKeyDown(backspace, in: window)
        try await until { !store.isMoving }
        try expect(store.errorMessage != nil && store.assets.count == 4
                   && original.flatMap(\.files).allSatisfy { fm.fileExists(atPath: $0.url.path) }
                   && (try String(contentsOf: marker, encoding: .utf8)) == "existing pending sidecar",
                   "an XMP name conflict keeps the entire photo batch in place and preserves the prior file")
        try fm.removeItem(at: marker); store.errorMessage = nil
        store.selectAll(); store.isFullscreenPreview = true
        _ = store.handleKeyDown(backspace, in: window)
        try await until { !store.isMoving }
        try expect(store.assets.isEmpty && !store.isFullscreenPreview && store.focusedID == nil,
                   "deleting the last selected photos exits fullscreen and clears the preview")
        store.undo(store.history.first!)
        try await until { !store.isMoving && !store.isLoading }
        try expect(store.errorMessage == nil && store.assets.count == 4 && store.groups.count == 2,
                   "deleting every photo remains fully reversible")
        store.load(target)
        try await until { !store.isLoading }
        try expect(!store.canDeleteSelection, "photos already in _del cannot be nested into another _del")
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
