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
        try await rawRetentionChecks()
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

    @MainActor static func rawRetentionChecks() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("KeepRAW-" + UUID().uuidString)
        let parent = root.appendingPathComponent("photos"), folder = parent.appendingPathComponent("group")
        let nested = folder.appendingPathComponent("nested"), outside = root.appendingPathComponent("outside")
        for directory in [nested, outside, folder.appendingPathComponent("_del"), folder.appendingPathComponent(".hidden")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let bytes = Data("original photo bytes".utf8)
        let kept = ["A.ARW", "A.xmp", "A.JPG.xmp", "B.jpg", "clip.mov", "note.txt", "nested/N.NEF", "nested/N.xmp",
                    "_del/old.arw", "_del/old.jpg", ".hidden/H.arw", ".hidden/H.jpg"]
        let moved = ["a.jpg", "A.HIF", "nested/n.jpeg"]
        for name in kept + moved { try bytes.write(to: folder.appendingPathComponent(name)) }
        for name in ["E.arw", "E.jpg"] { try bytes.write(to: outside.appendingPathComponent(name)) }
        try fm.createSymbolicLink(at: folder.appendingPathComponent("external"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("linked.arw"), withDestinationURL: outside.appendingPathComponent("E.arw"))
        try bytes.write(to: folder.appendingPathComponent("linked.jpg"))
        let suite = "KeepRAW-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"),
                                 thumbnails: ThumbnailCache(directory: root.appendingPathComponent("thumbs")), defaults: defaults, monitoringEnabled: false)
        defer { store.cancelPreviewGeneration() }
        store.load(folder); try await until { !store.isLoading }
        store.groups = [PhotoGroup(id: "original-group", name: "original", assetIDs: ["a", "b"])]; try store.saveSession()
        store.load(parent); try await until { !store.isLoading }
        let plan = try RawRetentionPlan.prepare(in: folder, sessions: store.sessions)
        try expect(plan.fileCount == 3 && plan.moves.count == 2 && plan.totalBytes == Int64(bytes.count * 3),
                   "keep RAW previews case-insensitive paired formats recursively, skipping _del, hidden folders and links")
        let previewAssets = (1...61).map { index in
            let file = PhotoFile(url: folder.appendingPathComponent(String(format: "DSC%05d.HIF", index)), kind: .rendered, size: 1, modified: Date())
            return PhotoAsset(id: "preview-\(index)", name: file.url.lastPathComponent, files: [file])
        }
        let previewMove = try ArchivePlan.pendingDeletion(directory: folder, assets: previewAssets, groups: [])
        let preview = RawRetentionPlan(root: folder, sourceRoot: folder.resolvingSymlinksInPath(), moves: [previewMove], rawFiles: [])
        let confirmation = preview.confirmationPanel()
        let scroll = confirmation.fileList
        confirmation.window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        confirmation.window.contentView?.layoutSubtreeIfNeeded()
        guard let text = scroll.documentView as? NSTextView else {
            throw BrowserFailure.message("RAW confirmation has no scrollable file list")
        }
        try expect(text.string.components(separatedBy: "\n").count == 61 && text.string.contains("DSC00061.HIF")
                   && text.isSelectable && !text.isEditable && scroll.hasVerticalScroller,
                   "RAW confirmation lists all 61 files in a selectable read-only scroll view")
        text.scrollRangeToVisible(NSRange(location: (text.string as NSString).length - 1, length: 1))
        try expect(scroll.contentView.bounds.minY > 0 && scroll.frame.height == 240,
                   "RAW confirmation scrolls to the final file while keeping the list height fixed")
        // Native button frames include OS-specific focus/border outsets; stacks space alignment rects.
        let frames = confirmation.buttons.map { button in
            let aligned = button.alignmentRect(forFrame: button.frame)
            return button.superview!.convert(aligned, to: confirmation.window.contentView)
        }
        try expect(confirmation.buttons.allSatisfy { $0.image != nil }
                   && frames.allSatisfy { $0.width > 40 && $0.height > 15 }
                   && frames.allSatisfy { abs($0.midY - frames[0].midY) < 1 }
                   && zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX },
                   "RAW confirmation keeps all three icon buttons in one horizontal row; images=\(confirmation.buttons.map { $0.image != nil }), frames=\(frames)")
        if let path = ProcessInfo.processInfo.environment["PHOTO_RAW_CONFIRMATION_SNAPSHOT"],
           let view = confirmation.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        confirmation.window.orderOut(nil)
        confirmation.window.close()
        for index in 0..<3 {
            let dialog = preview.confirmationPanel()
            let parentWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            parentWindow.isReleasedWhenClosed = false
            var response: NSApplication.ModalResponse?
            dialog.present(attachedTo: parentWindow) { response = $0 }
            dialog.buttons[index].performClick(nil)
            try await until { response != nil }
            try expect(response?.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index,
                       "RAW confirmation button \(index) returns its original cancel/move/delete action")
            parentWindow.close()
        }
        store.keepRaw(plan)
        try expect(!store.isMoving && moved.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) },
                   "cancelled RAW cleanup leaves every file untouched")
        // Changes after confirmation, including losing the RAW, must abort the entire snapshot.
        try fm.removeItem(at: nested.appendingPathComponent("N.NEF"))
        store.keepRaw(plan, confirmed: true); try await until { !store.isMoving }
        try expect(store.errorMessage != nil && moved.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) },
                   "missing RAW aborts the full batch before any rendered companion moves")
        try bytes.write(to: nested.appendingPathComponent("N.NEF"))
        let fresh = try RawRetentionPlan.prepare(in: folder, sessions: store.sessions)
        try bytes.write(to: nested.appendingPathComponent("_del"))
        store.keepRaw(fresh, confirmed: true); try await until { !store.isMoving }
        try expect(store.errorMessage != nil && moved.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) },
                   "invalid nested _del aborts before moving files in other folders")
        try fm.removeItem(at: nested.appendingPathComponent("_del"))
        try bytes.write(to: folder.appendingPathComponent("_del/A.JPG"))
        store.keepRaw(fresh, confirmed: true); try await until { !store.isMoving }
        try expect(store.errorMessage != nil && moved.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) },
                   "case-insensitive _del filename conflicts never overwrite or partially move the batch")
        try fm.removeItem(at: folder.appendingPathComponent("_del/A.JPG"))
        _ = try await store.folderSummaries.summary(of: folder)
        store.keepRaw(fresh, confirmed: true); try await until { !store.isMoving }
        try expect(store.errorMessage == nil && moved.allSatisfy { !fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
                   && kept.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
                   && fm.fileExists(atPath: folder.appendingPathComponent("linked.jpg").path)
                   && fm.fileExists(atPath: outside.appendingPathComponent("E.jpg").path),
                   "RAW cleanup moves only rendered companions and preserves RAW, all XMP, unpaired photos, videos and external targets")
        let cached = try await store.folderSummaries.cached(of: folder)
        try expect(cached == nil && store.history.filter { $0.state == "complete" }.count == 2,
                   "RAW cleanup invalidates folder covers and journals each directory for undo")
        for record in store.history where record.state == "complete" {
            store.undo(record); try await until { !store.isMoving && !store.isLoading }
        }
        try expect(moved.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }, "move history restores every cleaned format")
        store.load(folder); try await until { !store.isLoading }
        try expect(store.groups.first { $0.id == "original-group" }?.assetIDs == ["a", "b"], "RAW cleanup and undo preserve original panorama membership")
        store.load(parent); try await until { !store.isLoading }
        let deletionPlan = try RawRetentionPlan.prepare(in: folder, sessions: store.sessions)
        store.keepRaw(deletionPlan, action: .permanentDelete)
        try expect(!store.isMoving && moved.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) },
                   "direct RAW cleanup also requires explicit confirmation")
        try fm.removeItem(at: nested.appendingPathComponent("N.NEF"))
        store.keepRaw(deletionPlan, action: .permanentDelete, confirmed: true); try await until { !store.isMoving }
        try expect(store.errorMessage != nil && moved.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) },
                   "direct deletion checks every RAW before permanently deleting any companion")
        try bytes.write(to: nested.appendingPathComponent("N.NEF"))
        let finalPlan = try RawRetentionPlan.prepare(in: folder, sessions: store.sessions)
        try bytes.write(to: folder.appendingPathComponent("_del/A.JPG"))
        let historyCount = store.history.count
        store.keepRaw(finalPlan, action: .permanentDelete, confirmed: true); try await until { !store.isMoving }
        try expect(store.errorMessage == nil && moved.allSatisfy { !fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
                   && kept.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
                   && fm.fileExists(atPath: folder.appendingPathComponent("_del/A.JPG").path)
                   && fm.fileExists(atPath: folder.appendingPathComponent("linked.jpg").path)
                   && fm.fileExists(atPath: outside.appendingPathComponent("E.jpg").path),
                   "direct deletion removes only confirmed companions, preserving RAW, sidecars, unpaired photos, videos, links and existing _del")
        try expect(store.history.count == historyCount && !fm.fileExists(atPath: nested.appendingPathComponent("_del").path),
                   "direct deletion creates neither a pending-delete directory nor an undo record")
        store.load(folder); try await until { !store.isLoading }
        try expect(store.groups.first { $0.id == "original-group" }?.assetIDs == ["a", "b"], "direct cleanup retains RAW panorama membership")
    }

}
