import AppKit
import AVFoundation
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func videoPlaybackChecks() async throws {
        let suite = "VideoPlaybackChecks-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let savedDirectory = UserDefaults.standard.object(forKey: "lastDirectory")
        defer {
            if let savedDirectory { UserDefaults.standard.set(savedDirectory, forKey: "lastDirectory") }
            else { UserDefaults.standard.removeObject(forKey: "lastDirectory") }
        }
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("VideoPlayback-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("clip.mp4")
        try await VideoFixture.create(at: url)
        let file = PhotoFile(url: url, kind: .video)
        let playback = VideoPlayback(defaults: defaults)
        await playback.load(file)
        try await until { !playback.loading }
        try expect(playback.failure == nil && playback.player.currentItem?.status == .readyToPlay, "native video player reaches ready state")
        playback.toggle(); try await until { playback.isPlaying }
        playback.toggle(); try await until { !playback.isPlaying }
        try expect(playback.player.rate == 0, "video playback toggles between play and pause")
        let item = playback.player.currentItem
        await playback.load(file)
        try expect(playback.player.currentItem === item, "the same video player item survives preview layout changes")
        playback.stop()
        try expect(playback.fileID == nil && playback.player.currentItem == nil && playback.player.rate == 0, "stopping video releases the old player item")
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"), defaults: defaults)
        store.assets = try DirectoryScanner.scan(root)
        store.focusedID = store.assets[0].id; store.selection = [store.assets[0].id]
        try expect(store.focusedFile?.kind == .video && store.directorySummary.contains("1"), "video-only directories have a focused media file and status counts")
        try expect(store.adjacentPreviewFiles.isEmpty, "videos are not sent through still-image preloading")
        let videoID = store.focusedID!
        var legacyMetadata = PhotoMetadata()
        legacyMetadata.duration = 2; legacyMetadata.frameRate = 10
        store.updateMetadata(videoID, value: legacyMetadata)
        var enrichedMetadata = legacyMetadata
        enrichedMetadata.bitRate = 56_320_000
        store.updateMetadata(videoID, value: enrichedMetadata)
        try expect(store.focusedAsset?.metadata?.bitRate == enrichedMetadata.bitRate && store.focusedAsset?.metadata?.duration == 2,
                   "video inspector enriches existing session metadata with bitrate")
        await store.video.load(store.focusedFile!); try await until { !store.video.loading }
        let selectedItem = store.video.player.currentItem
        store.preferredFileID = store.focusedFile!.id
        try expect(store.video.player.currentItem === selectedItem, "selecting the current video format does not clear its player")
        store.toggleFullscreenPreview(); store.closeFullscreenPreview()
        try expect(store.video.player.currentItem === selectedItem, "entering and exiting fullscreen preserves the player item")
        store.selectFolder(root)
        try expect(store.video.player.currentItem == nil, "selecting a folder stops the previously playing video")
        store.selectedFolderID = nil; store.focusedID = store.assets[0].id
        await store.video.load(store.focusedFile!); store.focusedID = nil
        try expect(store.video.player.currentItem == nil, "changing selection stops video immediately")
        let bad = PhotoFile(url: root.appendingPathComponent("missing.mp4"), kind: .video)
        await playback.load(bad)
        try expect(playback.failure != nil && playback.player.currentItem == nil, "unsupported or missing videos have an explicit playback error")
        let switching = Task { await playback.load(file) }
        await Task.yield(); playback.stop(); await switching.value
        try expect(playback.fileID == nil && playback.player.currentItem == nil, "obsolete video loads cannot reopen a stopped player")
        try Data("video sidecar".utf8).write(to: root.appendingPathComponent("clip.mp4.xmp"))
        store.directory = root; store.assets = try DirectoryScanner.scan(root)
        let video = store.assets[0]
        store.focusedID = video.id; store.selection = [video.id]
        await store.video.load(video.preferred); try await until { !store.video.loading }
        let board = NSPasteboard(name: .init("VideoCopy-" + UUID().uuidString))
        defer { board.releaseGlobally(); store.cancelPreviewGeneration() }
        store.copyFilesToClipboard(pasteboard: board)
        try expect(board.pasteboardItems?.count == 2, "copying a video includes its matching XMP file")
        store.deleteSelection(); try await until { !store.isMoving }
        try expect(store.video.player.currentItem == nil && fm.fileExists(atPath: root.appendingPathComponent("_del/clip.mp4").path)
                   && fm.fileExists(atPath: root.appendingPathComponent("_del/clip.mp4.xmp").path), "deleting video stops playback and safely moves video and sidecar to _del")
        guard let record = store.history.first else { throw BrowserFailure.message("video deletion history missing") }
        store.undo(record); try await until { !store.isMoving && !store.isLoading }
        try expect(store.assets.contains(where: \.isVideo) && fm.fileExists(atPath: url.path), "video deletion can be undone and restores the independent video asset")
    }
}
