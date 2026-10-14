import AppKit
import ImageIO
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func navigationChecks(root: URL) async throws {
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("navigation-support"))
        let folders = [root.appendingPathComponent("folder-a"), root.appendingPathComponent("folder-b")]
        let photos = (0..<3).map { n in
            PhotoAsset(id: "photo-\(n)", name: "photo-\(n)", files: [
                PhotoFile(url: root.appendingPathComponent("photo-\(n).jpg"), kind: .rendered)
            ])
        }
        store.assets = photos; store.subdirectories = folders
        store.select(photos[0], modifiers: [])
        store.step(-1)
        try expect(store.selectedFolderID == folders[1].path && store.selection.isEmpty,
                   "left from first photo selects the preceding folder and clears photo selection")
        store.step(-1); store.step(-1)
        try expect(store.selectedFolderID == folders[0].path && store.selectedItemID == "folder:" + folders[0].path,
                   "folder navigation stops at the first folder and provides its scroll identity")
        try expect(store.navigationScrollTarget == store.selectedItemID, "keyboard selection scrolls its card into view")
        store.selectFolder(folders[0])
        try expect(store.navigationScrollTarget == nil, "mouse selection keeps the card still for a second click")
        store.step(1); store.step(1)
        try expect(store.selectedFolderID == nil && store.focusedID == photos[0].id && store.selection == [photos[0].id],
                   "right from last folder returns to the first photo even when its preview was already focused")
        store.step(1); store.step(1); store.step(1)
        try expect(store.focusedID == photos[2].id, "photo navigation stops at the last photo")
        store.select(photos[0], modifiers: [])
        store.step(1, extendingSelection: true); store.step(1, extendingSelection: true)
        try expect(store.selection == Set(photos.map(\.id)), "Shift-right extends selection across photos")
        store.step(-1, extendingSelection: true); store.step(-1, extendingSelection: true); store.step(-1, extendingSelection: true)
        try expect(store.selection == [photos[0].id] && store.selectedFolderID == nil,
                   "Shift-left contracts the range and stops before folders")
        store.scope = "ungrouped"; store.changeScope(); store.step(-1)
        try expect(store.selectedFolderID == nil && store.focusedID == photos[0].id,
                   "ungrouped scope does not navigate hidden folder cards")
        store.groups = [PhotoGroup(id: "group", name: "group", assetIDs: [photos[2].id, photos[0].id])]
        store.scope = "group"; store.changeScope(); store.step(1)
        try expect(store.focusedID == photos[0].id && store.selectedFolderID == nil,
                   "group navigation follows group order and excludes folders")
        store.scope = "all"; store.changeScope(); store.isFullscreenPreview = true; store.step(-1)
        try expect(store.focusedID == photos[0].id && store.selectedFolderID == nil,
                   "fullscreen navigation remains within photos")
        store.isFullscreenPreview = false; store.assets = []; store.focusedID = nil; store.selection = []
        store.step(1); store.step(1)
        try expect(store.selectedFolderID == folders[1].path, "directories without photos remain keyboard navigable")
        try FileManager.default.createDirectory(at: folders[1], withIntermediateDirectories: true)
        store.openSelectedFolder()
        try await until { !store.isLoading }
        try expect(store.directory?.path == folders[1].path && store.selectedFolderID == nil && store.errorMessage == nil,
                   "opening selected folder loads it and clears the old selection")
        store.cancelPreviewGeneration()
    }

    @MainActor static func formatPreferenceChecks(root: URL) throws {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "preferRawPreview")
        defer { if let previous { defaults.set(previous, forKey: "preferRawPreview") } else { defaults.removeObject(forKey: "preferRawPreview") } }
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("format-support"))
        let raw = PhotoFile(url: root.appendingPathComponent("paired.ARW"), kind: .raw)
        let hif = PhotoFile(url: root.appendingPathComponent("paired.HIF"), kind: .rendered)
        let jpg = PhotoFile(url: root.appendingPathComponent("paired.JPG"), kind: .rendered)
        let pair = PhotoAsset(id: "pair", name: "pair", files: [raw, hif, jpg])
        let rawOnly = PhotoAsset(id: "raw-only", name: "raw-only", files: [raw])
        let jpgOnly = PhotoAsset(id: "jpg-only", name: "jpg-only", files: [jpg])
        store.assets = [pair, rawOnly, jpgOnly]; store.select(pair, modifiers: [])
        store.preferRawPreview = false
        try expect(store.focusedFile?.id == hif.id, "rendered preference previews the paired HIF")
        store.preferRawPreview = true
        try expect(store.focusedFile?.id == raw.id, "RAW preference selects the RAW original")
        store.preferredFileID = jpg.id
        try expect(store.focusedFile?.id == jpg.id, "manual format selection overrides the global preference for this photo")
        store.preferRawPreview = false
        try expect(store.preferredFileID == nil && store.focusedFile?.id == hif.id, "changing preference clears the current format override")
        store.select(rawOnly, modifiers: [])
        try expect(store.focusedFile?.id == raw.id, "rendered preference falls back to RAW when no rendered photo exists")
        store.preferRawPreview = true; store.select(jpgOnly, modifiers: [])
        try expect(store.focusedFile?.id == jpg.id, "RAW preference falls back to JPEG when no RAW exists")
        store.select(pair, modifiers: [])
        try expect(store.focusedFile?.id == raw.id, "navigation uses the global preference for the next photo")
        try expect(BrowserStore(supportDirectory: root.appendingPathComponent("format-reload")).preferRawPreview,
                   "RAW preference is remembered by a new browser")
    }

}
