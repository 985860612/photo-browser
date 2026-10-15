import AppKit
import BrowserCore

extension BrowserStore {
    func updateAdjacentReadiness() async {
        let files = selectedFolderID == nil && !isLoading && !isMoving && focusedFile != nil ? adjacentPreviewFiles : []
        let videos = selectedFolderID == nil && !isLoading && !isMoving ? adjacentVideoFiles : []
        await previewCoordinator.updateReadiness(request: previewRequestID, neighbors: files, videos: videos,
                                                 hdr: hdrPreview, maximum: isFullscreenPreview ? nil : 2800)
    }
    func updateCacheStatus() async {
        diagnostics = PreviewDiagnostics.shared.snapshot()
        previewStatistics = await displayCache.statistics()
        do {
            diskUsage = try await thumbnails.diskUsage(); cacheFailure = await thumbnails.diskMaintenanceError()
            livePhotoDiskUsage = try await clipboardWorkers.run(background: true) { _ in try LivePhotoCache.shared.usage() }
        }
        catch is CancellationError {}
        catch { cacheFailure = error.localizedDescription }
    }
    func applyDiskLimit() async {
        guard !cacheBusy else { return }
        cacheBusy = true; defer { cacheBusy = false }
        do {
            var applied: Int
            repeat {
                applied = diskLimitGB
                try await thumbnails.setDiskLimit(Int64(applied) * 1_000_000_000)
            } while applied != diskLimitGB && !Task.isCancelled
            await updateCacheStatus()
        }
        catch is CancellationError {}
        catch { cacheFailure = error.localizedDescription }
    }
    func clearPreviewCaches() async {
        guard !cacheBusy else { return }
        cacheBusy = true; defer { cacheBusy = false }
        // Retain the displayed image/player; stop warming so clear does not immediately refill the cache.
        cancelPreviewGeneration(stopVideo: false)
        await displayCache.removeAll()
        do {
            try await thumbnails.clear()
            try await clipboardWorkers.run(background: true) { _ in try LivePhotoCache.shared.clear() }
            await updateCacheStatus()
        }
        catch { cacheFailure = error.localizedDescription }
    }
}
