import AppKit
import ImageIO
import BrowserCore

extension PreviewStoreChecks {
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

    @MainActor static func adjacentDecodeChecks(root: URL, jpeg: Data) async throws {
        let workers = PreviewWorkQueue(), cache = DisplayPhotoCache(memoryBudget: 16 * 1024 * 1024, workers: workers)
        let suite = "AdjacentDecode-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defaults.set(1, forKey: "previewDecodeConcurrency")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("neighbor-support"), defaults: defaults, displayCache: cache)
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
        try await until { store.adjacentReady == 7 }
        try expect(store.adjacentTotal == 7, "coordinator publishes readiness for the full configured neighbor range")
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

}
