import AppKit
import BrowserCore

extension BrowserStore {
    func toggleLivePhotoPlayback(_ asset: PhotoAsset? = nil) {
        guard !isMoving, !isLoading, let target = asset ?? focusedAsset, target.isLivePhoto else { return }
        if livePhotoMotionID == target.id { video.stop(); livePhotoMotionID = nil; return }
        select(target, modifiers: [])
        startLivePhotoPlayback(target)
    }
    func startLivePhotoPlayback(_ asset: PhotoAsset) {
        guard !isMoving, !isLoading, focusedID == asset.id, selectedFolderID == nil,
              let file = asset.mediaFiles.first(where: \.isLivePhoto) else { return }
        showGroupOverview = false
        if livePhotoMotionID == asset.id {
            if video.fileID == file.id, !video.loading, !video.isPlaying { video.toggle() }
            return
        }
        livePhotoMotionID = asset.id
        video.playWhenReady(file)
    }
    func toggleFullscreenPreview() {
        guard !isMoving, selectedFolderID == nil, focusedFile != nil else { return }
        if isFullscreenPreview { closeFullscreenPreview(); return }
        previewWindow = NSApp.keyWindow
        enteredFullscreen = previewWindow?.styleMask.contains(.fullScreen) == false
        isFullscreenPreview = true
        if enteredFullscreen { previewWindow?.toggleFullScreen(nil) }
    }

    func toggleVideoPlayback() {
        guard !isMoving, !isLoading, selectedFolderID == nil, let file = playbackFile else { return }
        if showGroupOverview { showGroupOverview = false; video.playWhenReady(file) }
        else if video.fileID == file.id { video.toggle() }
        else { video.playWhenReady(file) }
    }

    func playVideo(_ asset: PhotoAsset) {
        guard asset.isVideo, !isMoving, !isLoading else { return }
        select(asset, modifiers: []); showGroupOverview = false; video.playWhenReady(asset.preferred)
    }
    func closeFullscreenPreview() {
        isFullscreenPreview = false
        if enteredFullscreen, previewWindow?.styleMask.contains(.fullScreen) == true { previewWindow?.toggleFullScreen(nil) }
        enteredFullscreen = false
    }
    func fullscreenWindowExited() { isFullscreenPreview = false; enteredFullscreen = false }
}
