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
