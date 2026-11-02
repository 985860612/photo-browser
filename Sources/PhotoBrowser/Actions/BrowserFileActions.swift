import AppKit
import BrowserCore

extension BrowserStore {
    func deleteSelection() {
        guard canDeleteSelection, let directory else { return }
        do {
            let selected = visibleAssets.filter { selection.contains($0.id) }
            let plan = try ArchivePlan.pendingDeletion(directory: directory, assets: selected, groups: groups)
            archive(plan)
        } catch { report(error) }
    }

    func canDeleteFolder(_ folder: URL) -> Bool {
        canArchive && !isLoading && !editingPath && directory != nil
            && folder.standardizedFileURL.deletingLastPathComponent() == directory?.standardizedFileURL
            && subdirectories.contains { $0.standardizedFileURL == folder.standardizedFileURL }
    }

    func permanentDeletionAssets(for asset: PhotoAsset) -> [PhotoAsset] {
        let list = visibleAssets
        return selection.contains(asset.id) ? list.filter { selection.contains($0.id) } : list.filter { $0.id == asset.id }
    }

    func confirmMediaDeletion(_ asset: PhotoAsset) {
        guard canArchive, !isLoading, !editingPath, let parent = directory else { return }
        let chosen = permanentDeletionAssets(for: asset)
        guard !chosen.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("永久删除 \(chosen.count) 个项目？")
        alert.informativeText = L10n.text("将永久删除 \(chosen.flatMap(\.files).count) 个文件，包括对应照片、视频及配套文件，无法撤销。\n目录：\(parent.path)")
            + "\n\n" + chosen.prefix(4).map(\.name).joined(separator: "\n")
        alert.addButton(withTitle: L10n.text("取消"))
        alert.addButton(withTitle: L10n.text("删除")).hasDestructiveAction = true
        let commit: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertSecondButtonReturn { self?.deleteMedia(chosen, from: parent, confirmed: true) }
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: commit) }
        else { commit(alert.runModal()) }
    }

    func deleteMedia(_ chosen: [PhotoAsset], from parent: URL, confirmed: Bool = false) {
        guard confirmed else { return }
        guard canArchive, !isLoading, !editingPath, directory?.standardizedFileURL.path == parent.standardizedFileURL.path, !chosen.isEmpty,
              Set(chosen.map(\.id)).count == chosen.count,
              chosen.allSatisfy({ item in assets.first { $0.id == item.id }?.files == item.files }) else {
            report(BrowserFailure.message(L10n.text("删除项目已变化，请刷新后重试。"))); return
        }
        let files = chosen.flatMap(\.files), removed = Set(chosen.map(\.id)), list = visibleAssets
        let index = list.firstIndex { $0.id == focusedID } ?? 0
        let nextID = list.dropFirst(index + 1).first { !removed.contains($0.id) }?.id
            ?? list.prefix(index).last { !removed.contains($0.id) }?.id
        cancelPreviewGeneration(stopVideo: focusedID.map { removed.contains($0) } ?? false)
        stopDirectoryObservation(); isMoving = true; errorMessage = nil
        status = L10n.text("正在永久删除文件，请勿退出…")
        Task {
            var failure: Error?
            do { try await Task.detached(priority: .userInitiated) { try FileDeletionService.removeMedia(files, from: parent) }.value }
            catch { failure = error }
            // A filesystem error can occur after some files were removed. Reflect the actual remaining files.
            do {
                let fresh = try await Task.detached(priority: .userInitiated) { try DirectoryScanner.scan(parent) }.value
                let previous = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
                assets = fresh.map { item in
                    var value = item
                    if let old = previous[item.id], old.files == item.files { value.metadata = old.metadata }
                    return value
                }
                let remaining = Set(assets.map(\.id))
                removeMembership(Array(Set(previous.keys).subtracting(remaining)))
                selection.formIntersection(remaining)
                if let focusedID, !remaining.contains(focusedID) {
                    self.focusedID = visibleAssets.first { $0.id == nextID }?.id ?? visibleAssets.first?.id
                    preferredFileID = nil
                    if let next = self.focusedID { selection.insert(next) }
                }
                if scope != "all", scope != "ungrouped", currentGroup == nil { scope = "ungrouped" }
                navigationScrollTarget = focusedID; selectionAnchorID = focusedID; rangeSelectionBase = nil
                if focusedID == nil, isFullscreenPreview { closeFullscreenPreview() }
            } catch { if failure == nil { failure = error } }
            await displayCache.invalidate(files)
            do { try await thumbnails.invalidate(files) } catch { if failure == nil { failure = error } }
            await invalidateFolderCaches([parent])
            isMoving = false
            if let failure { report(failure); status = L10n.text("永久删除未全部完成，请检查剩余文件。") }
            else { persistChanges(L10n.text("已永久删除 \(chosen.count) 个项目、\(files.count) 个文件")) }
            if monitoringEnabled { startDirectoryObservation() }
            startPreviewGeneration()
        }
    }

    /// The confirmation dialog is the only UI caller allowed to commit a permanent deletion.
    func deleteFolder(_ folder: URL, confirmed: Bool = false) {
        guard confirmed else { return }
        guard canDeleteFolder(folder), let parent = directory else {
            report(BrowserFailure.message(L10n.text("当前无法删除该文件夹，请刷新后重试。"))); return
        }
        cancelPreviewGeneration(stopVideo: false)
        stopDirectoryObservation()
        isMoving = true; errorMessage = nil
        status = L10n.text("正在删除文件夹：\(folder.lastPathComponent)")
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try FileDeletionService.removeFolder(folder, from: parent) }.value
                subdirectories.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
                if selectedFolderID == folder.path { selectedFolderID = nil; navigationScrollTarget = focusedID }
                await invalidateFolderCaches([folder], descendants: true)
                await invalidateFolderCaches([parent])
                status = L10n.text("已删除文件夹：\(folder.lastPathComponent)")
            } catch {
                status = L10n.text("文件夹删除失败，请查看提示。")
                report(error)
            }
            isMoving = false
            if monitoringEnabled { startDirectoryObservation() }
            startPreviewGeneration()
        }
    }

    func archive(_ plan: ArchivePlan) {
        guard canArchive else { report(BrowserFailure.message(L10n.text("请先完成当前任务或恢复未完成的移动记录。"))); return }
        let deleting = plan.record.isPendingDeletion
        let moved = Set(plan.record.group.assetIDs), list = visibleAssets
        let includesVideo = list.contains { moved.contains($0.id) && $0.isVideo }
        let index = list.firstIndex { $0.id == focusedID } ?? 0
        let nextID = list.first { $0.id == focusedID && !moved.contains($0.id) }?.id
            ?? list.dropFirst(index + 1).first { !moved.contains($0.id) }?.id
            ?? list.prefix(index).last { !moved.contains($0.id) }?.id
        cancelPreviewGeneration()
        isMoving = true; archiveGroup = nil
        status = deleting ? L10n.text("正在移到 _del，请勿退出…") : L10n.text("正在移动整组文件，请勿退出…")
        let worker = engine
        Task {
            do {
                let record = try await Task.detached(priority: .userInitiated) { try worker.archive(plan) }.value
                await invalidateFolderCaches([record.sourceDirectory, record.destination] + [directory].compactMap { $0 })
                if record.destination.deletingLastPathComponent().resolvingSymlinksInPath() == directory?.resolvingSymlinksInPath(),
                   !subdirectories.contains(where: { $0.resolvingSymlinksInPath() == record.destination }) {
                    subdirectories.append(record.destination)
                    subdirectories.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                }
                assets.removeAll { moved.contains($0.id) }; removeMembership(Array(moved))
                selectedFolderID = nil
                selection = []; preferredFileID = nil
                if deleting {
                    if scope != "all", scope != "ungrouped", currentGroup == nil { scope = "ungrouped" }
                    let remaining = visibleAssets
                    focusedID = remaining.first { $0.id == nextID }?.id ?? remaining.first?.id
                    navigationScrollTarget = focusedID
                    if focusedID == nil, isFullscreenPreview { closeFullscreenPreview() }
                } else {
                    scope = "all"; focusedID = assets.first?.id; showGroupOverview = false
                }
                if let focusedID { selection = [focusedID] }
                selectionAnchorID = focusedID; rangeSelectionBase = nil
                isMoving = false
                let message = includesVideo
                    ? (deleting ? L10n.text("已将 \(record.group.assetIDs.count) 个项目、\(record.entries.count) 个文件移到 _del，可在移动记录中撤销")
                       : L10n.text("已移动 \(record.group.assetIDs.count) 个项目、\(record.entries.count) 个文件，可在移动记录中撤销"))
                    : (deleting
                    ? L10n.text("已将 \(record.group.assetIDs.count) 张照片、\(record.entries.count) 个文件移到 _del，可在移动记录中撤销")
                    : L10n.text("已移动 \(record.group.assetIDs.count) 张照片、\(record.entries.count) 个文件，可在移动记录中撤销"))
                persistChanges(message)
                refreshHistory()
                startPreviewGeneration()
            } catch { isMoving = false; startPreviewGeneration(); status = L10n.text("移动失败，请查看提示和移动记录"); report(error); refreshHistory() }
        }
    }

    func undo(_ record: ArchiveRecord) {
        guard !isMoving else { return }
        cancelPreviewGeneration()
        isMoving = true; status = L10n.text("正在撤销移动…"); let worker = engine
        Task {
            do {
                let restored = try await Task.detached(priority: .userInitiated) { try worker.undo(record) }.value
                await invalidateFolderCaches([restored.sourceDirectory, restored.destination] + [directory].compactMap { $0 })
                isMoving = false; showHistory = false
                load(restored.sourceDirectory, restoring: restored.group, restoringDeletedGroups: restored.deletionGroups)
            } catch { isMoving = false; startPreviewGeneration(); report(error); refreshHistory() }
        }
    }

    func refreshHistory() {
        do { history = try engine.records() } catch { report(error) }
    }

}

/// A confirmed snapshot: only rendered companions of an existing RAW are eligible.
enum RawRetentionAction: Sendable {
    case moveToDel
    case permanentDelete
}

struct RawRetentionPlan: Sendable {
    let root: URL
    let sourceRoot: URL
    let moves: [ArchivePlan]
    let rawFiles: [PhotoFile]
    var fileCount: Int { moves.reduce(0) { $0 + $1.fileCount } }
    var totalBytes: Int64 { moves.reduce(0) { $0 + $1.totalBytes } }

    static func prepare(in folder: URL, sessions: BrowserSessionRepository) throws -> Self {
        let root = folder.standardizedFileURL
        try validateDirectory(root, under: root)
        let sourceRoot = root.resolvingSymlinksInPath()
        var moves: [ArchivePlan] = [], rawFiles: [PhotoFile] = []
        var pending = [sourceRoot]
        while let directory = pending.popLast() {
            try validateDirectory(directory, under: sourceRoot)
            let assets = try DirectoryScanner.scan(directory)
            var companions: [PhotoAsset] = []
            for asset in assets {
                let regular = try asset.files.filter {
                    try FileManager.default.attributesOfItem(atPath: $0.url.path)[.type] as? FileAttributeType == .typeRegular
                }
                let raws = regular.filter { $0.kind == .raw }
                let rendered = regular.filter { $0.kind == .rendered }
                guard !raws.isEmpty, !rendered.isEmpty else { continue }
                // Scanner families are case insensitive, but links must never qualify as RAW originals.
                for file in raws + rendered { try validate(file) }
                rawFiles.append(contentsOf: raws)
                companions.append(PhotoAsset(id: asset.id, name: asset.name, files: rendered))
            }
            if !companions.isEmpty {
                let groups = try sessions.restore(assets, in: directory).groups
                moves.append(try ArchivePlan.pendingDeletion(directory: directory, assets: companions, groups: groups))
            }
            for child in try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true, child.lastPathComponent.lowercased() != "_del" {
                    pending.append(child)
                }
            }
        }
        return Self(root: root, sourceRoot: sourceRoot, moves: moves, rawFiles: rawFiles)
    }

    func execute(using engine: ArchiveEngine, action: RawRetentionAction = .moveToDel) throws {
        // Check the entire confirmed batch before changing its first file.
        try Self.validateDirectory(root, under: root)
        guard root.resolvingSymlinksInPath() == sourceRoot else {
            throw BrowserFailure.message(L10n.text("只能处理所选文件夹内的普通目录。"))
        }
        for move in moves {
            try Self.validateDirectory(move.record.sourceDirectory, under: sourceRoot)
            if action == .moveToDel {
                let destination = move.record.destination
                let destinationAttributes: [FileAttributeKey: Any]?
                do { destinationAttributes = try FileManager.default.attributesOfItem(atPath: destination.path) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                    destinationAttributes = nil
                }
                if let destinationAttributes {
                    guard destinationAttributes[.type] as? FileAttributeType == .typeDirectory else {
                        throw BrowserFailure.message(L10n.text("_del 必须是当前目录下的普通文件夹，不能是文件或符号链接。"))
                    }
                    let names = Set(try FileManager.default.contentsOfDirectory(atPath: destination.path).map { $0.lowercased() })
                    guard move.record.entries.allSatisfy({ !names.contains($0.destination.lastPathComponent.lowercased()) }) else {
                        throw BrowserFailure.message(L10n.text("目标文件已存在：\(destination.path)"))
                    }
                }
            }
            for entry in move.record.entries {
                try Self.validate(PhotoFile(url: entry.source, kind: .rendered, size: entry.size, modified: entry.modified))
            }
        }
        for file in rawFiles { try Self.validate(file) }
        let originalsByDirectory = Dictionary(grouping: rawFiles) { $0.url.deletingLastPathComponent().standardizedFileURL }
        for move in moves {
            try Self.validateDirectory(move.record.sourceDirectory, under: sourceRoot)
            for file in originalsByDirectory[move.record.sourceDirectory] ?? [] {
                try Self.validate(file)
            }
            switch action {
            case .moveToDel:
                _ = try engine.archive(move)
            case .permanentDelete:
                let files = move.record.entries.map { PhotoFile(url: $0.source, kind: .rendered, size: $0.size, modified: $0.modified) }
                try FileDeletionService.removeMedia(files, from: move.record.sourceDirectory)
            }
        }
    }

    private static func validate(_ file: PhotoFile) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == file.size,
              let date = attributes[.modificationDate] as? Date, abs(date.timeIntervalSince(file.modified)) < 1 else {
            throw BrowserFailure.message(L10n.text("文件已变化或不是普通文件，请重新扫描：\(file.url.lastPathComponent)"))
        }
    }

    private static func validateDirectory(_ directory: URL, under root: URL) throws {
        var current = directory.standardizedFileURL
        guard current == root || current.path.hasPrefix(root.path + "/") else {
            throw BrowserFailure.message(L10n.text("只能处理所选文件夹内的普通目录。"))
        }
        while true {
            let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  current.lastPathComponent.lowercased() != "_del",
                  !current.lastPathComponent.hasPrefix(".") else {
                throw BrowserFailure.message(L10n.text("只能处理所选文件夹内的普通目录。"))
            }
            if current == root { break }
            current.deleteLastPathComponent()
        }
    }
}

extension RawRetentionPlan {
    @MainActor func confirmationPanel() -> RawRetentionConfirmation {
        let title = L10n.text("仅保留“\(root.lastPathComponent)”中的 RAW？")
        let message = L10n.text("将递归清理此文件夹中有同名 RAW 的 JPG、HIF 等照片。\n移到 _del：可在移动记录中撤销。\n直接删除：永久删除，不经过废纸篓，无法撤销。\n保留 RAW、XMP、视频和没有 RAW 的照片，跳过 _del、隐藏目录及符号链接。\n文件：\(fileCount) 个 · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))\n路径：\(root.path)")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 240))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        let width = scroll.contentSize.width
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 240))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 240)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        text.setAccessibilityLabel(L10n.text("待清理文件列表"))
        text.string = moves.flatMap { $0.record.entries }.map { $0.source.path }.joined(separator: "\n")
        scroll.documentView = text
        if let container = text.textContainer, let layout = text.layoutManager {
            layout.ensureLayout(for: container)
            text.setFrameSize(NSSize(width: width, height: max(240, ceil(layout.usedRect(for: container).height) + 16)))
        }
        return RawRetentionConfirmation(title: title, message: message, fileList: scroll)
    }
}

@MainActor final class RawRetentionConfirmation: NSObject, NSWindowDelegate {
    let window: NSPanel
    let fileList: NSScrollView
    let buttons: [NSButton]

    init(title: String, message: String, fileList: NSScrollView) {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.fileList = fileList
        let cancel = NSButton(title: L10n.text("取消"), target: nil, action: nil)
        let move = NSButton(title: L10n.text("移到 _del"), target: nil, action: nil)
        let delete = NSButton(title: L10n.text("直接删除（不可撤销）"), target: nil, action: nil)
        buttons = [cancel, move, delete]
        super.init()
        window.title = L10n.text("仅保留 RAW…")
        window.isReleasedWhenClosed = false
        window.delegate = self
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .boldSystemFont(ofSize: 15)
        let explanation = NSTextField(wrappingLabelWithString: message)
        explanation.font = .systemFont(ofSize: 13)
        explanation.isSelectable = true
        let row = NSStackView(views: [NSView(), cancel, move, delete])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        for (index, symbol) in ["xmark", "folder", "trash"].enumerated() {
            let button = buttons[index]
            button.bezelStyle = .rounded
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.tag = index
            button.target = self
            button.action = #selector(choose(_:))
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        move.contentTintColor = .systemBlue
        delete.contentTintColor = .systemRed
        let content = NSStackView(views: [heading, explanation, fileList, row])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [heading, explanation, fileList, row] {
            view.widthAnchor.constraint(equalToConstant: 580).isActive = true
        }
        fileList.heightAnchor.constraint(equalToConstant: 240).isActive = true
        window.contentView = content
        window.setContentSize(content.fittingSize)
        content.layoutSubtreeIfNeeded()
    }

    func present(attachedTo parent: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let parent, parent.attachedSheet == nil {
            parent.beginSheet(window) { [self] response in
                window.orderOut(nil)
                completion(response)
            }
        } else {
            window.center()
            let response = NSApp.runModal(for: window)
            window.orderOut(nil)
            completion(response)
        }
    }

    @objc private func choose(_ sender: NSButton) {
        finish(NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag))
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        if let parent = window.sheetParent { parent.endSheet(window, returnCode: response) }
        else { NSApp.stopModal(withCode: response) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.alertFirstButtonReturn)
        return false
    }
}

extension BrowserStore {
    func canKeepRaw(in folder: URL) -> Bool {
        canDeleteFolder(folder) && !folder.pathComponents.contains { $0.lowercased() == "_del" }
    }

    func confirmKeepRaw(in folder: URL) {
        guard canKeepRaw(in: folder) else { return }
        isMoving = true; errorMessage = nil
        status = L10n.text("正在检查 RAW 配套文件…")
        let repository = sessions
        Task {
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try RawRetentionPlan.prepare(in: folder, sessions: repository)
                }.value
                isMoving = false
                guard plan.fileCount > 0 else { status = L10n.text("没有可清理的 RAW 配套照片。"); return }
                let confirmation = plan.confirmationPanel()
                let commit: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                    if response == .alertSecondButtonReturn { self?.keepRaw(plan, confirmed: true) }
                    else if response == .alertThirdButtonReturn { self?.keepRaw(plan, action: .permanentDelete, confirmed: true) }
                    else { self?.status = L10n.text("已取消。") }
                }
                confirmation.present(attachedTo: NSApp.keyWindow, completion: commit)
            } catch { isMoving = false; status = L10n.text("RAW 配套文件检查失败。"); report(error) }
        }
    }

    func keepRaw(_ plan: RawRetentionPlan, action: RawRetentionAction = .moveToDel, confirmed: Bool = false) {
        guard confirmed else { return }
        guard canKeepRaw(in: plan.root) else {
            report(BrowserFailure.message(L10n.text("当前无法处理该文件夹，请刷新后重试。"))); return
        }
        cancelPreviewGeneration(stopVideo: false); stopDirectoryObservation()
        isMoving = true; errorMessage = nil
        status = action == .moveToDel ? L10n.text("正在移到 _del，请勿退出…") : L10n.text("正在永久删除文件，请勿退出…")
        let worker = engine
        Task {
            var failure: Error?
            do { try await Task.detached(priority: .userInitiated) { try plan.execute(using: worker, action: action) }.value }
            catch { failure = error }
            await invalidateFolderCaches([plan.root], descendants: true)
            refreshHistory(); isMoving = false
            if let failure {
                status = action == .moveToDel ? L10n.text("RAW 清理未全部完成，请检查文件和移动记录。")
                    : L10n.text("RAW 清理未全部完成，请检查剩余文件。")
                report(failure)
            } else {
                status = action == .moveToDel ? L10n.text("已将 \(plan.fileCount) 个 RAW 配套照片移到 _del，可在移动记录中撤销")
                    : L10n.text("已永久删除 \(plan.fileCount) 个 RAW 配套照片")
            }
            if monitoringEnabled { startDirectoryObservation() }
            startPreviewGeneration()
        }
    }
}
