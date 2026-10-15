import AppKit
import BrowserCore

extension BrowserStore {
    func start() {
        guard !started else { return }; started = true
        Task { await applyDiskLimit() }
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--directory"), index + 1 < arguments.count {
            load(URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        } else if let path = preferencesDefaults.string(forKey: "lastDirectory") {
            load(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    func chooseDirectory() {
        guard !isMoving else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("打开照片目录"); panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func refreshDirectory() {
        guard let directory, !isMoving, !isLoading else { return }
        isLoading = true; status = L10n.text("扫描照片并合并同名格式…")
        Task {
            await invalidateFolderCaches([directory], descendants: true)
            guard self.directory == directory, !isMoving else { return }
            load(directory)
        }
    }

    func invalidateFolderCaches(_ urls: [URL], descendants: Bool = false) async {
        // Cache errors must not undo or misreport a completed filesystem move.
        do { try await folderSummaries.invalidate(urls, descendants: descendants) }
        catch { report(BrowserFailure.message(L10n.text("缓存更新失败：\(error.localizedDescription)"))) }
        do { try await folderSizes.invalidate(urls, descendants: descendants) }
        catch { report(BrowserFailure.message(L10n.text("缓存更新失败：\(error.localizedDescription)"))) }
        folderCacheRevision = UUID()
    }

    func load(_ inputURL: URL, restoring restoredGroup: PhotoGroup? = nil,
              restoringDeletedGroups: [PhotoGroup]? = nil, recordNavigation: Bool = true) {
        guard !isMoving else { return }
        stopDirectoryObservation()
        culling.close()
        cancelPreviewGeneration()
        captureDates.cancel(reset: true)
        let url = inputURL.standardizedFileURL
        if isFullscreenPreview { closeFullscreenPreview() }
        metadataJob?.cancel(); metadataJob = nil; isReadingMetadata = false; metadataID = UUID()
        let ticket = UUID(); loadID = ticket
        directory = url; isLoading = true; status = L10n.text("扫描照片并合并同名格式…")
        selectedFolderID = nil
        navigationScrollTarget = nil
        assets = []; groups = []; subdirectories = []; selection = []; focusedID = nil; preferredFileID = nil; scope = "all"; search = ""; showGroupOverview = false
        selectionAnchorID = nil; rangeSelectionBase = nil
        pathText = url.path; editingPath = false
        let sessions = sessions
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> ([PhotoAsset], [PhotoGroup], String, [URL]) in
                    let photos = try DirectoryScanner.scan(url)
                    let folders = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                        .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    let restored = try sessions.restore(photos, in: url)
                    return (restored.assets, restored.groups, restored.note, folders)
                }.value
                guard loadID == ticket else { return }
                assets = result.0; groups = result.1; subdirectories = result.3
                if recordNavigation, navigationHistory.indices.contains(navigationIndex) == false || navigationHistory[navigationIndex] != url {
                    navigationHistory = Array(navigationHistory.prefix(navigationIndex + 1)) + [url]
                    navigationIndex = navigationHistory.count - 1
                }
                if let restoringDeletedGroups {
                    restoreDeletedMembership(restoringDeletedGroups, assetIDs: Set(restoredGroup?.assetIDs ?? []))
                } else if let restoredGroup, !groups.contains(where: { $0.id == restoredGroup.id }) {
                    let existing = Set(assets.map(\.id))
                    var restored = restoredGroup; restored.assetIDs = restored.assetIDs.filter { existing.contains($0) }
                    if !restored.assetIDs.isEmpty { groups.append(restored) }
                }
                focusedID = visibleAssets.first?.id
                if let focusedID { selection = [focusedID] }
                isLoading = false
                status = result.2
                preferencesDefaults.set(url.path, forKey: "lastDirectory")
                try saveSession()
                await culling.open(url, assets: assets, protectedIDs: Set(groups.flatMap(\.assetIDs)))
                guard loadID == ticket else { return }
                refreshHistory()
                startPreviewGeneration()
                ensureCaptureSortDates()
                if monitoringEnabled { startDirectoryObservation() }
            } catch {
                guard loadID == ticket else { return }
                isLoading = false; status = L10n.text("目录加载失败"); report(error)
            }
        }
    }

}
