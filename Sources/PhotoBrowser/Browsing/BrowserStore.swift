import AppKit
import SwiftUI
import BrowserCore
import Combine

@MainActor final class BrowserStore: ObservableObject {
    var directoryKnownAssets: [PhotoAsset] = []
    @Published var directory: URL?
    @Published var assets: [PhotoAsset] = [] { didSet { visibleOrdering = nil } }
    @Published var groups: [PhotoGroup] = [] { didSet { visibleOrdering = nil } }
    @Published var scope = "all" { didSet { visibleOrdering = nil; if scope != oldValue { gridScrollID = nil } } }
    @Published var search = "" { didSet { visibleOrdering = nil; if search != oldValue { gridScrollID = nil } } }
    var visibleOrdering: [PhotoAsset]? { didSet { visiblePositions = nil } }
    private var visiblePositions: [String: Int]?
    @Published var previewSortField: PreviewSortField = .original { didSet { if oldValue != previewSortField { sortingChanged() } } }
    @Published var previewSortDescending = false { didSet { if oldValue != previewSortDescending { sortingChanged() } } }
    @Published var sortingRevision = UUID()
    var isReadingSortDates: Bool { captureDates.loading }
    let captureDates: CaptureDateLoader
    @Published var selection: Set<String> = []
    @Published var selectedFolderID: String?
    @Published var navigationScrollTarget: String?
    // Fullscreen replaces the grid, so its visible-row anchor belongs to the store.
    @Published var gridScrollID: String?
    @Published var focusedID: String? {
        didSet {
            if focusedID != oldValue {
                video.stop(); livePhotoMotionID = nil; observeFocusedFiles()
                if isFullscreenPreview { gridScrollID = focusedID }
            }
        }
    }
    @Published var preferredFileID: String? { didSet { if preferredFileID != oldValue { if livePhotoMotionID != nil || video.fileID != focusedFile?.id { video.stop() }; livePhotoMotionID = nil } } }
    @Published var isLoading = false
    @Published var livePhotoMotionID: String?
    @Published var isReadingMetadata = false
    @Published var isMoving = false
    @Published var isExportingLivePhotoVideo = false
    let previewCoordinator: PreviewCoordinator
    var isGeneratingPreviews: Bool { previewCoordinator.thumbnailsProgress.running }
    var previewCompleted: Int { previewCoordinator.thumbnailsProgress.completed }
    var previewTotal: Int { previewCoordinator.thumbnailsProgress.total }
    var previewFailures: Int { previewCoordinator.thumbnailsProgress.failures }
    var previewFailureDetails: String { previewCoordinator.thumbnailsProgress.details }
    let displayCache: DisplayPhotoCache
    let video: VideoPlayback
    var adjacentReady: Int { previewCoordinator.adjacentReady }
    var adjacentTotal: Int { previewCoordinator.adjacentTotal }
    var adjacentVideoReady: Int { previewCoordinator.adjacentVideoReady }
    var adjacentVideoTotal: Int { previewCoordinator.adjacentVideoTotal }
    @Published var previewContentRevision = UUID()
    @Published var diskLimitGB = 2 {
        didSet { preferencesDefaults.set(diskLimitGB, forKey: "thumbnailDiskLimitGB") }
    }
    @Published var diskUsage: ThumbnailDiskUsage?
    @Published var livePhotoDiskUsage: LivePhotoCache.Usage?
    @Published var previewStatistics: DisplayPhotoCache.Statistics?
    @Published var diagnostics = PreviewDiagnostics.shared.snapshot()
    @Published var cacheBusy = false
    @Published var cacheFailure: String?
    var directoryObserver: DirectoryObserver?
    var observationStartTask: Task<Void, Never>?
    var automaticRefreshTask: Task<Void, Never>?
    var refreshRequested = false
    var refreshFullRequested = false
    var observedFolderDates: [String: Date] = [:]
    var observationRevision = UUID()
    let observationWorkers = PreviewWorkQueue()
    let monitoringEnabled: Bool
    let clipboardWorkers = PreviewWorkQueue()
    @Published var isCopyingImage = false
    var clipboardTask: Task<Void, Never>?
    var clipboardTicket = UUID()
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
    @Published var previewDecodeConcurrency = PreviewPreferences.defaultConcurrency {
        didSet {
            let bounded = PreviewPreferences.clampConcurrency(previewDecodeConcurrency)
            if previewDecodeConcurrency != bounded { previewDecodeConcurrency = bounded }
            previewPreferences.decodeConcurrency = previewDecodeConcurrency
            Task { [weak self] in await self?.applyDecodeConcurrency() }
        }
    }
    @Published var preferredCoordinateSystem: PhotoCoordinateSystem = .wgs84 {
        didSet { LocationPreferences(defaults: preferencesDefaults).preferredCoordinateSystem = preferredCoordinateSystem }
    }
    private let previewPreferences: PreviewPreferences
    let preferencesDefaults: UserDefaults
    @Published var showGroupOverview = false { didSet { if showGroupOverview { video.pause() } } }
    @Published var renameGroup: PhotoGroup?
    @Published var subdirectories: [URL] = []
    @Published var diskImages: [URL] = []
    @Published var mountedDiskImages: [MountedDiskImage] = []
    @Published var mountingDiskImage: URL?
    @Published var isEjectingDiskImage = false
    @Published var isReadOnlyDirectory = false
    let diskImageService: DiskImageService
    @Published var folderCacheRevision = UUID()
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
    @Published var showFocusPoints = false {
        didSet { preferencesDefaults.set(showFocusPoints, forKey: "showFocusPoints") }
    }
    weak var previewWindow: NSWindow?
    var enteredFullscreen = false
    var loadID = UUID()
    var metadataID = UUID()
    var metadataJob: MetadataReader?
    var started = false
    var selectionAnchorID: String?
    var rangeSelectionBase: Set<String>?
    let sessions: BrowserSessionRepository
    let thumbnails: ThumbnailCache
    let engine: ArchiveEngine
    private var observations: Set<AnyCancellable> = []

    init(supportDirectory: URL? = nil, thumbnails: ThumbnailCache = .shared, defaults: UserDefaults = .standard, displayCache: DisplayPhotoCache = .shared,
         folderSummaries: FolderSummaryCache = .shared, folderSizes: FolderSizeCache = .shared, monitoringEnabled: Bool = true,
         diskImageService: DiskImageService = DiskImageService()) {
        self.diskImageService = diskImageService
        self.folderSummaries = folderSummaries; self.folderSizes = folderSizes
        preferencesDefaults = defaults
        showFocusPoints = defaults.bool(forKey: "showFocusPoints")
        preferredCoordinateSystem = LocationPreferences(defaults: defaults).preferredCoordinateSystem
        previewSortField = defaults.string(forKey: "previewSortField").flatMap(PreviewSortField.init(rawValue:)) ?? .original
        previewSortDescending = defaults.bool(forKey: "previewSortDescending")
        self.monitoringEnabled = monitoringEnabled
        let playback = VideoPlayback(defaults: defaults)
        video = playback
        previewCoordinator = PreviewCoordinator(thumbnails: thumbnails, cache: displayCache, video: playback)
        captureDates = CaptureDateLoader(thumbnails: thumbnails)
        diskLimitGB = min(20, max(1, defaults.object(forKey: "thumbnailDiskLimitGB") as? Int ?? 2))
        previewPreferences = PreviewPreferences(defaults: defaults)
        previewBefore = previewPreferences.before; previewAfter = previewPreferences.after
        previewDecodeConcurrency = previewPreferences.decodeConcurrency
        thumbnailSize = BrowserPanelLayout.clamp(defaults.object(forKey: "thumbnailSize") as? Double ?? 155, to: 110...360, fallback: 155)
        let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoBrowser", isDirectory: true)
        sessions = BrowserSessionRepository(directory: support.appendingPathComponent("Sessions", isDirectory: true))
        self.thumbnails = thumbnails
        self.displayCache = displayCache
        engine = ArchiveEngine(journalDirectory: support.appendingPathComponent("Moves", isDirectory: true))
        previewCoordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        captureDates.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        playback.livePhotoEnded = { [weak self] fileID in
            guard let self, self.playbackFile?.id == fileID else { return }
            self.livePhotoMotionID = nil
        }
        Task { [weak self] in await self?.applyDecodeConcurrency() }
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
    var playbackFile: PhotoFile? {
        guard selectedFolderID == nil else { return nil }
        if let file = focusedFile, file.kind == .video { return file }
        guard let asset = focusedAsset, livePhotoMotionID == asset.id else { return nil }
        return asset.mediaFiles.first(where: \.isLivePhoto)
    }
    var focusPointFile: PhotoFile? {
        guard showFocusPoints, selectedFolderID == nil, playbackFile == nil else { return nil }
        return focusedFile
    }
    var previewRequestID: String {
        let file = focusedFile
        return "\(file?.id ?? "")|\(file?.size ?? 0)|\(file?.modified.timeIntervalSince1970 ?? 0)|\(hdrPreview)|\(preferRawPreview)|\(previewBefore)|\(previewAfter)|\(scope)|\(search)|\(selectedFolderID ?? "")|\(isFullscreenPreview)|\(previewContentRevision)|\(sortingRevision)|\(livePhotoMotionID ?? "")"
    }
    var adjacentPreviewFiles: [PhotoFile] {
        guard selectedFolderID == nil, let index = visibleIndex(of: focusedID) else { return [] }
        return PreviewPreferences.neighbors(in: visibleAssets, index: index, before: previewBefore, after: previewAfter).filter { !$0.isVideo }.map { asset in
            asset.imageFiles.first { $0.kind == (preferRawPreview ? .raw : .rendered) } ?? asset.preferred
        }
    }
    var adjacentVideoFiles: [PhotoFile] {
        guard selectedFolderID == nil, let index = visibleIndex(of: focusedID) else { return [] }
        return PreviewPreferences.neighbors(in: visibleAssets, index: index, before: previewBefore, after: previewAfter).filter(\.isVideo).map(\.preferred)
    }
    func preparePreviewCache() async {
        await applyDecodeConcurrency()
        let current = selectedFolderID == nil && !isMoving && !isLoading && playbackFile == nil ? focusedFile : nil
        let neighbors = selectedFolderID == nil && !isMoving && !isLoading && playbackFile == nil && focusedFile != nil ? adjacentPreviewFiles : []
        let videos = selectedFolderID == nil && !isMoving && !isLoading ? adjacentVideoFiles : []
        await previewCoordinator.prepare(request: previewRequestID, current: current, neighbors: neighbors, videos: videos,
                                         hdr: hdrPreview, maximum: isFullscreenPreview ? nil : 2800)
    }
    func applyDecodeConcurrency() async {
        var applied: Int
        repeat {
            applied = previewDecodeConcurrency
            await displayCache.setDecodeConcurrency(applied)
        } while applied != previewDecodeConcurrency && !Task.isCancelled
    }
    func cancelAdjacentPreviews() { previewCoordinator.cancelAdjacent() }
    var visibleAssets: [PhotoAsset] {
        if let visibleOrdering { return visibleOrdering }
        let ordered = AssetOrdering.visible(assets, groups: groups, scope: scope, search: search,
                                            field: previewSortField, descending: previewSortDescending)
        visibleOrdering = ordered; return ordered
    }
    func visibleIndex(of id: String?) -> Int? {
        guard let id else { return nil }
        if let visiblePositions { return visiblePositions[id] }
        let positions = Dictionary(visibleAssets.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
        visiblePositions = positions
        return positions[id]
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
        !isReadOnlyDirectory && !isOperatingDiskImage && !isMoving && !isReadingMetadata && !history.contains { ["prepared", "moving", "undoing", "recoveryNeeded"].contains($0.state) }
    }
    var canDeleteSelection: Bool {
        canArchive && !isLoading && !editingPath && selectedFolderID == nil
            && directory != nil && directory?.lastPathComponent.lowercased() != "_del"
            && visibleAssets.contains { selection.contains($0.id) }
    }

    func updateMetadata(_ id: String, value: PhotoMetadata?) {
        guard let value, let index = assets.firstIndex(where: { $0.id == id }) else { return }
        // Per-photo preview/inspector reads must not move the photo between arrow presses.
        // Capture dates are reordered together by the batch loader or an explicit sort change.
        var ordering = previewSortField == .captured ? visibleAssets : nil
        let position = ordering?.firstIndex { $0.id == id }
        if assets[index].metadata == nil { assets[index].metadata = value }
        else {
            // Native previews enrich display fields without changing the original burst sequence/time.
            if assets[index].metadata?.camera == nil { assets[index].metadata?.camera = value.camera }
            if assets[index].metadata?.lensModel == nil { assets[index].metadata?.lensModel = value.lensModel }
            if assets[index].metadata?.aperture == nil { assets[index].metadata?.aperture = value.aperture }
            if assets[index].metadata?.iso == nil { assets[index].metadata?.iso = value.iso }
            if assets[index].metadata?.shutter == nil { assets[index].metadata?.shutter = value.shutter }
            if assets[index].metadata?.bitRate == nil { assets[index].metadata?.bitRate = value.bitRate }
            if let location = value.location {
                if assets[index].metadata?.location == nil {
                    assets[index].metadata?.gpsLatitude = location.latitude
                    assets[index].metadata?.gpsLongitude = location.longitude
                    assets[index].metadata?.gpsMapDatum = value.gpsMapDatum
                    assets[index].metadata?.gpsMapDatumRead = value.gpsMapDatumRead
                }
                if assets[index].metadata?.gpsLatitude == location.latitude, assets[index].metadata?.gpsLongitude == location.longitude {
                    if assets[index].metadata?.gpsMapDatum == nil { assets[index].metadata?.gpsMapDatum = value.gpsMapDatum }
                    if value.gpsMapDatumRead == true { assets[index].metadata?.gpsMapDatumRead = true }
                }
                if assets[index].metadata?.gpsAltitude == nil,
                   assets[index].metadata?.gpsLatitude == location.latitude, assets[index].metadata?.gpsLongitude == location.longitude,
                   let altitude = location.altitude {
                    assets[index].metadata?.gpsAltitude = altitude
                }
            }
        }
        if let position { ordering?[position] = assets[index] }
        if let ordering { visibleOrdering = ordering }
    }

    func revealFocused() {
        if let file = focusedFile { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
    }

    func report(_ error: Error) { errorMessage = error.localizedDescription }

    func persistChanges(_ message: String) {
        do { try saveSession(); status = message } catch { report(error); status = L10n.text("操作已执行，但分组保存失败，请勿退出") }
    }

    func saveSession() throws {
        guard let directory else { return }
        try sessions.save(assets: assets, groups: groups, in: directory)
    }
}
