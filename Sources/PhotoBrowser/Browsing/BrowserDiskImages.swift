import AppKit
import BrowserCore

extension BrowserStore {
    var navigationEntries: [URL] {
        (subdirectories + diskImages).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    var isOperatingDiskImage: Bool { mountingDiskImage != nil || isEjectingDiskImage }
    var activeDiskImage: MountedDiskImage? {
        guard let directory else { return nil }
        return mountedDiskImages.first { $0.contains(directory) }
    }
    var directoryDisplayName: String {
        if let image = activeDiskImage, directory?.standardizedFileURL == image.root.standardizedFileURL {
            return image.source.deletingPathExtension().lastPathComponent
        }
        return directory?.lastPathComponent ?? L10n.text("文件夹")
    }
    var selectedEntryDescription: String? {
        guard let selectedFolderID else { return nil }
        return diskImages.contains(where: { $0.path == selectedFolderID }) ? L10n.text("1 个镜像已选") : L10n.text("1 个目录已选")
    }

    func openDiskImage(_ source: URL, relativePath: String = "") {
        guard !isMoving, !isOperatingDiskImage, !isExportingLivePhotoVideo else { return }
        let ticket = UUID(); loadID = ticket
        mountingDiskImage = source; isLoading = true; errorMessage = nil
        stopDirectoryObservation(); cancelPreviewGeneration(); cancelMetadata()
        status = L10n.text("正在只读加载镜像：\(source.lastPathComponent)")
        Task {
            defer { mountingDiskImage = nil }
            do {
                let image = try await diskImageService.mount(source)
                if !mountedDiskImages.contains(where: { $0.root == image.root }) { mountedDiskImages.append(image) }
                // Navigating elsewhere while a slow NAS mount finishes must not pull the user back.
                guard loadID == ticket else { return }
                let target = image.root.appendingPathComponent(relativePath).standardizedFileURL
                guard image.contains(target) else { throw BrowserFailure.message(L10n.text("镜像内路径无效。")) }
                isLoading = false
                load(target)
            } catch {
                guard loadID == ticket else { return }
                isLoading = false; status = L10n.text("镜像加载失败"); report(error)
                if monitoringEnabled && directory != nil { startDirectoryObservation() }
            }
        }
    }

    func goUp() {
        guard let directory, !isMoving, !isLoading, !isEjectingDiskImage else { return }
        if let image = activeDiskImage, directory.standardizedFileURL == image.root.standardizedFileURL {
            load(image.source.deletingLastPathComponent())
        } else { load(directory.deletingLastPathComponent()) }
    }

    func rememberDirectory(_ url: URL) {
        preferencesDefaults.set(url.path, forKey: "lastDirectory")
        if let image = activeDiskImage {
            preferencesDefaults.set(image.source.path, forKey: "lastDiskImagePath")
            let relative = String(url.standardizedFileURL.path.dropFirst(image.root.standardizedFileURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            preferencesDefaults.set(relative, forKey: "lastDiskImageRelativePath")
        } else {
            preferencesDefaults.removeObject(forKey: "lastDiskImagePath")
            preferencesDefaults.removeObject(forKey: "lastDiskImageRelativePath")
        }
    }

    func ejectDiskImage(_ image: MountedDiskImage) {
        guard !isOperatingDiskImage, !isMoving, !isLoading, !isExportingLivePhotoVideo, !isCopyingImage else { return }
        isEjectingDiskImage = true; isLoading = true
        let previous = directory
        let wasInside = previous.map(image.contains) ?? false
        if wasInside {
            stopDirectoryObservation(); cancelPreviewGeneration(); cancelMetadata()
            if isFullscreenPreview { closeFullscreenPreview() }
        }
        status = L10n.text("正在推出镜像：\(image.source.lastPathComponent)")
        Task {
            defer { isEjectingDiskImage = false }
            do {
                try await diskImageService.eject(image)
                mountedDiskImages.removeAll { $0.root == image.root }
                // Detached mount points must not remain as broken back/forward destinations.
                let preceding = navigationHistory.prefix(max(0, navigationIndex + 1)).filter { !image.contains($0) }.count
                navigationHistory.removeAll { image.contains($0) }; navigationIndex = preceding - 1
                isEjectingDiskImage = false; isLoading = false
                if wasInside, directory == previous { load(image.source.deletingLastPathComponent()) }
                else { status = L10n.text("已推出镜像：\(image.source.lastPathComponent)") }
            } catch {
                status = L10n.text("镜像推出失败，请关闭正在使用镜像的程序后重试。")
                report(error)
                isEjectingDiskImage = false; isLoading = false
                if wasInside, let previous { load(previous, recordNavigation: false) }
            }
        }
    }

    func ejectDiskImagesForTermination() async throws {
        isEjectingDiskImage = true; isLoading = true
        defer { isEjectingDiskImage = false; isLoading = false }
        for image in mountedDiskImages {
            try await diskImageService.eject(image)
            mountedDiskImages.removeAll { $0.root == image.root }
        }
    }
}
