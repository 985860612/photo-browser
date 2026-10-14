import AppKit
import ImageIO
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func permanentMediaDeletionChecks() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("MediaDeletion-" + UUID().uuidString)
        let parent = root.appendingPathComponent("photos")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        for name in ["A.jpg", "A.arw", "A.xmp", "A.arw.xmp", "B.mp4", "B.xmp", "C.jpg"] {
            try Data("original media bytes".utf8).write(to: parent.appendingPathComponent(name))
        }
        let suite = "MediaDeletion-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"), thumbnails: ThumbnailCache(directory: root.appendingPathComponent("thumbs")),
                                 defaults: defaults, monitoringEnabled: false)
        defer { store.cancelPreviewGeneration() }
        store.load(parent); try await until { !store.isLoading }
        guard let a = store.assets.first(where: { $0.id == "a" }), let b = store.assets.first(where: \.isVideo),
              let c = store.assets.first(where: { $0.id == "c" }) else { throw BrowserFailure.message("Media deletion fixtures were not scanned") }
        store.selection = [a.id, b.id]; store.focusedID = a.id
        try expect(store.permanentDeletionAssets(for: b).map(\.id) == [a.id, b.id]
                   && store.permanentDeletionAssets(for: c).map(\.id) == [c.id], "right-click deletion uses the selected batch or only the clicked unselected item")
        store.deleteMedia([a, b], from: parent)
        try expect(a.files.allSatisfy { fm.fileExists(atPath: $0.url.path) } && b.files.allSatisfy { fm.fileExists(atPath: $0.url.path) }
                   && store.selection == [a.id, b.id] && !store.isMoving, "cancelled permanent deletion preserves files and selection")
        // A stale companion must abort preflight before the first RAW/JPEG can be removed.
        let companion = a.files.first { $0.kind == .sidecar }!
        try Data("changed companion with different bytes".utf8).write(to: companion.url)
        store.deleteMedia([a, b], from: parent, confirmed: true); try await until { !store.isMoving }
        try expect(store.errorMessage != nil && a.files.allSatisfy { fm.fileExists(atPath: $0.url.path) }
                   && b.files.allSatisfy { fm.fileExists(atPath: $0.url.path) }, "changed companion prevents deletion of the entire photo/video batch")
        store.assets = try DirectoryScanner.scan(parent); store.errorMessage = nil
        let freshA = store.assets.first { $0.id == a.id }!, freshB = store.assets.first { $0.id == b.id }!
        store.groups = [PhotoGroup(id: "batch", name: "batch", assetIDs: [a.id, b.id, c.id])]
        let historyCount = store.history.count
        store.deleteMedia([freshA, freshB], from: parent, confirmed: true); try await until { !store.isMoving }
        try expect(store.errorMessage == nil && (freshA.files + freshB.files).allSatisfy { !fm.fileExists(atPath: $0.url.path) }
                   && store.assets.map(\.id) == [c.id] && store.focusedID == c.id && store.selection == [c.id],
                   "confirmed photo/video deletion removes all paired formats and sidecars and focuses the next item")
        try expect(store.groups.first?.assetIDs == [c.id] && store.history.count == historyCount
                   && !fm.fileExists(atPath: parent.appendingPathComponent("_del").path), "permanent deletion prunes group membership without creating _del or undo records")
        try expect(c.files.allSatisfy { fm.fileExists(atPath: $0.url.path) }, "unselected media stays untouched")
        let pending = parent.appendingPathComponent("_del")
        try fm.createDirectory(at: pending, withIntermediateDirectories: false)
        try Data("pending video".utf8).write(to: pending.appendingPathComponent("pending.mp4"))
        store.load(pending); try await until { !store.isLoading }
        let video = store.assets[0]
        store.deleteMedia([video], from: pending, confirmed: true); try await until { !store.isMoving }
        try expect(store.assets.isEmpty && !fm.fileExists(atPath: video.preferred.url.path) && store.focusedID == nil,
                   "permanent right-click deletion also cleans files already inside _del")
        let outside = root.appendingPathComponent("outside.jpg")
        try Data("outside original".utf8).write(to: outside)
        let values = try outside.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let file = PhotoFile(url: outside, kind: .rendered, size: Int64(values.fileSize!), modified: values.contentModificationDate!)
        do { try FileDeletionService.removeMedia([file], from: parent); throw BrowserFailure.message("Outside media deleted") }
        catch is BrowserFailure {}
        try expect(fm.fileExists(atPath: outside.path), "media deletion refuses files outside the active directory")
    }

    @MainActor static func folderDeletionChecks() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("FolderDeletion-" + UUID().uuidString)
        let parent = root.appendingPathComponent("parent"), empty = parent.appendingPathComponent("empty")
        let content = parent.appendingPathComponent("content"), sibling = parent.appendingPathComponent("sibling")
        let outside = root.appendingPathComponent("outside"), alias = parent.appendingPathComponent("alias")
        for folder in [empty, content.appendingPathComponent("nested"), sibling, outside] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let bytes = Data("keep original bytes".utf8)
        try bytes.write(to: outside.appendingPathComponent("keep.txt"))
        try bytes.write(to: sibling.appendingPathComponent("keep.txt"))
        for file in ["nested/photo.jpg", "nested/video.mov", "photo.xmp", ".hidden"] {
            try bytes.write(to: content.appendingPathComponent(file))
        }
        try fm.createSymbolicLink(at: alias, withDestinationURL: outside)
        try fm.createSymbolicLink(at: content.appendingPathComponent("external"), withDestinationURL: outside)
        let suite = "FolderDeletion-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let summaries = FolderSummaryCache(directory: root.appendingPathComponent("summaries"))
        let sizes = FolderSizeCache(directory: root.appendingPathComponent("sizes"))
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"), thumbnails: ThumbnailCache(directory: root.appendingPathComponent("thumbnails")),
                                 defaults: defaults, folderSummaries: summaries, folderSizes: sizes, monitoringEnabled: false)
        defer { store.cancelPreviewGeneration() }
        store.load(parent); try await until { !store.isLoading && !store.isGeneratingPreviews }
        try expect(store.canDeleteFolder(empty), "empty child folder offers deletion")
        store.deleteFolder(empty)
        try expect(fm.fileExists(atPath: empty.path) && !store.isMoving, "unconfirmed or cancelled deletion leaves the folder untouched")
        store.selectedFolderID = empty.path
        store.deleteFolder(empty, confirmed: true); try await until { !store.isMoving }
        try expect(!fm.fileExists(atPath: empty.path) && !store.subdirectories.contains(empty) && store.selectedFolderID == nil,
                   "confirmed empty-folder deletion removes its card and selection")
        _ = try await summaries.summary(of: content); _ = try await sizes.size(of: content)
        _ = try await summaries.summary(of: parent); _ = try await sizes.size(of: parent)
        let history = store.history.count
        store.deleteFolder(content, confirmed: true); try await until { !store.isMoving }
        let contentSummary = try await summaries.cached(of: content), parentSize = try await sizes.cached(of: parent)
        try expect(!fm.fileExists(atPath: content.path) && !store.subdirectories.contains(content)
                   && !fm.fileExists(atPath: parent.appendingPathComponent("_del").path) && store.history.count == history,
                   "folder deletion removes nested media, sidecars and hidden files permanently without _del or an undo record")
        try expect(contentSummary == nil && parentSize == nil, "folder deletion invalidates removed and parent folder caches")
        try expect(try Data(contentsOf: outside.appendingPathComponent("keep.txt")) == bytes
                   && Data(contentsOf: sibling.appendingPathComponent("keep.txt")) == bytes,
                   "deleting a folder preserves siblings and targets of contained symbolic links")
        store.deleteFolder(alias, confirmed: true); try await until { !store.isMoving }
        try expect(store.errorMessage != nil && fm.fileExists(atPath: alias.path) && fm.fileExists(atPath: outside.path),
                   "a symbolic folder is rejected without deleting the external directory")
        for target in [parent, outside, sibling.appendingPathComponent("keep.txt")] {
            do { try FileDeletionService.removeFolder(target, from: parent); throw BrowserFailure.message("Invalid target was deleted") }
            catch is BrowserFailure {}
            try expect(fm.fileExists(atPath: target.path), "invalid deletion target stays intact: " + target.lastPathComponent)
        }
    }

}
