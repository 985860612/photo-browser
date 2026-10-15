import AppKit
import AVFoundation
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func livePhotoPlaybackChecks() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("LivePlayback-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "LivePlayback-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { try? fm.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let archive = root.appendingPathComponent("live.livp"), still = root.appendingPathComponent("still.livp")
        try await LivePhotoFixture.create(at: archive)
        try await LivePhotoFixture.create(at: still, movie: false)
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"), defaults: defaults)
        defer { store.video.stop(); store.cancelPreviewGeneration() }
        store.directory = root; store.assets = try DirectoryScanner.scan(root)
        let live = store.assets.first { $0.name == "live" }!, staticPhoto = store.assets.first { $0.name == "still" }!
        store.select(live, modifiers: [])
        try expect(store.playbackFile?.isLivePhoto == true && !store.showGroupOverview, "selecting a LIVP opens its motion preview automatically")
        try expect(store.playbackFile?.id == live.preferred.id, "Live Photo playback retains the original archive identity")
        await store.video.load(store.playbackFile!); try await until { !store.video.loading }
        try expect(store.video.failure == nil && store.video.player.currentItem?.status == .readyToPlay, "LIVP motion reaches the native player's ready state")
        try await until { store.video.isPlaying }
        store.toggleVideoPlayback(); try await until { !store.video.isPlaying }
        store.toggleVideoPlayback(); try await until { store.video.isPlaying }
        try expect(store.video.player.rate != 0, "the playback command pauses and resumes Live Photo motion")
        let movieURL = (store.video.player.currentItem!.asset as! AVURLAsset).url
        try LivePhotoCache.shared.clear()
        try expect(fm.fileExists(atPath: movieURL.path), "clearing caches keeps a playing Live Photo available")
        let playingItem = store.video.player.currentItem
        store.select(live, modifiers: [])
        try expect(store.video.player.currentItem === playingItem, "reselecting the current Live Photo keeps its player")
        store.video.pause(); store.select(live, modifiers: [])
        try await until { store.video.isPlaying }
        try expect(store.video.player.currentItem === playingItem, "selecting a paused Live Photo resumes its existing player")
        store.select(staticPhoto, modifiers: [.command])
        try expect(store.playbackFile == nil && store.video.player.currentItem == nil, "multiple selection stops Live Photo playback without starting another")
        store.select(live, modifiers: [])
        await store.video.load(store.playbackFile!); try await until { !store.video.loading }
        store.toggleLivePhotoPlayback()
        try expect(store.playbackFile == nil && store.video.player.currentItem == nil, "returning to the photo releases the motion player")
        store.select(live, modifiers: [])
        store.isFullscreenPreview = true
        await store.video.load(store.playbackFile!); try await until { !store.video.loading }
        let completedItem = store.video.player.currentItem!
        try await until { store.playbackFile == nil }
        try expect(store.video.player.currentItem == nil && store.focusedID == live.id && store.selection == [live.id]
                   && store.isFullscreenPreview, "natural Live Photo completion returns to the still photo without changing selection or fullscreen")
        store.select(live, modifiers: [])
        await store.video.load(store.playbackFile!); try await until { !store.video.loading }
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: completedItem)
        try await Task.sleep(for: .milliseconds(30))
        try expect(store.playbackFile != nil && store.video.player.currentItem !== completedItem,
                   "an old completion notification cannot close a replayed Live Photo")
        store.toggleLivePhotoPlayback(); store.isFullscreenPreview = false
        store.step(1)
        try expect(store.playbackFile?.id == staticPhoto.preferred.id, "keyboard selection automatically starts the next Live Photo")
        await store.video.load(store.playbackFile!)
        try expect(store.video.failure != nil && store.video.player.currentItem == nil, "a LIVP without motion shows an explicit playback error")
        store.select(live, modifiers: [])
        let board = NSPasteboard(name: .init("LiveCopy-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        store.copyFilesToClipboard(pasteboard: board)
        let copied = board.readObjects(forClasses: [NSURL.self]) as? [URL]
        try expect(copied?.map { $0.resolvingSymlinksInPath().path } == [live.preferred.url.resolvingSymlinksInPath().path], "copying Live Photos copies the original LIVP rather than extracted members")
        store.deleteSelection(); try await until { !store.isMoving && !store.isLoading }
        try expect(fm.fileExists(atPath: root.appendingPathComponent("_del/live.livp").path) && !fm.fileExists(atPath: archive.path), "pending deletion moves the complete LIVP archive")
        try LivePhotoCache.shared.clear()
        let regularURL = root.appendingPathComponent("regular.mp4")
        try await VideoFixture.create(at: regularURL)
        let playback = VideoPlayback(defaults: defaults), regular = PhotoFile(url: regularURL, kind: .video)
        var liveCompletions = 0
        playback.livePhotoEnded = { _ in liveCompletions += 1 }
        await playback.load(regular); try await until { !playback.loading }
        let regularItem = playback.player.currentItem!
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: regularItem)
        try await Task.sleep(for: .milliseconds(30))
        try expect(liveCompletions == 0 && playback.player.currentItem === regularItem && playback.fileID == regular.id,
                   "ordinary video completion keeps its player and does not trigger a Live Photo return")
        playback.stop()
    }
}
