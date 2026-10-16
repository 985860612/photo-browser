import AppKit
import BrowserCore

extension BrowserStore {
    func changeScope() {
        guard !isMoving else { return }
        selectedFolderID = nil
        selection = []; focusedID = visibleAssets.first?.id; preferredFileID = nil
        if let focusedID { selection = [focusedID] }
        showGroupOverview = currentGroup != nil
        selectionAnchorID = focusedID; rangeSelectionBase = nil
        navigationScrollTarget = selectedItemID
        prioritizePreviews(visibleAssets.prefix(48).map(\.preferred))
    }

    func selectFolder(_ url: URL) {
        livePhotoMotionID = nil
        video.stop()
        guard !isMoving, !isLoading else { return }
        navigationScrollTarget = nil
        selectedFolderID = url.path
        selection = []; selectionAnchorID = nil; rangeSelectionBase = nil
    }

    func select(_ asset: PhotoAsset, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        let singleSelection = modifiers.intersection([.command, .shift]).isEmpty
        let keepMotion = singleSelection && livePhotoMotionID == asset.id
        if !keepMotion {
            if livePhotoMotionID != nil { video.stop() }
            livePhotoMotionID = nil
        }
        navigationScrollTarget = nil
        selectedFolderID = nil
        let list = visibleAssets
        if modifiers.contains(.shift), let b = visibleIndex(of: asset.id) {
            let anchor = selectionAnchorID ?? focusedID ?? asset.id
            let a = visibleIndex(of: anchor) ?? visibleIndex(of: focusedID) ?? b
            selectionAnchorID = list[a].id
            let visibleIDs = Set(list.map(\.id))
            let base = (rangeSelectionBase ?? selection).intersection(visibleIDs)
            rangeSelectionBase = base
            selection = base.union(list[min(a,b)...max(a,b)].map(\.id))
        } else if modifiers.contains(.command) {
            if selection.contains(asset.id) { selection.remove(asset.id) } else { selection.insert(asset.id) }
            selectionAnchorID = asset.id; rangeSelectionBase = nil
        } else {
            selection = [asset.id]
            selectionAnchorID = asset.id; rangeSelectionBase = nil
        }
        focusedID = asset.id; preferredFileID = nil
        if singleSelection, selection == [asset.id] {
            startLivePhotoPlayback(asset)
        }
    }

    func step(_ offset: Int, extendingSelection: Bool = false) {
        guard !isMoving, !isLoading else { return }
        let list = visibleAssets
        // Fullscreen and range selection operate on photos; normal browsing follows every displayed item.
        let folders = scope == "all" && !isFullscreenPreview && !extendingSelection ? navigationEntries : []
        let total = folders.count + list.count
        guard total > 0 else { return }
        let index: Int?
        if let folder = selectedFolderID, let position = folders.firstIndex(where: { $0.path == folder }) {
            index = position
        } else if selectedFolderID == nil, let position = visibleIndex(of: focusedID) {
            index = folders.count + position
        } else { index = nil }
        let next = index.map { max(0, min(total - 1, $0 + offset)) } ?? 0
        if next < folders.count { selectFolder(folders[next]) }
        else { select(list[next - folders.count], modifiers: extendingSelection ? [.shift] : []) }
        navigationScrollTarget = selectedItemID
    }

    func openSelectedFolder() {
        guard !isMoving, !isLoading, let path = selectedFolderID,
              let url = navigationEntries.first(where: { $0.path == path }) else { return }
        load(url)
    }

    func selectAll() {
        selectedFolderID = nil
        selection = Set(visibleAssets.map(\.id))
        selectionAnchorID = focusedID; rangeSelectionBase = nil
    }

}
