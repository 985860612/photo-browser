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
        guard isGeneratingPreviews else { return }
        let list = visibleAssets
        guard let index = list.firstIndex(where: { $0.id == asset.id }) else { return }
        // Warm the following screenful before the user scrolls into it.
        prioritizePreviews(list[max(0, index - 4)..<min(list.count, index + 25)].map(\.preferred))
    }

}
