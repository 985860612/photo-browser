import AppKit
import SwiftUI
import BrowserCore
import CoreImage

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
    @Published var selectedFolderID: String?
    @Published private(set) var navigationScrollTarget: String?
    @Published var focusedID: String? { didSet { if focusedID != oldValue { video.stop() } } }
    @Published var preferredFileID: String? { didSet { if preferredFileID != oldValue, video.fileID != focusedFile?.id { video.stop() } } }
    @Published var isLoading = false
    @Published var isReadingMetadata = false
    @Published var isMoving = false
    @Published var isGeneratingPreviews = false
    @Published var previewCompleted = 0
    @Published var previewTotal = 0
    @Published var previewFailures = 0
    @Published var previewFailureDetails = ""
    private var previewTask: Task<Void, Never>?
    private struct AdjacentKey: Hashable {
        let file: PhotoFile
        let hdr: Bool
        let maximum: Int?
    }
    private struct AdjacentJob {
        let ticket: UUID
        let task: Task<Void, Never>
    }
    private var adjacentJobs: [AdjacentKey: AdjacentJob] = [:]
    private let displayCache: DisplayPhotoCache
    let video = VideoPlayback()
    private let clipboardWorkers = PreviewWorkQueue()
    @Published private(set) var isCopyingImage = false
    private var clipboardTask: Task<Void, Never>?
    private var clipboardTicket = UUID()
    private var previewID = UUID()
    private var previewQueue: [PhotoFile] = []
    @Published var status = L10n.text("选择照片目录开始浏览")
    @Published var errorMessage: String?
    @Published var archiveGroup: PhotoGroup?
    @Published var showHistory = false
    @Published var history: [ArchiveRecord] = []
    @Published var showMerge = false
    @Published var thumbnailSize: Double = 155 {
        didSet {
            let bounded = BrowserPanelLayout.clamp(thumbnailSize, to: 110...360, fallback: 155)
            if thumbnailSize != bounded { thumbnailSize = bounded; return }
            preferencesDefaults.set(thumbnailSize, forKey: "thumbnailSize")
        }
    }
    @Published var previewBefore = 2 {
        didSet {
            let bounded = PreviewPreferences.clamp(previewBefore)
            if previewBefore != bounded { previewBefore = bounded; return }
            previewPreferences.before = previewBefore
        }
    }
    @Published var previewAfter = 5 {
        didSet {
            let bounded = PreviewPreferences.clamp(previewAfter)
            if previewAfter != bounded { previewAfter = bounded; return }
            previewPreferences.after = previewAfter
        }
    }
    private let previewPreferences: PreviewPreferences
    private let preferencesDefaults: UserDefaults
    @Published var showGroupOverview = false { didSet { if showGroupOverview { video.pause() } } }
    @Published var renameGroup: PhotoGroup?
    @Published var subdirectories: [URL] = []
    @Published private(set) var folderCacheRevision = UUID()
    let folderSummaries: FolderSummaryCache
    let folderSizes: FolderSizeCache
    @Published var navigationHistory: [URL] = []
    @Published var navigationIndex = -1
    @Published var editingPath = false
    @Published var pathText = ""
    @Published var isFullscreenPreview = false
    @Published var preferRawPreview = UserDefaults.standard.bool(forKey: "preferRawPreview") {
        didSet {
            UserDefaults.standard.set(preferRawPreview, forKey: "preferRawPreview")
            preferredFileID = nil
        }
    }
    @Published var hdrPreview = UserDefaults.standard.object(forKey: "hdrPreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hdrPreview, forKey: "hdrPreview") }
    }
    private weak var previewWindow: NSWindow?
    private var enteredFullscreen = false
    private var loadID = UUID()
    private var metadataID = UUID()
    private var metadataJob: MetadataReader?
    private var started = false
    private var selectionAnchorID: String?
    private var rangeSelectionBase: Set<String>?
    private let support: URL
    private let thumbnails: ThumbnailCache
    let engine: ArchiveEngine

    init(supportDirectory: URL? = nil, thumbnails: ThumbnailCache = .shared, defaults: UserDefaults = .standard, displayCache: DisplayPhotoCache = .shared,
         folderSummaries: FolderSummaryCache = .shared, folderSizes: FolderSizeCache = .shared) {
        self.folderSummaries = folderSummaries; self.folderSizes = folderSizes
        preferencesDefaults = defaults
        previewPreferences = PreviewPreferences(defaults: defaults)
        previewBefore = previewPreferences.before; previewAfter = previewPreferences.after
        thumbnailSize = BrowserPanelLayout.clamp(defaults.object(forKey: "thumbnailSize") as? Double ?? 155, to: 110...360, fallback: 155)
        support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoBrowser", isDirectory: true)
        self.thumbnails = thumbnails
        self.displayCache = displayCache
        engine = ArchiveEngine(journalDirectory: support.appendingPathComponent("Moves", isDirectory: true))
    }

    var selectedItemID: String? { selectedFolderID.map { "folder:" + $0 } ?? focusedID }
    var focusedAsset: PhotoAsset? { assets.first { $0.id == focusedID } }
    var currentGroup: PhotoGroup? { groups.first { $0.id == scope } }
    var focusedFile: PhotoFile? {
        guard let asset = focusedAsset else { return nil }
        return asset.mediaFiles.first { $0.id == preferredFileID }
            ?? asset.imageFiles.first { $0.kind == (preferRawPreview ? .raw : .rendered) }
            ?? asset.preferred
    }
    var previewRequestID: String {
        let file = focusedFile
        return "\(file?.id ?? "")|\(file?.size ?? 0)|\(file?.modified.timeIntervalSince1970 ?? 0)|\(hdrPreview)|\(preferRawPreview)|\(previewBefore)|\(previewAfter)|\(scope)|\(search)|\(selectedFolderID ?? "")|\(isFullscreenPreview)"
    }
    var adjacentPreviewFiles: [PhotoFile] {
        guard selectedFolderID == nil, let index = visibleAssets.firstIndex(where: { $0.id == focusedID }) else { return [] }
        return PreviewPreferences.neighbors(in: visibleAssets, index: index, before: previewBefore, after: previewAfter).filter { !$0.isVideo }.map { asset in
            asset.imageFiles.first { $0.kind == (preferRawPreview ? .raw : .rendered) } ?? asset.preferred
        }
    }
    func preparePreviewCache() async {
        let requestID = previewRequestID
        let current = selectedFolderID == nil && !isMoving && !isLoading && focusedFile?.kind != .video ? focusedFile : nil
        let neighbors = current == nil ? [] : adjacentPreviewFiles
        let hdr = hdrPreview, maximum: Int? = isFullscreenPreview ? nil : 2800
        await displayCache.setWorkingSet(current: current, neighbors: neighbors, hdr: hdr)
        guard !Task.isCancelled, requestID == previewRequestID, !isMoving, !isLoading else { return }
        let keys = neighbors.map { AdjacentKey(file: $0, hdr: hdr, maximum: maximum) }
        var retained = Set(keys)
        // A neighbor that becomes visible keeps its decode: the foreground joins/promotes it.
        if let current { retained.insert(AdjacentKey(file: current, hdr: hdr, maximum: maximum)) }
        for key in Array(adjacentJobs.keys) where !retained.contains(key) {
            adjacentJobs.removeValue(forKey: key)?.task.cancel()
        }
        for key in keys where adjacentJobs[key] == nil {
            let ticket = UUID(), cache = displayCache
            let task = Task { [weak self] in
                do { _ = try await cache.image(key.file, hdr: key.hdr, maximum: key.maximum, background: true) }
                catch { /* Bad or cancelled neighbors must not stop the rest of the range. */ }
                if self?.adjacentJobs[key]?.ticket == ticket { self?.adjacentJobs.removeValue(forKey: key) }
            }
            adjacentJobs[key] = AdjacentJob(ticket: ticket, task: task)
        }
    }
    func cancelAdjacentPreviews() {
        for job in adjacentJobs.values { job.task.cancel() }
        adjacentJobs.removeAll()
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
    var directorySummary: String {
        let videos = assets.filter(\.isVideo).count
        if videos > 0 { return L10n.text("\(assets.count - videos) 张照片 · \(videos) 个视频 · \(totalFiles + videos) 个媒体文件 · \(groups.count) 个分组") }
        return L10n.text("\(assets.count) 张照片 · \(totalFiles) 个图像文件 · \(groups.count) 个分组")
    }
    var canArchive: Bool {
        !isMoving && !isReadingMetadata && !history.contains { ["prepared", "moving", "undoing", "recoveryNeeded"].contains($0.state) }
    }
    var canDeleteSelection: Bool {
        canArchive && !isLoading && !editingPath && selectedFolderID == nil
            && directory != nil && directory?.lastPathComponent.lowercased() != "_del"
            && visibleAssets.contains { selection.contains($0.id) }
    }

    func handleKeyDown(_ event: NSEvent, in window: NSWindow?) -> NSEvent? {
        guard !isMoving else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if isFullscreenPreview, event.keyCode == 53, modifiers.intersection([.command, .control, .option]).isEmpty { closeFullscreenPreview(); return nil }
        guard let window, !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
              window.identifier?.rawValue != "PhotoBrowser.Settings",
              !isLoading, window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
        if event.keyCode == 8, modifiers == .command, canCopyFiles {
            copyFilesToClipboard(); return nil
        }
        if event.keyCode == 8, modifiers == [.command, .shift], selectedFolderID == nil, focusedFile != nil, focusedFile?.kind != .video {
            if !event.isARepeat { copyImageToClipboard() }
            return nil
        }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return event }
        if event.keyCode == 51 || event.keyCode == 117 {
            // Holding Delete must not remove the next automatically selected photo.
            if !event.isARepeat { deleteSelection() }
            return nil
        }
        if event.keyCode == 123 || event.keyCode == 124 {
            step(event.keyCode == 123 ? -1 : 1, extendingSelection: event.modifierFlags.contains(.shift))
            return nil
        }
        if (event.keyCode == 36 || event.keyCode == 76), selectedFolderID != nil {
            openSelectedFolder(); return nil
        }
        if event.keyCode == 49, focusedFile != nil, selectedFolderID == nil {
            if focusedFile?.kind == .video { if !event.isARepeat { toggleVideoPlayback() }; return nil }
            toggleFullscreenPreview(); return nil
        }
        return event
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

    private func invalidateFolderCaches(_ urls: [URL], descendants: Bool = false) async {
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
        cancelPreviewGeneration()
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
                        note = L10n.text("已恢复保存的分组")
                    } else {
                        let csv = url.appendingPathComponent("全景素材筛选/全景候选文件清单.csv")
                        if FileManager.default.fileExists(atPath: csv.path) {
                            imported = try Grouping.importCSV(Data(contentsOf: csv), assets: photos)
                            note = L10n.text("已导入已有全景清单")
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
                if let restoringDeletedGroups {
                    restoreDeletedMembership(restoringDeletedGroups, assetIDs: Set(restoredGroup?.assetIDs ?? []))
                } else if let restoredGroup, !groups.contains(where: { $0.id == restoredGroup.id }) {
                    let existing = Set(assets.map(\.id))
                    var restored = restoredGroup; restored.assetIDs = restored.assetIDs.filter { existing.contains($0) }
                    if !restored.assetIDs.isEmpty { groups.append(restored) }
                }
                focusedID = assets.first?.id
                if let focusedID { selection = [focusedID] }
                isLoading = false
                status = result.2
                UserDefaults.standard.set(url.path, forKey: "lastDirectory")
                try saveSession()
                refreshHistory()
                startPreviewGeneration()
            } catch {
                guard loadID == ticket else { return }
                isLoading = false; status = L10n.text("目录加载失败"); report(error)
            }
        }
    }

    func cancelPreviewGeneration() {
        video.stop()
        cancelAdjacentPreviews()
        previewID = UUID(); previewTask?.cancel(); previewTask = nil
        previewQueue = []; isGeneratingPreviews = false
        previewCompleted = 0; previewTotal = 0; previewFailures = 0; previewFailureDetails = ""
    }

    private func startPreviewGeneration() {
        cancelPreviewGeneration()
        guard !isMoving, !isLoading, !assets.isEmpty else { return }
        previewQueue = assets.map(\.preferred)
        previewTotal = previewQueue.count; isGeneratingPreviews = true
        let ticket = previewID
        prioritizePreviews(visibleAssets.prefix(48).map(\.preferred))
        previewTask = Task {
            var completed = 0, failures = 0, details: [String] = []
            var lastUpdate = Date.distantPast
            while previewID == ticket, !Task.isCancelled, !previewQueue.isEmpty {
                let file = previewQueue.removeFirst()
                do { _ = try await thumbnails.image(file, maximum: 520, background: true) }
                catch is CancellationError { return }
                catch {
                    failures += 1
                    if details.count < 20 { details.append("\(file.url.lastPathComponent)：\(error.localizedDescription)") }
                }
                guard previewID == ticket, !Task.isCancelled else { return }
                completed += 1
                // Publishing each cache hit would needlessly redraw the whole gallery.
                if Date().timeIntervalSince(lastUpdate) >= 0.25 || previewQueue.isEmpty {
                    previewCompleted = completed; previewFailures = failures
                    previewFailureDetails = details.joined(separator: "\n")
                    lastUpdate = Date()
                }
            }
            guard previewID == ticket, !Task.isCancelled else { return }
            do { try await thumbnails.trim(protecting: assets.map(\.preferred)) }
            catch is CancellationError { return }
            catch { previewFailureDetails += L10n.text("\n缓存清理失败：\(error.localizedDescription)") }
            guard previewID == ticket, !Task.isCancelled else { return }
            isGeneratingPreviews = false; previewTask = nil
        }
    }

    private func prioritizePreviews(_ files: [PhotoFile]) {
        guard isGeneratingPreviews else { return }
        let rank = Dictionary(files.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
        let priority = previewQueue.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        previewQueue = priority + previewQueue.filter { rank[$0.id] == nil }
    }

    func previewAppeared(_ asset: PhotoAsset) {
        guard isGeneratingPreviews else { return }
        let list = visibleAssets
        guard let index = list.firstIndex(where: { $0.id == asset.id }) else { return }
        // Warm the following screenful before the user scrolls into it.
        prioritizePreviews(list[max(0, index - 4)..<min(list.count, index + 25)].map(\.preferred))
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
        guard path.hasPrefix("/") else { report(BrowserFailure.message(L10n.text("请输入绝对路径，例如 /Volumes/照片库，或 ~/Pictures。"))); return }
        load(URL(fileURLWithPath: path, isDirectory: true))
    }
    func rename(_ group: PhotoGroup, to input: String) {
        guard !isMoving, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\0"), !name.contains("\n") else { report(BrowserFailure.message(L10n.text("请输入有效的分组名称。"))); return }
        groups[index].name = name; renameGroup = nil
        persistChanges(L10n.text("分组已重命名为“\(name)”"))
    }
    func toggleFullscreenPreview() {
        guard !isMoving, selectedFolderID == nil, focusedFile != nil else { return }
        if isFullscreenPreview { closeFullscreenPreview(); return }
        previewWindow = NSApp.keyWindow
        enteredFullscreen = previewWindow?.styleMask.contains(.fullScreen) == false
        isFullscreenPreview = true
        if enteredFullscreen { previewWindow?.toggleFullScreen(nil) }
    }

    func toggleVideoPlayback() {
        guard !isMoving, !isLoading, selectedFolderID == nil, let file = focusedFile, file.kind == .video else { return }
        if showGroupOverview { showGroupOverview = false; video.playWhenReady(file) }
        else if video.fileID == file.id { video.toggle() }
        else { video.playWhenReady(file) }
    }

    func playVideo(_ asset: PhotoAsset) {
        guard asset.isVideo, !isMoving, !isLoading else { return }
        select(asset, modifiers: []); showGroupOverview = false; video.playWhenReady(asset.preferred)
    }
    func closeFullscreenPreview() {
        isFullscreenPreview = false
        if enteredFullscreen, previewWindow?.styleMask.contains(.fullScreen) == true { previewWindow?.toggleFullScreen(nil) }
        enteredFullscreen = false
    }
    func fullscreenWindowExited() { isFullscreenPreview = false; enteredFullscreen = false }
    func openInCameraRaw(_ asset: PhotoAsset, file: PhotoFile? = nil) {
        guard !isMoving, !asset.isVideo else { return }
        let source = file ?? asset.imageFiles.first(where: { $0.kind == .raw }) ?? asset.preferred
        do { try CameraRawLauncher.open(source) { [weak self] error in
            if let error { self?.report(error) }
        } } catch { report(error) }
    }

    var canCopyFiles: Bool {
        !isMoving && !isLoading && (selectedFolderID != nil || visibleAssets.contains { selection.contains($0.id) })
    }

    func copyFilesToClipboard(_ asset: PhotoAsset? = nil, pasteboard: NSPasteboard = .general) {
        guard !isMoving, !isLoading else { return }
        let targets = asset.map { selection.contains($0.id) ? visibleAssets.filter { selection.contains($0.id) } : [$0] }
            ?? visibleAssets.filter { selection.contains($0.id) }
        let urls: [URL]
        if asset == nil, let folder = selectedFolderID { urls = [URL(fileURLWithPath: folder)] }
        else { urls = targets.flatMap { $0.files.map(\.url) } }
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0.standardizedFileURL).inserted }
        guard !unique.isEmpty else { return }
        clipboardTask?.cancel(); clipboardTicket = UUID(); isCopyingImage = false
        pasteboard.clearContents()
        if pasteboard.writeObjects(unique.map { $0 as NSURL }) {
            status = L10n.text("已复制 \(unique.count) 个文件到剪贴板")
        } else { report(BrowserFailure.message(L10n.text("无法写入剪贴板，请重试。"))) }
    }

    func copyImageToClipboard(_ asset: PhotoAsset? = nil, pasteboard: NSPasteboard = .general) {
        guard !isMoving, !isLoading, !isCopyingImage else { return }
        let source: PhotoFile?
        if let asset, asset.id != focusedID {
            source = asset.imageFiles.first { $0.kind == (preferRawPreview ? .raw : .rendered) } ?? asset.preferred
        } else { source = focusedFile }
        guard let source, source.kind != .video, asset != nil || selectedFolderID == nil else { return }
        clipboardTask?.cancel()
        let ticket = UUID(), count = pasteboard.changeCount, cache = displayCache, workers = clipboardWorkers
        clipboardTicket = ticket; isCopyingImage = true
        status = L10n.text("正在复制图片…")
        clipboardTask = Task { [weak self] in
            defer { if self?.clipboardTicket == ticket { self?.isCopyingImage = false } }
            do {
                let photo = try await cache.image(source, hdr: false, maximum: nil)
                try Task.checkCancellation()
                let data = try await workers.run(background: true) { check in
                    try check()
                    let context = CIContext(), colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                    guard let png = context.pngRepresentation(of: photo.image, format: .RGBA8, colorSpace: colorSpace) else {
                        throw BrowserFailure.message(L10n.text("无法生成剪贴板图片，请切换照片格式后重试。"))
                    }
                    try check()
                    guard let tiff = context.tiffRepresentation(of: photo.image, format: .RGBA8, colorSpace: colorSpace) else {
                        throw BrowserFailure.message(L10n.text("无法生成剪贴板图片，请切换照片格式后重试。"))
                    }
                    return (png, tiff)
                }
                try Task.checkCancellation()
                guard let self, self.clipboardTicket == ticket else { return }
                guard pasteboard.changeCount == count else {
                    self.status = L10n.text("剪贴板已有新内容，已取消复制图片")
                    return
                }
                let item = NSPasteboardItem()
                item.setData(data.0, forType: .png); item.setData(data.1, forType: .tiff)
                pasteboard.clearContents()
                guard pasteboard.writeObjects([item]) else { throw BrowserFailure.message(L10n.text("无法写入剪贴板，请重试。")) }
                self.status = L10n.text("已复制图片到剪贴板")
            } catch is CancellationError {}
            catch { if self?.clipboardTicket == ticket { self?.report(error) } }
        }
    }

    func changeScope() {
        guard !isMoving else { return }
        selectedFolderID = nil
        selection = []; focusedID = visibleAssets.first?.id; preferredFileID = nil
        if let focusedID { selection = [focusedID] }
        showGroupOverview = currentGroup != nil
        selectionAnchorID = focusedID; rangeSelectionBase = nil
        navigationScrollTarget = selectedItemID
        prioritizePreviews(visibleAssets.prefix(48).map(\.preferred))
    }

    func selectFolder(_ url: URL) {
        video.stop()
        guard !isMoving, !isLoading else { return }
        navigationScrollTarget = nil
        selectedFolderID = url.path
        selection = []; selectionAnchorID = nil; rangeSelectionBase = nil
    }

    func select(_ asset: PhotoAsset, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        navigationScrollTarget = nil
        selectedFolderID = nil
        let list = visibleAssets
        if modifiers.contains(.shift), let b = list.firstIndex(where: { $0.id == asset.id }) {
            let anchor = selectionAnchorID ?? focusedID ?? asset.id
            let a = list.firstIndex(where: { $0.id == anchor }) ?? list.firstIndex(where: { $0.id == focusedID }) ?? b
            selectionAnchorID = list[a].id
            let visibleIDs = Set(list.map(\.id))
            let base = (rangeSelectionBase ?? selection).intersection(visibleIDs)
            rangeSelectionBase = base
            selection = base.union(list[min(a,b)...max(a,b)].map(\.id))
        } else if modifiers.contains(.command) {
            if selection.contains(asset.id) { selection.remove(asset.id) } else { selection.insert(asset.id) }
            selectionAnchorID = asset.id; rangeSelectionBase = nil
        } else {
            selection = [asset.id]
            selectionAnchorID = asset.id; rangeSelectionBase = nil
        }
        focusedID = asset.id; preferredFileID = nil
    }

    func step(_ offset: Int, extendingSelection: Bool = false) {
        guard !isMoving, !isLoading else { return }
        let list = visibleAssets
        // Fullscreen and range selection operate on photos; normal browsing follows every displayed item.
        let folders = scope == "all" && !isFullscreenPreview && !extendingSelection ? subdirectories : []
        let total = folders.count + list.count
        guard total > 0 else { return }
        let index: Int?
        if let folder = selectedFolderID, let position = folders.firstIndex(where: { $0.path == folder }) {
            index = position
        } else if selectedFolderID == nil, let position = list.firstIndex(where: { $0.id == focusedID }) {
            index = folders.count + position
        } else { index = nil }
        let next = index.map { max(0, min(total - 1, $0 + offset)) } ?? 0
        if next < folders.count { selectFolder(folders[next]) }
        else { select(list[next - folders.count], modifiers: extendingSelection ? [.shift] : []) }
        navigationScrollTarget = selectedItemID
    }

    func openSelectedFolder() {
        guard !isMoving, !isLoading, let path = selectedFolderID,
              let url = subdirectories.first(where: { $0.path == path }) else { return }
        load(url)
    }

    func selectAll() {
        selectedFolderID = nil
        selection = Set(visibleAssets.map(\.id))
        selectionAnchorID = focusedID; rangeSelectionBase = nil
    }

    func createGroup() {
        let ids = visibleAssets.filter { selection.contains($0.id) }.map(\.id)
        guard ids.count >= 2 else { report(BrowserFailure.message(L10n.text("请选择至少两张照片。⌘ 点击可多选，⇧ 点击可选择连续范围。"))); return }
        removeMembership(ids)
        let group = PhotoGroup(name: L10n.text("手动组 \(groups.count + 1)"), assetIDs: ids)
        groups.append(group); scope = group.id; showGroupOverview = true
        persistChanges(L10n.text("已创建分组，共 \(ids.count) 张照片"))
    }

    func splitGroup() {
        guard let group = currentGroup, let id = focusedID else { return }
        do {
            let split = try Grouping.split(group, at: id)
            guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
            groups.replaceSubrange(index...index, with: split); scope = split[1].id
            persistChanges(L10n.text("已从当前照片处分成两组"))
        } catch { report(error) }
    }

    func mergeGroup(into targetID: String) {
        guard let group = currentGroup, let target = groups.first(where: { $0.id == targetID }), target.id != group.id else { return }
        let combined = Set(group.assetIDs + target.assetIDs)
        let merged = PhotoGroup(name: group.name + " + " + target.name, assetIDs: assets.filter { combined.contains($0.id) }.map(\.id))
        groups.removeAll { $0.id == group.id || $0.id == target.id }
        groups.append(merged); scope = merged.id; showMerge = false
        persistChanges(L10n.text("已合并两个分组"))
    }

    func removeFromGroup() {
        guard let group = currentGroup, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].assetIDs.removeAll { selection.contains($0) }
        if groups[index].assetIDs.isEmpty { groups.remove(at: index); scope = "ungrouped" }
        changeScope(); persistChanges(L10n.text("已将所选照片移出分组，原文件未移动"))
    }

    func dissolveGroup(_ group: PhotoGroup) {
        groups.removeAll { $0.id == group.id }
        if scope == group.id { scope = "all"; changeScope() }
        persistChanges(L10n.text("已取消分组，原文件未移动"))
    }

    func autoGroup() {
        guard let directory, !isReadingMetadata, !isMoving, !assets.isEmpty else { return }
        let snapshot = assets.filter { !$0.isVideo }, job = MetadataReader(), ticket = UUID()
        guard !snapshot.isEmpty else { return }
        metadataJob = job; metadataID = ticket; isReadingMetadata = true
        status = L10n.text("读取 \(snapshot.count) 张照片的拍摄信息…NAS 首次读取可能需要几分钟，可继续浏览")
        Task {
            do {
                let metadata = try await Task.detached(priority: .utility) { try job.read(directory: directory, assets: snapshot) }.value
                guard metadataID == ticket else { return }
                for index in assets.indices where !assets[index].isVideo { assets[index].metadata = metadata[assets[index].id] }
                groups = Grouping.candidates(assets)
                scope = "all"; showGroupOverview = false; metadataJob = nil; isReadingMetadata = false
                persistChanges(L10n.text("生成 \(groups.count) 个候选组；请检查画面重叠，自动分组不代表已确认全景"))
            } catch {
                guard metadataID == ticket else { return }
                metadataJob = nil; isReadingMetadata = false
                if error is CancellationError { status = L10n.text("已取消自动分组") } else { status = L10n.text("自动分组失败"); report(error) }
            }
        }
    }

    func cancelMetadata() {
        metadataID = UUID(); metadataJob?.cancel(); metadataJob = nil; isReadingMetadata = false
        status = L10n.text("已取消自动分组，已有分组保留")
    }

    func importCSV() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            do {
                groups = try Grouping.importCSV(Data(contentsOf: url), assets: assets)
                scope = "all"; changeScope(); persistChanges(L10n.text("已导入 \(groups.count) 个分组"))
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

    func deleteSelection() {
        guard canDeleteSelection, let directory else { return }
        do {
            let selected = visibleAssets.filter { selection.contains($0.id) }
            let plan = try ArchivePlan.pendingDeletion(directory: directory, assets: selected, groups: groups)
            archive(plan)
        } catch { report(error) }
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

    func revealFocused() {
        if let file = focusedFile { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
    }

    func report(_ error: Error) { errorMessage = error.localizedDescription }

    private func removeMembership(_ ids: [String]) {
        let removed = Set(ids)
        for index in groups.indices { groups[index].assetIDs.removeAll { removed.contains($0) } }
        groups.removeAll { $0.assetIDs.isEmpty }
    }

    private func restoreDeletedMembership(_ savedGroups: [PhotoGroup], assetIDs: Set<String>) {
        let restoredIDs = assetIDs.intersection(assets.map(\.id))
        let currentGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        removeMembership(Array(restoredIDs))
        for saved in savedGroups {
            let recovered = saved.assetIDs.filter { restoredIDs.contains($0) }
            guard !recovered.isEmpty else { continue }
            if let index = groups.firstIndex(where: { $0.id == saved.id }) {
                var ordered = groups[index].assetIDs
                for id in recovered {
                    let position = saved.assetIDs.firstIndex(of: id)!
                    if let next = saved.assetIDs.dropFirst(position + 1).first(where: { ordered.contains($0) }),
                       let anchor = ordered.firstIndex(of: next) {
                        ordered.insert(id, at: anchor)
                    } else if let previous = saved.assetIDs.prefix(position).last(where: { ordered.contains($0) }),
                              let anchor = ordered.firstIndex(of: previous) {
                        ordered.insert(id, at: anchor + 1)
                    } else { ordered.append(id) }
                }
                groups[index].assetIDs = ordered
            } else {
                var group = currentGroups[saved.id] ?? saved
                group.assetIDs = recovered; groups.append(group)
            }
        }
    }

    private func persistChanges(_ message: String) {
        do { try saveSession(); status = message } catch { report(error); status = L10n.text("操作已执行，但分组保存失败，请勿退出") }
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
