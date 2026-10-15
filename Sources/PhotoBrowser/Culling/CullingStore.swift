import AppKit
import Combine
import BrowserCore
import CullingCore

@MainActor final class CullingStore: ObservableObject {
    enum Filter: String, CaseIterable { case all, unreviewed, keep, maybe, reject, similar, recommended, review }
    typealias Provider = @Sendable (PhotoAsset, AnalysisOptions) async throws -> PhotoAnalysis
    @Published var active = false
    @Published var filter: Filter = .all
    @Published var selectedGroupID: String?
    @Published var selectedLabel: String?
    @Published var referenceID: String?
    @Published var compare = true
    @Published var grid = false
    @Published var autoAdvance = true
    @Published var showAnalysisSheet = false
    @Published var showResultsSheet = false
    @Published var errorMessage: String?
    @Published private(set) var session = CullingSession()
    @Published var analyses: [String: PhotoAnalysis] = [:]
    @Published var similarityGroups: [SimilarityGroup] = [] {
        didSet { groupByAsset = Dictionary(similarityGroups.flatMap { group in group.assetIDs.map { ($0, group) } }, uniquingKeysWith: { first, _ in first }) }
    }
    @Published var failures: [String: String] = [:]
    @Published var running = false
    @Published var grouping = false
    @Published var restoring = false
    @Published var completed = 0
    @Published var total = 0
    @Published var undoCount = 0
    private(set) var directory: URL?
    private(set) var assets: [PhotoAsset] = []
    private(set) var assetByID: [String: PhotoAsset] = [:]
    private(set) var groupByAsset: [String: SimilarityGroup] = [:]
    private(set) var protectedIDs: Set<String> = []
    var available = false
    var analysisTask: Task<Void, Never>?
    var groupingTask: Task<Void, Never>?
    var generation = UUID()
    var groupingGeneration = UUID()
    let repository: CullingRepository
    let workers = PreviewWorkQueue(backgroundConcurrency: 1)
    let provider: Provider
    private var undoHistory: [CullingSession] = []

    init(directory: URL, thumbnails: ThumbnailCache = .shared, provider: Provider? = nil) {
        repository = CullingRepository(directory: directory)
        let analyzer = VisionPhotoAnalyzer(thumbnails: thumbnails)
        self.provider = provider ?? { try await analyzer.analyze($0, options: $1) }
    }
    func close() {
        pause(); groupingTask?.cancel(); groupingGeneration = UUID(); grouping = false
        generation = UUID(); directory = nil; available = false; restoring = false; errorMessage = nil
        assets = []; assetByID = [:]; analyses = [:]; similarityGroups = []; failures = [:]
        session = CullingSession(); undoHistory = []; undoCount = 0
        referenceID = nil; selectedGroupID = nil; selectedLabel = nil; filter = .all
        completed = 0; total = 0
    }
    func open(_ library: URL, assets: [PhotoAsset], protectedIDs: Set<String>) async {
        close()
        let ticket = generation, repository = repository
        directory = library; self.assets = assets; self.protectedIDs = protectedIDs; restoring = true
        assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        do {
            let restored = try await workers.run(background: true) { check in
                try check()
                return (try repository.loadSession(in: library), try repository.loadAnalyses(for: assets, in: library))
            }
            guard generation == ticket else { return }
            session = restored.0
            analyses = restored.1.filter { id, value in assetByID[id].map { value.isCurrent(for: $0) } ?? false }
            available = true; restoring = false
            referenceID = self.assets.first?.id
            rebuildGroups()
        } catch {
            guard generation == ticket else { return }
            restoring = false; available = false
            errorMessage = L10n.text("无法恢复选片记录：\(error.localizedDescription)")
        }
    }
    func reconcile(_ assets: [PhotoAsset], protectedIDs: Set<String>) {
        guard directory != nil else { return }
        let changed = self.assets.map { $0.id + $0.fingerprint } != assets.map { $0.id + $0.fingerprint }
        let protectionChanged = self.protectedIDs != protectedIDs
        self.assets = assets; self.protectedIDs = protectedIDs
        assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        if changed {
            // A changed directory must not accept late work from an older file snapshot.
            if !restoring { pause() }
            failures = failures.filter { id, _ in assets.contains { $0.id == id } }
            let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            analyses = analyses.filter { id, value in byID[id].map { value.isCurrent(for: $0) } ?? false }
            if !assets.contains(where: { $0.id == referenceID }) { referenceID = nil }
        }
        if available, changed || protectionChanged { rebuildGroups() }
    }
    @discardableResult func commit(_ next: CullingSession, remember: Bool = true) -> Bool {
        guard available, let directory else { return false }
        do {
            try repository.save(next, in: directory)
            if remember { undoHistory.append(session); if undoHistory.count > 100 { undoHistory.removeFirst() } }
            session = next; undoCount = undoHistory.count
            return true
        } catch { errorMessage = L10n.text("无法保存选片记录：\(error.localizedDescription)"); return false }
    }
    @discardableResult func mark(_ mark: CullingMark, assets chosen: [PhotoAsset]) -> Bool {
        let live = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.fingerprint) })
        let valid = chosen.filter { !$0.isVideo && live[$0.id] == $0.fingerprint }
        guard !valid.isEmpty else { return false }
        var next = session
        for asset in valid {
            if mark == .unreviewed { next.decisions.removeValue(forKey: asset.id) }
            else { next.decisions[asset.id] = CullingDecision(mark: mark, fingerprint: asset.fingerprint) }
        }
        return commit(next)
    }
    func undo() {
        guard var previous = undoHistory.last else { return }
        // Undo affects human choices, not the analysis configuration of a running task.
        previous.options = session.options
        if commit(previous, remember: false) {
            undoHistory.removeLast(); undoCount = undoHistory.count; rebuildGroups()
        }
    }
    func removeFromSimilarity(_ ids: Set<String>) {
        var next = session
        next.excludedFromSimilarity.formUnion(ids)
        next.manualGroups = next.manualGroups.compactMap { group in
            let remaining = group.assetIDs.filter { !ids.contains($0) }
            return remaining.count >= 2 ? SimilarityGroup(id: group.id, assetIDs: remaining) : nil
        }
        if commit(next) { selectedGroupID = nil; rebuildGroups() }
    }
    func split(_ group: SimilarityGroup, at id: String) {
        guard let index = group.assetIDs.firstIndex(of: id), index > 0 else { return }
        var next = session
        next.excludedFromSimilarity.formUnion(group.assetIDs)
        next.manualGroups.removeAll { $0.id == group.id }
        for part in [Array(group.assetIDs[..<index]), Array(group.assetIDs[index...])] where part.count >= 2 {
            next.manualGroups.append(SimilarityGroup(assetIDs: part))
        }
        if commit(next) { selectedGroupID = nil; rebuildGroups() }
    }
    func merge(_ ids: Set<String>) {
        let chosen = assets.filter { ids.contains($0.id) && !protectedIDs.contains($0.id) && !$0.isVideo }.map(\.id)
        guard chosen.count >= 2 else { return }
        var next = session
        // Remove merged photos from old manual groups without duplicating membership.
        next.manualGroups = next.manualGroups.compactMap { group in
            let remaining = group.assetIDs.filter { !ids.contains($0) }
            return remaining.count >= 2 ? SimilarityGroup(id: group.id, assetIDs: remaining) : nil
        }
        next.excludedFromSimilarity.formUnion(chosen)
        let group = SimilarityGroup(assetIDs: chosen); next.manualGroups.append(group)
        if commit(next) { selectedGroupID = group.id; filter = .similar; rebuildGroups() }
    }
}
