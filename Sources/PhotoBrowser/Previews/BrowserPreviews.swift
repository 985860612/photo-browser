import AppKit
import BrowserCore

extension BrowserStore {
    func cancelPreviewGeneration(stopVideo: Bool = true) {
        cancelSortDates()
        if stopVideo { video.stop() }
        previewCoordinator.cancel()
    }

    func startPreviewGeneration() {
        cancelPreviewGeneration(stopVideo: false)
        guard !isMoving, !isLoading, !assets.isEmpty else { return }
        previewCoordinator.start(files: assets.map(\.preferred), priority: visibleAssets.prefix(48).map(\.preferred))
    }

    func prioritizePreviews(_ files: [PhotoFile]) { previewCoordinator.prioritize(files) }

    func previewAppeared(_ asset: PhotoAsset) {
        guard isGeneratingPreviews, let index = visibleIndex(of: asset.id) else { return }
        previewCoordinator.prioritize(around: index, in: visibleAssets)
    }

}
