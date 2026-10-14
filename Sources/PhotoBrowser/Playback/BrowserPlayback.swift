import AppKit
import BrowserCore

extension BrowserStore {
    func toggleFullscreenPreview() {
        guard !isMoving, selectedFolderID == nil, focusedFile != nil else { return }
        if isFullscreenPreview { closeFullscreenPreview(); return }
        previewWindow = NSApp.keyWindow
        enteredFullscreen = previewWindow?.styleMask.contains(.fullScreen) == false
        isFullscreenPreview = true
        if enteredFullscreen { previewWindow?.toggleFullScreen(nil) }
    }

    func toggleVideoPlayback() {
        guard !isMoving, !isLoading, selectedFolderID == nil, let file = focusedFile, file.kind == .video else { return }
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
