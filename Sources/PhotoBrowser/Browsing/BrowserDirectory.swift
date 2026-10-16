import AppKit
import UniformTypeIdentifiers
import BrowserCore

extension BrowserStore {
    func start() {
        guard !started else { return }; started = true
        Task { await applyDiskLimit() }
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--directory"), index + 1 < arguments.count {
            load(URL(fileURLWithPath: arguments[index + 1]))
        } else if let path = preferencesDefaults.string(forKey: "lastDiskImagePath") {
            openDiskImage(URL(fileURLWithPath: path), relativePath: preferencesDefaults.string(forKey: "lastDiskImageRelativePath") ?? "")
        } else if let path = preferencesDefaults.string(forKey: "lastDirectory") {
            load(URL(fileURLWithPath: path))
        }
    }

    func chooseDirectory() {
        guard !isMoving, !isOperatingDiskImage else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.allowsOtherFileTypes = false
        panel.title = L10n.text("打开照片目录或 ISO 镜像")
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
        guard !isMoving, !isEjectingDiskImage else { return }
        if DiskImageService.supports(inputURL) && !inputURL.hasDirectoryPath {
            openDiskImage(inputURL)
            return
        }
        stopDirectoryObservation()
        cancelPreviewGeneration()
        captureDates.cancel(reset: true)
        let url = inputURL.standardizedFileURL
        if isFullscreenPreview { closeFullscreenPreview() }
        metadataJob?.cancel(); metadataJob = nil; isReadingMetadata = false; metadataID = UUID()
        let ticket = UUID(); loadID = ticket
        directory = url; isLoading = true; status = L10n.text("扫描照片并合并同名格式…")
        selectedFolderID = nil
        navigationScrollTarget = nil
        assets = []; groups = []; subdirectories = []; diskImages = []; selection = []; focusedID = nil; preferredFileID = nil; scope = "all"; search = ""; showGroupOverview = false
        selectionAnchorID = nil; rangeSelectionBase = nil
        pathText = url.path; editingPath = false
        let sessions = sessions
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> (RestoredBrowserSession, DirectorySnapshot) in
                    let snapshot = try DirectorySnapshot.read(url)
                    let restored = try sessions.restore(snapshot.assets, in: url)
                    return (restored, snapshot)
                }.value
                guard loadID == ticket else { return }
                assets = result.0.assets; groups = result.0.groups; subdirectories = result.1.folders; diskImages = result.1.diskImages
                isReadOnlyDirectory = result.1.isReadOnly || activeDiskImage != nil
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
                status = result.0.note
                rememberDirectory(url)
                try saveSession()
                refreshHistory()
                startPreviewGeneration()
                ensureCaptureSortDates()
                if monitoringEnabled && !isReadOnlyDirectory { startDirectoryObservation() }
            } catch {
                guard loadID == ticket else { return }
                isLoading = false; status = L10n.text("目录加载失败"); report(error)
            }
        }
    }

}
