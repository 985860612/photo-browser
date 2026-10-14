import AppKit
import ImageIO
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func deletionChecks(root: URL, jpeg: Data) async throws {
        let fm = FileManager.default, directory = root.appendingPathComponent("delete-photos")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        for name in ["A.jpg", "B.jpg", "C.jpg", "D.jpg"] { try jpeg.write(to: directory.appendingPathComponent(name)) }
        for name in ["A.arw", "A.hif", "A.xmp", "A.arw.xmp"] {
            try Data("original \(name)".utf8).write(to: directory.appendingPathComponent(name))
        }
        let cache = ThumbnailCache(directory: root.appendingPathComponent("deletion-cache"))
        let folderSummaries = FolderSummaryCache(directory: root.appendingPathComponent("deletion-summaries"))
        let folderSizes = FolderSizeCache(directory: root.appendingPathComponent("deletion-sizes"))
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("deletion-support"), thumbnails: cache,
                                 folderSummaries: folderSummaries, folderSizes: folderSizes)
        defer { store.cancelPreviewGeneration() }
        store.load(directory)
        try await until { !store.isLoading }
        let original = store.assets
        _ = try await folderSummaries.summary(of: directory); _ = try await folderSizes.size(of: directory)
        let firstGroup = PhotoGroup(id: "first-group", name: "First", assetIDs: ["a", "c", "d"])
        let secondGroup = PhotoGroup(id: "second-group", name: "Second", assetIDs: ["b"])
        store.groups = [firstGroup, secondGroup]
        try expect(store.directorySummary == L10n.text("\(4) 张照片 · \(6) 个图像文件 · \(2) 个分组"),
                   "directory summary counts paired captures and groups independently of operation messages")
        store.scope = secondGroup.id; store.changeScope()
        try expect(store.visibleAssets.count == 1 && store.directorySummary == L10n.text("\(4) 张照片 · \(6) 个图像文件 · \(2) 个分组"),
                   "viewing one group does not reduce the whole-directory totals")
        store.scope = "all"; store.changeScope()
        store.select(original[0], modifiers: []); store.select(original[1], modifiers: [.command])
        store.showGroupOverview = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func key(_ code: UInt16 = 51, repeating: Bool = false, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil,
                             characters: code == 117 ? "\u{f728}" : "\u{7f}",
                             charactersIgnoringModifiers: code == 117 ? "\u{f728}" : "\u{7f}",
                             isARepeat: repeating, keyCode: code)!
        }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        editor.isFieldEditor = true; editor.string = "path123"
        window.contentView = editor
        try expect(window.makeFirstResponder(editor), "text editor accepts focus for keyboard checks")
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        let backspace = key()
        try expect(store.handleKeyDown(backspace, in: window) === backspace && !store.isMoving,
                   "Backspace in an input field is not consumed by photo deletion")
        editor.keyDown(with: backspace)
        try expect(editor.string == "path12" && store.assets.count == 4,
                   "native Backspace deletes text and leaves every photo untouched")
        window.contentView = NSView(); window.makeFirstResponder(nil)
        let commandDelete = key(modifiers: [.command])
        try expect(store.handleKeyDown(commandDelete, in: window) === commandDelete && !store.isMoving,
                   "modified Delete does not trigger the plain deletion shortcut")
        try expect(store.handleKeyDown(backspace, in: nil) === backspace && !store.isMoving,
                   "keyboard events without a browser window cannot delete photos")
        store.isLoading = true
        try expect(store.handleKeyDown(backspace, in: window) === backspace && !store.isMoving,
                   "Delete does not operate while a folder is loading")
        store.isLoading = false
        store.selectFolder(root)
        _ = store.handleKeyDown(backspace, in: window)
        try expect(!store.canDeleteSelection && !store.isMoving && store.assets.count == 4,
                   "selecting a folder never deletes its contents or the previously focused photo")
        store.select(original[0], modifiers: []); store.select(original[1], modifiers: [.command])
        try expect(store.handleKeyDown(backspace, in: window) == nil && store.isMoving,
                   "Apple Backspace starts the selected photo move immediately")
        try await until { !store.isMoving }
        try expect(store.errorMessage == nil && store.assets.map(\.id) == ["c", "d"],
                   "Backspace moves both selected captures and removes them from the browser")
        let deletedSummary = try await folderSummaries.cached(of: directory), deletedSize = try await folderSizes.cached(of: directory)
        try expect(deletedSummary == nil && deletedSize == nil, "deletion invalidates cached source cover, count and size")
        let target = directory.appendingPathComponent("_del")
        let expectedFiles = original.filter { ["a", "b"].contains($0.id) }.flatMap(\.files)
        try expect(expectedFiles.count == 6 && expectedFiles.allSatisfy {
            !fm.fileExists(atPath: $0.url.path) && fm.fileExists(atPath: target.appendingPathComponent($0.url.lastPathComponent).path)
        }, "deletion includes RAW, HIF, JPEG, both XMP sidecar names, and the second capture")
        try expect(store.focusedID == "c" && store.selection == ["c"] && store.showGroupOverview,
                   "after deletion the next photo is selected without changing the browsing layout")
        try expect(store.groups.count == 1 && store.groups[0].assetIDs == ["c", "d"],
                   "deleted membership is removed and empty groups disappear")
        try expect(store.directorySummary == L10n.text("\(2) 张照片 · \(2) 个图像文件 · \(1) 个分组") && !store.status.isEmpty,
                   "directory counts update after deletion while its undo message remains visible")
        let firstRecord = store.history.first!
        _ = store.handleKeyDown(key(repeating: true), in: window)
        try expect(!store.isMoving && store.assets.count == 2,
                   "holding Backspace does not delete the automatically selected next photo")
        store.rename(store.groups[0], to: "Renamed while pending")
        store.scope = firstGroup.id; store.changeScope()
        try expect(store.directorySummary == L10n.text("\(2) 张照片 · \(2) 个图像文件 · \(1) 个分组"),
                   "directory summary remains the whole-directory count when a group is selected")
        try expect(store.handleKeyDown(key(117, modifiers: [.function]), in: window) == nil && store.isMoving,
                   "forward Delete / Fn-Backspace uses the same pending deletion action")
        try await until { !store.isMoving }
        try expect(store.errorMessage == nil && store.assets.map(\.id) == ["d"] && store.scope == firstGroup.id,
                   "consecutive deletion reuses _del and preserves the current group scope")
        let secondRecord = store.history.first!
        _ = try await folderSummaries.summary(of: directory); _ = try await folderSizes.size(of: directory)
        store.undo(firstRecord)
        try await until { !store.isMoving && !store.isLoading }
        try expect(store.errorMessage == nil && store.assets.map(\.id) == ["a", "b", "d"],
                   "undoing an earlier batch restores only that batch")
        let undoSummary = try await folderSummaries.cached(of: directory), undoSize = try await folderSizes.cached(of: directory)
        try expect(undoSummary == nil && undoSize == nil, "undo invalidates cached directory statistics before restoring the browser")
        try expect(store.groups.first { $0.id == firstGroup.id }?.assetIDs == ["a", "d"]
                   && store.groups.first { $0.id == firstGroup.id }?.name == "Renamed while pending"
                   && store.groups.first { $0.id == secondGroup.id }?.assetIDs == ["b"],
                   "undo restores original membership without reviving later deletions or overwriting group renames")
        try expect(fm.fileExists(atPath: target.appendingPathComponent("C.jpg").path),
                   "undo of one batch leaves other pending files in _del")
        store.undo(secondRecord)
        try await until { !store.isMoving && !store.isLoading }
        try expect(store.errorMessage == nil && store.assets.count == 4
                   && store.groups.first { $0.id == firstGroup.id }?.assetIDs == ["a", "c", "d"],
                   "undo of the remaining batch restores group order and all captures")
        try expect(store.directorySummary == L10n.text("\(4) 张照片 · \(6) 个图像文件 · \(2) 个分组"),
                   "undo restores the directory photo, file and group totals")
        try expect(store.groups.allSatisfy { $0.id != firstRecord.group.id && $0.id != secondRecord.group.id },
                   "undo does not create artificial deletion groups")
        _ = try await folderSummaries.summary(of: directory); _ = try await folderSizes.size(of: directory)
        let revision = store.folderCacheRevision
        store.refreshDirectory()
        try await until { store.folderCacheRevision != revision && !store.isLoading }
        let refreshedSummary = try await folderSummaries.cached(of: directory), refreshedSize = try await folderSizes.cached(of: directory)
        try expect(refreshedSummary == nil && refreshedSize == nil, "explicit refresh clears persisted folder caches without requiring the six-hour expiry")

        let marker = target.appendingPathComponent("a.XMP")
        try Data("existing pending sidecar".utf8).write(to: marker)
        store.select(store.assets[0], modifiers: [])
        _ = store.handleKeyDown(backspace, in: window)
        try await until { !store.isMoving }
        try expect(store.errorMessage != nil && store.assets.count == 4
                   && original.flatMap(\.files).allSatisfy { fm.fileExists(atPath: $0.url.path) }
                   && (try String(contentsOf: marker, encoding: .utf8)) == "existing pending sidecar",
                   "an XMP name conflict keeps the entire photo batch in place and preserves the prior file")
        try fm.removeItem(at: marker); store.errorMessage = nil
        store.selectAll(); store.isFullscreenPreview = true
        _ = store.handleKeyDown(backspace, in: window)
        try await until { !store.isMoving }
        try expect(store.assets.isEmpty && !store.isFullscreenPreview && store.focusedID == nil,
                   "deleting the last selected photos exits fullscreen and clears the preview")
        store.undo(store.history.first!)
        try await until { !store.isMoving && !store.isLoading }
        try expect(store.errorMessage == nil && store.assets.count == 4 && store.groups.count == 2,
                   "deleting every photo remains fully reversible")
        store.load(target)
        try await until { !store.isLoading }
        try expect(!store.canDeleteSelection, "photos already in _del cannot be nested into another _del")
    }

}
