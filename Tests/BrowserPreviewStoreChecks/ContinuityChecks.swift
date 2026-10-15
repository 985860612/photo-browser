import AppKit
import AVFoundation
import ImageIO
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func continuityChecks() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("Continuity-" + UUID().uuidString)
        let directory = root.appendingPathComponent("photos")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Continuity-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let image = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        let data = NSMutableData(), destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination), "continuity JPEG fixture created")
        for n in 0..<10 { try (data as Data).write(to: directory.appendingPathComponent("photo\(n).jpg")) }
        let thumbs = ThumbnailCache(directory: root.appendingPathComponent("cache")), cache = DisplayPhotoCache(memoryBudget: 32 * 1024 * 1024)
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"), thumbnails: thumbs, defaults: defaults, displayCache: cache)
        defer { store.stopDirectoryObservation(); store.cancelPreviewGeneration() }
        await store.applyDecodeConcurrency()
        let initialConcurrency = await cache.decodeConcurrency
        try expect(store.previewDecodeConcurrency == 4 && initialConcurrency == 4,
                   "browser uses four background decoders with fresh settings")
        let beforeConcurrencyRequest = store.previewRequestID
        store.previewDecodeConcurrency = 2; await store.applyDecodeConcurrency()
        let concurrencyCache = DisplayPhotoCache(memoryBudget: 1024 * 1024)
        let concurrencyReopened = BrowserStore(supportDirectory: root.appendingPathComponent("concurrency-support"), defaults: defaults,
                                               displayCache: concurrencyCache, monitoringEnabled: false)
        await concurrencyReopened.applyDecodeConcurrency()
        let restoredConcurrency = await concurrencyCache.decodeConcurrency
        try expect(concurrencyReopened.previewDecodeConcurrency == 2 && restoredConcurrency == 2
                   && store.previewRequestID == beforeConcurrencyRequest,
                   "decode settings restore after reopening and changing the limit does not restart the visible image")
        store.previewDecodeConcurrency = 99; await store.applyDecodeConcurrency()
        let boundedConcurrency = await cache.decodeConcurrency
        try expect(store.previewDecodeConcurrency == 8 && boundedConcurrency == 8
                   && defaults.integer(forKey: "previewDecodeConcurrency") == 8, "out-of-range concurrency is bounded, applied and saved")
        store.previewDecodeConcurrency = 4; await store.applyDecodeConcurrency()
        store.load(directory)
        try await until { !store.isLoading && store.directoryObserver != nil && store.automaticRefreshTask == nil }
        store.diskLimitGB = 3; await store.applyDiskLimit()
        let reopenedSettings = BrowserStore(supportDirectory: root.appendingPathComponent("settings-support"), defaults: defaults, monitoringEnabled: false)
        try expect(reopenedSettings.diskLimitGB == 3 && store.diskUsage?.limit == 3_000_000_000,
                   "disk quota applies in bytes and persists across store recreation")
        store.focusedID = store.assets[4].id; store.selection = [store.assets[4].id]
        await store.preparePreviewCache()
        try await until { store.adjacentReady == 7 }
        try expect(store.adjacentTotal == 7 && store.adjacentReady == 7, "preload readiness reflects all two previous and five next resident images")
        await cache.releaseNeighbors(); await store.updateAdjacentReadiness()
        try expect(store.adjacentReady < store.adjacentTotal, "preload readiness decreases when memory pressure evicts neighbors")
        let preview = PreviewPresentation(cache: cache, thumbnails: thumbs)
        PreviewDiagnostics.shared.reset()
        await preview.load(store.focusedFile, hdr: false, maximum: 2800) { _ in }
        let cold = PreviewDiagnostics.shared.snapshot()
        try expect(cold.requests == 1 && cold.hits == 0 && cold.samples.last?.timing != nil,
                   "cold foreground preview records source, decode and queue durations")
        let timing = cold.samples.last!.timing!
        try expect(timing.queue >= 0 && timing.source >= 0 && timing.decode > 0, "diagnostic phase durations measure completed decode work")
        await preview.load(store.focusedFile, hdr: false, maximum: 2800) { _ in }
        try expect(PreviewDiagnostics.shared.snapshot().hits == 1, "cached foreground preview records a hit without another decode")
        for _ in 0..<110 { _ = PreviewDiagnostics.shared.begin(store.focusedFile!) }
        try expect(PreviewDiagnostics.shared.snapshot().samples.count == 100, "diagnostics retain a bounded recent history")

        let selected = store.focusedID!, group = PhotoGroup(name: "manual", assetIDs: [store.assets[4].id, store.assets[5].id])
        store.groups = [group]; store.scope = group.id; store.search = "photo"
        store.selection = Set(group.assetIDs)
        let navigation = store.navigationHistory, original = store.focusedFile!
        try Data("sidecar".utf8).write(to: directory.appendingPathComponent("photo4.xmp"))
        try (data as Data).write(to: directory.appendingPathComponent("new.jpg"))
        try await until { store.assets.count == 11 && store.focusedAsset?.files.count == 2 }
        try expect(await cache.cached(original, hdr: false, maximum: 2800) == nil,
                   "an XMP-only change invalidates decoded pixels even when the paired image fingerprint is unchanged")
        try expect(store.focusedID == selected && store.selection == Set(group.assetIDs) && store.scope == group.id && store.search == "photo"
                   && store.groups.first?.assetIDs == group.assetIDs && store.navigationHistory == navigation,
                   "external additions and sidecars update without resetting selection, group, search or navigation")
        try fm.setAttributes([.modificationDate: original.modified.addingTimeInterval(5)], ofItemAtPath: original.url.path)
        try await until { store.focusedFile?.modified != original.modified }
        try expect(store.focusedID == selected, "in-place changes to the focused file refresh its fingerprint")
        try fm.removeItem(at: directory.appendingPathComponent("photo5.jpg"))
        try await until { store.groups.first?.assetIDs.count == 1 }
        try expect(store.groups.first?.assetIDs == [selected], "external removals prune missing membership without losing the remaining group")
        let newURL = directory.appendingPathComponent("new.jpg")
        let previous = store.assets.first { $0.id == "new" }!.preferred
        try fm.setAttributes([.modificationDate: previous.modified.addingTimeInterval(5)], ofItemAtPath: newURL.path)
        store.directoryObserver?.stop()
        store.directoryObserver = try await DirectoryObserver(directory: directory, pollInterval: 0.05,
            changed: { full in store.scheduleAutomaticRefresh(full: full) }, failure: { error in store.reportObservationFailure(error) })
        store.observeFocusedFiles()
        store.scheduleAutomaticRefresh(full: true)
        try await until { store.assets.first { $0.id == "new" }!.preferred.modified != previous.modified }
        try expect(true, "explicit reconciliation detects edits to non-focused files without periodic full scans")
        await store.clearPreviewCaches()
        let usage = try await thumbs.diskUsage()
        try expect(usage.entries == 0 && !store.isGeneratingPreviews && store.groups.first?.id == group.id && fm.fileExists(atPath: original.url.path),
                   "cache clearing stops warming and preserves sources and groups")
        let other = root.appendingPathComponent("other"); try fm.createDirectory(at: other, withIntermediateDirectories: true)
        store.load(other); try await until { !store.isLoading && store.automaticRefreshTask == nil }
        try (data as Data).write(to: directory.appendingPathComponent("old-event.jpg"))
        try await Task.sleep(for: .milliseconds(900))
        try expect(store.directory?.path == other.standardizedFileURL.path && store.assets.isEmpty, "events from a previously opened directory cannot replace the current directory")
        try (data as Data).write(to: other.appendingPathComponent("incoming.jpg"))
        try await until { store.assets.count == 1 && store.focusedAsset?.id == "incoming" }
        try expect(store.selection == ["incoming"], "a formerly empty directory automatically presents newly arriving media")
        try await videoMemoryChecks(root: root, defaults: defaults)
    }

    @MainActor static func videoMemoryChecks(root: URL, defaults: UserDefaults) async throws {
        let url = root.appendingPathComponent("resume.mp4")
        try await VideoFixture.create(at: url)
        let file = PhotoFile(url: url, kind: .video, size: 100, modified: Date(timeIntervalSince1970: 1))
        let playback = VideoPlayback(defaults: defaults)
        defer { playback.stop(); playback.cancelPreparation() }
        let previousView = Task { await playback.load(file) }
        await Task.yield(); previousView.cancel()
        await playback.load(file); await previousView.value
        try await until { !playback.loading && playback.player.currentItem != nil }
        try expect(playback.failure == nil, "a replacement view can take over the same video during cancelled preflight")
        await playback.load(file); try await until { !playback.loading }
        await playback.player.seek(to: CMTime(seconds: 0.8, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playback.player.volume = 0.3; playback.player.isMuted = true; playback.pause(); playback.stop()
        let reopened = VideoPlayback(defaults: defaults)
        defer { reopened.stop(); reopened.cancelPreparation() }
        await reopened.load(file); try await until { !reopened.loading }
        try expect(abs(CMTimeGetSeconds(reopened.player.currentTime()) - 0.8) < 0.05 && reopened.player.rate == 0,
                   "video position survives player recreation and restores before playback")
        try expect(abs(reopened.player.volume - 0.3) < 0.01 && reopened.player.isMuted, "video volume and mute survive reopening")
        reopened.stop(); reopened.prepareNeighbors([file])
        try await until { reopened.preparedCount == 1 }
        try expect(reopened.player.currentItem == nil && reopened.player.rate == 0, "neighbor preparation loads metadata without creating or playing a player item")
        reopened.playWhenReady(file); await reopened.load(file); try await until { !reopened.loading && reopened.isPlaying }
        try expect(reopened.preparedCount == 0 && CMTimeGetSeconds(reopened.player.currentTime()) >= 0.75, "selection consumes prepared video information and autoplays only after restoring position")
        reopened.pause()
        let changed = PhotoFile(url: file.url, kind: .video, size: 101, modified: file.modified.addingTimeInterval(1))
        await reopened.load(changed); try await until { !reopened.loading }
        try expect(CMTimeGetSeconds(reopened.player.currentTime()) < 0.1, "replaced video content does not inherit an obsolete saved position")
        await reopened.player.seek(to: CMTime(seconds: 1.95, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        reopened.stop(); await reopened.load(changed); try await until { !reopened.loading }
        try expect(CMTimeGetSeconds(reopened.player.currentTime()) < 0.1, "completed videos reopen at the beginning")
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("video-support"),
                                 thumbnails: ThumbnailCache(directory: root.appendingPathComponent("video-cache")), defaults: defaults, monitoringEnabled: false)
        defer { store.cancelPreviewGeneration() }
        store.assets = [PhotoAsset(id: "video", name: "resume", files: [file])]; store.focusedID = "video"
        store.video.playWhenReady(file); await store.video.load(file)
        try await until { !store.video.loading && store.video.isPlaying }
        let currentItem = store.video.player.currentItem
        let neighborURL = root.appendingPathComponent("neighbor.mp4")
        try FileManager.default.copyItem(at: url, to: neighborURL)
        store.assets.append(PhotoAsset(id: "neighbor", name: "neighbor", files: [PhotoFile(url: neighborURL, kind: .video)]))
        await store.preparePreviewCache(); try await until { store.video.preparedCount == 1 }
        await store.updateAdjacentReadiness()
        try expect(store.adjacentVideoReady == 1 && store.adjacentVideoTotal == 1, "video metadata preparation has visible readiness counts")
        await store.clearPreviewCaches()
        try expect(store.video.player.currentItem === currentItem && store.video.player.rate > 0,
                   "clearing preview caches retains the current video item and playback")
    }
}
