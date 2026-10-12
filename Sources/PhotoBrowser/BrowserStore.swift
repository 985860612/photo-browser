import AppKit
import SwiftUI
import BrowserCore

private struct StoredMetadata: Codable {
    let fingerprint: String
    let value: PhotoMetadata
}
private struct BrowserSession: Codable {
    let groups: [PhotoGroup]
    let metadata: [String: StoredMetadata]
}

@MainActor final class BrowserStore: ObservableObject {
    @Published var directory: URL?
    @Published var assets: [PhotoAsset] = []
    @Published var groups: [PhotoGroup] = []
    @Published var scope = "all"
    @Published var search = ""
    @Published var selection: Set<String> = []
    @Published var focusedID: String?
    @Published var preferredFileID: String?
    @Published var isLoading = false
    @Published var isReadingMetadata = false
    @Published var isMoving = false
    @Published var status = "选择照片目录开始浏览"
    @Published var errorMessage: String?
    @Published var archiveGroup: PhotoGroup?
    @Published var showHistory = false
    @Published var history: [ArchiveRecord] = []
    @Published var showMerge = false
    @Published var thumbnailSize: Double = 155
    @Published var showGroupOverview = false
    @Published var renameGroup: PhotoGroup?
    @Published var subdirectories: [URL] = []
    @Published var navigationHistory: [URL] = []
    @Published var navigationIndex = -1
    @Published var editingPath = false
    @Published var pathText = ""
    @Published var isFullscreenPreview = false
    @Published var hdrPreview = UserDefaults.standard.object(forKey: "hdrPreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hdrPreview, forKey: "hdrPreview") }
    }
    private weak var previewWindow: NSWindow?
    private var enteredFullscreen = false
    private var loadID = UUID()
    private var metadataID = UUID()
    private var metadataJob: MetadataReader?
    private var started = false
    private let support: URL
    let engine: ArchiveEngine

    init() {
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoBrowser", isDirectory: true)
        engine = ArchiveEngine(journalDirectory: support.appendingPathComponent("Moves", isDirectory: true))
    }

    var focusedAsset: PhotoAsset? { assets.first { $0.id == focusedID } }
    var currentGroup: PhotoGroup? { groups.first { $0.id == scope } }
    var focusedFile: PhotoFile? {
        guard let asset = focusedAsset else { return nil }
        return asset.imageFiles.first { $0.id == preferredFileID } ?? asset.preferred
    }
    var visibleAssets: [PhotoAsset] {
        let base: [PhotoAsset]
        if let group = currentGroup {
            let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            base = group.assetIDs.compactMap { byID[$0] }
        } else if scope == "ungrouped" {
            let assigned = Set(groups.flatMap(\.assetIDs))
            base = assets.filter { !assigned.contains($0.id) }
        } else { base = assets }
        return search.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.formatLabel.localizedCaseInsensitiveContains(search) }
    }
    var groupAssets: [PhotoAsset] {
        guard let group = currentGroup else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return group.assetIDs.compactMap { byID[$0] }
    }
    var ungroupedCount: Int { assets.count - Set(groups.flatMap(\.assetIDs)).count }
    var totalFiles: Int { assets.reduce(0) { $0 + $1.imageFiles.count } }
    var canArchive: Bool {
        !isMoving && !isReadingMetadata && !history.contains { ["prepared", "moving", "undoing", "recoveryNeeded"].contains($0.state) }
    }

    func start() {
        guard !started else { return }; started = true
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--directory"), index + 1 < arguments.count {
            load(URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        } else if let path = UserDefaults.standard.string(forKey: "lastDirectory") {
            load(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    func chooseDirectory() {
        guard !isMoving else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "打开照片目录"; panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ inputURL: URL, restoring restoredGroup: PhotoGroup? = nil, recordNavigation: Bool = true) {
        guard !isMoving else { return }
        let url = inputURL.standardizedFileURL
        if isFullscreenPreview { closeFullscreenPreview() }
        metadataJob?.cancel(); metadataJob = nil; isReadingMetadata = false; metadataID = UUID()
        let ticket = UUID(); loadID = ticket
        directory = url; isLoading = true; status = "扫描照片并合并同名格式…"
        assets = []; groups = []; subdirectories = []; selection = []; focusedID = nil; preferredFileID = nil; scope = "all"; search = ""; showGroupOverview = false
        pathText = url.path; editingPath = false
        let sessionURL = sessionURL(for: url)
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> ([PhotoAsset], [PhotoGroup], String, [URL]) in
                    var photos = try DirectoryScanner.scan(url)
                    let folders = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                        .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    var imported: [PhotoGroup] = []
                    var note = ""
                    if FileManager.default.fileExists(atPath: sessionURL.path) {
                        let session = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: sessionURL))
                        let existing = Set(photos.map(\.id))
                        imported = session.groups.compactMap { group in
                            var g = group; g.assetIDs = g.assetIDs.filter { existing.contains($0) }; return g.assetIDs.isEmpty ? nil : g
                        }
                        for index in photos.indices {
                            if let saved = session.metadata[photos[index].id], saved.fingerprint == Self.fingerprint(photos[index]) {
                                photos[index].metadata = saved.value
                            }
                        }
                        note = "已恢复保存的分组"
                    } else {
                        let csv = url.appendingPathComponent("全景素材筛选/全景候选文件清单.csv")
                        if FileManager.default.fileExists(atPath: csv.path) {
                            imported = try Grouping.importCSV(Data(contentsOf: csv), assets: photos)
                            note = "已导入已有全景清单"
                        }
                    }
                    return (photos, imported, note, folders)
                }.value
                guard loadID == ticket else { return }
                assets = result.0; groups = result.1; subdirectories = result.3
                if recordNavigation, navigationHistory.indices.contains(navigationIndex) == false || navigationHistory[navigationIndex] != url {
                    navigationHistory = Array(navigationHistory.prefix(navigationIndex + 1)) + [url]
                    navigationIndex = navigationHistory.count - 1
                }
                if let restoredGroup, !groups.contains(where: { $0.id == restoredGroup.id }) {
                    let existing = Set(assets.map(\.id))
                    var restored = restoredGroup; restored.assetIDs = restored.assetIDs.filter { existing.contains($0) }
                    if !restored.assetIDs.isEmpty { groups.append(restored) }
                }
                focusedID = assets.first?.id
                if let focusedID { selection = [focusedID] }
                isLoading = false
                status = "\(assets.count) 张照片 · \(totalFiles) 个图像文件 · \(groups.count) 个分组" + (result.2.isEmpty ? "" : " · \(result.2)")
                UserDefaults.standard.set(url.path, forKey: "lastDirectory")
                try saveSession()
                refreshHistory()
            } catch {
                guard loadID == ticket else { return }
                isLoading = false; status = "目录加载失败"; report(error)
            }
        }
    }

    var canGoBack: Bool { navigationIndex > 0 && !isLoading && !isMoving }
    var canGoForward: Bool { navigationIndex + 1 < navigationHistory.count && !isLoading && !isMoving }
    var breadcrumbs: [URL] {
        guard var url = directory else { return [] }
        var components = [url]
        while url.path != "/" { url.deleteLastPathComponent(); components.insert(url, at: 0) }
        return components
    }
    func navigateHistory(_ delta: Int) {
        guard delta < 0 ? canGoBack : canGoForward else { return }
        navigationIndex += delta; load(navigationHistory[navigationIndex], recordNavigation: false)
    }
    func editPath() { pathText = directory?.path ?? ""; editingPath = true }
    func openTypedPath() {
        let path = (pathText.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { report(BrowserFailure.message("请输入绝对路径，例如 /Volumes/照片库，或 ~/Pictures。")); return }
        load(URL(fileURLWithPath: path, isDirectory: true))
    }
    func rename(_ group: PhotoGroup, to input: String) {
        guard !isMoving, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\0"), !name.contains("\n") else { report(BrowserFailure.message("请输入有效的分组名称。")); return }
        groups[index].name = name; renameGroup = nil
        persistChanges("分组已重命名为“\(name)”")
    }
    func toggleFullscreenPreview() {
        guard !isMoving, focusedFile != nil else { return }
        if isFullscreenPreview { closeFullscreenPreview(); return }
        previewWindow = NSApp.keyWindow
        enteredFullscreen = previewWindow?.styleMask.contains(.fullScreen) == false
        isFullscreenPreview = true
        if enteredFullscreen { previewWindow?.toggleFullScreen(nil) }
    }
    func closeFullscreenPreview() {
        isFullscreenPreview = false
        if enteredFullscreen, previewWindow?.styleMask.contains(.fullScreen) == true { previewWindow?.toggleFullScreen(nil) }
        enteredFullscreen = false
    }
    func fullscreenWindowExited() { isFullscreenPreview = false; enteredFullscreen = false }
    func openInCameraRaw(_ asset: PhotoAsset, file: PhotoFile? = nil) {
        guard !isMoving else { return }
        let source = file ?? asset.imageFiles.first(where: { $0.kind == .raw }) ?? asset.preferred
        do { try CameraRawLauncher.open(source) { [weak self] error in
            if let error { self?.report(error) }
        } } catch { report(error) }
    }

    func changeScope() {
        guard !isMoving else { return }
        selection = []; focusedID = visibleAssets.first?.id; preferredFileID = nil
        if let focusedID { selection = [focusedID] }
        showGroupOverview = currentGroup != nil
    }

    func select(_ asset: PhotoAsset, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        if modifiers.contains(.shift), let focus = focusedID,
           let a = visibleAssets.firstIndex(where: { $0.id == focus }), let b = visibleAssets.firstIndex(where: { $0.id == asset.id }) {
            selection.formUnion(visibleAssets[min(a,b)...max(a,b)].map(\.id))
        } else if modifiers.contains(.command) {
            if selection.contains(asset.id) { selection.remove(asset.id) } else { selection.insert(asset.id) }
        } else { selection = [asset.id] }
        focusedID = asset.id; preferredFileID = nil
    }

    func step(_ offset: Int) {
        let list = visibleAssets
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == focusedID } ?? 0
        let next = max(0, min(list.count - 1, index + offset))
        select(list[next], modifiers: [])
    }

    func selectAll() { selection = Set(visibleAssets.map(\.id)) }

    func createGroup() {
        let ids = visibleAssets.filter { selection.contains($0.id) }.map(\.id)
        guard ids.count >= 2 else { report(BrowserFailure.message("请选择至少两张照片。⌘ 点击可多选，⇧ 点击可选择连续范围。")); return }
        removeMembership(ids)
        let group = PhotoGroup(name: "手动组 \(groups.count + 1)", assetIDs: ids)
        groups.append(group); scope = group.id; showGroupOverview = true
        persistChanges("已创建分组，共 \(ids.count) 张照片")
    }

    func splitGroup() {
        guard let group = currentGroup, let id = focusedID else { return }
        do {
            let split = try Grouping.split(group, at: id)
            guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
            groups.replaceSubrange(index...index, with: split); scope = split[1].id
            persistChanges("已从当前照片处分成两组")
        } catch { report(error) }
    }

    func mergeGroup(into targetID: String) {
        guard let group = currentGroup, let target = groups.first(where: { $0.id == targetID }), target.id != group.id else { return }
        let combined = Set(group.assetIDs + target.assetIDs)
        let merged = PhotoGroup(name: group.name + " + " + target.name, assetIDs: assets.filter { combined.contains($0.id) }.map(\.id))
        groups.removeAll { $0.id == group.id || $0.id == target.id }
        groups.append(merged); scope = merged.id; showMerge = false
        persistChanges("已合并两个分组")
    }

    func removeFromGroup() {
        guard let group = currentGroup, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].assetIDs.removeAll { selection.contains($0) }
        if groups[index].assetIDs.isEmpty { groups.remove(at: index); scope = "ungrouped" }
        changeScope(); persistChanges("已将所选照片移出分组，原文件未移动")
    }

    func dissolveGroup(_ group: PhotoGroup) {
        groups.removeAll { $0.id == group.id }
        if scope == group.id { scope = "all"; changeScope() }
        persistChanges("已取消分组，原文件未移动")
    }

    func confirmGroup() {
        guard let index = groups.firstIndex(where: { $0.id == scope }) else { return }
        groups[index].confidence = .candidate
        groups[index].reason = "用户已查看画面并确认属于全景素材"
        persistChanges("已确认全景分组，尚未移动文件")
    }

    func autoGroup() {
        guard let directory, !isReadingMetadata, !isMoving, !assets.isEmpty else { return }
        let snapshot = assets, job = MetadataReader(), ticket = UUID()
        metadataJob = job; metadataID = ticket; isReadingMetadata = true
        status = "读取 \(snapshot.count) 张照片的拍摄信息…NAS 首次读取可能需要几分钟，可继续浏览"
        Task {
            do {
                let metadata = try await Task.detached(priority: .utility) { try job.read(directory: directory, assets: snapshot) }.value
                guard metadataID == ticket else { return }
                for index in assets.indices { assets[index].metadata = metadata[assets[index].id] }
                groups = Grouping.candidates(assets)
                scope = "all"; showGroupOverview = false; metadataJob = nil; isReadingMetadata = false
                persistChanges("生成 \(groups.count) 个候选组；请检查画面重叠，自动分组不代表已确认全景")
            } catch {
                guard metadataID == ticket else { return }
                metadataJob = nil; isReadingMetadata = false
                if error is CancellationError { status = "已取消自动分组" } else { status = "自动分组失败"; report(error) }
            }
        }
    }

    func cancelMetadata() {
        metadataID = UUID(); metadataJob?.cancel(); metadataJob = nil; isReadingMetadata = false
        status = "已取消自动分组，已有分组保留"
    }

    func importCSV() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            do {
                groups = try Grouping.importCSV(Data(contentsOf: url), assets: assets)
                scope = "all"; changeScope(); persistChanges("已导入 \(groups.count) 个分组")
            } catch { report(error) }
        }
    }

    func updateMetadata(_ id: String, value: PhotoMetadata?) {
        guard let value, let index = assets.firstIndex(where: { $0.id == id }) else { return }
        if assets[index].metadata == nil { assets[index].metadata = value }
        else {
            // Native previews enrich display fields without changing the original burst sequence/time.
            if assets[index].metadata?.camera == nil { assets[index].metadata?.camera = value.camera }
            if assets[index].metadata?.aperture == nil { assets[index].metadata?.aperture = value.aperture }
            if assets[index].metadata?.iso == nil { assets[index].metadata?.iso = value.iso }
            if assets[index].metadata?.shutter == nil { assets[index].metadata?.shutter = value.shutter }
        }
    }

    func archive(_ plan: ArchivePlan) {
        guard canArchive else { report(BrowserFailure.message("请先完成当前任务或恢复未完成的移动记录。")); return }
        isMoving = true; archiveGroup = nil; status = "正在移动整组文件，请勿退出…"
        let worker = engine
        Task {
            do {
                let record = try await Task.detached(priority: .userInitiated) { try worker.archive(plan) }.value
                let moved = Set(record.group.assetIDs)
                assets.removeAll { moved.contains($0.id) }; removeMembership(Array(moved))
                selection = []; scope = "all"; focusedID = assets.first?.id; preferredFileID = nil; showGroupOverview = false
                if let focusedID { selection = [focusedID] }
                isMoving = false; persistChanges("已归档 \(record.group.assetIDs.count) 张照片、\(record.entries.count) 个文件，可在移动记录中撤销")
                refreshHistory()
            } catch { isMoving = false; status = "归档失败，请查看提示和移动记录"; report(error); refreshHistory() }
        }
    }

    func undo(_ record: ArchiveRecord) {
        guard !isMoving else { return }
        isMoving = true; status = "正在撤销移动…"; let worker = engine
        Task {
            do {
                let restored = try await Task.detached(priority: .userInitiated) { try worker.undo(record) }.value
                isMoving = false; showHistory = false
                load(restored.sourceDirectory, restoring: restored.group)
            } catch { isMoving = false; report(error); refreshHistory() }
        }
    }

    func refreshHistory() {
        do { history = try engine.records() } catch { report(error) }
    }

    func revealFocused() {
        if let file = focusedFile { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
    }

    func report(_ error: Error) { errorMessage = error.localizedDescription }

    private func removeMembership(_ ids: [String]) {
        let removed = Set(ids)
        for index in groups.indices { groups[index].assetIDs.removeAll { removed.contains($0) } }
        groups.removeAll { $0.assetIDs.isEmpty }
    }

    private func persistChanges(_ message: String) {
        do { try saveSession(); status = message } catch { report(error); status = "操作已执行，但分组保存失败，请勿退出" }
    }

    private func sessionURL(for directory: URL) -> URL {
        support.appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(ThumbnailCache.digest(directory.resolvingSymlinksInPath().path) + ".json")
    }

    private nonisolated static func fingerprint(_ asset: PhotoAsset) -> String {
        asset.files.map { "\($0.url.lastPathComponent)|\($0.size)|\($0.modified.timeIntervalSince1970)" }.joined(separator: ";")
    }

    private func saveSession() throws {
        guard let directory else { return }
        let url = sessionURL(for: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var metadata: [String: StoredMetadata] = [:]
        for asset in assets { if let value = asset.metadata { metadata[asset.id] = StoredMetadata(fingerprint: Self.fingerprint(asset), value: value) } }
        try JSONEncoder().encode(BrowserSession(groups: groups, metadata: metadata)).write(to: url, options: .atomic)
    }
}
