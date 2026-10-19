import SwiftUI
import BrowserCore

@MainActor final class AIVisualSearchStore: ObservableObject {
    let seed: AICatalogItem
    let root: URL
    let repository: AICatalogRepository
    let exclusions: [URL]
    @Published private(set) var matches: [AIVisualMatch] = []
    @Published private(set) var progress: AIVisualIndexProgress?
    @Published private(set) var indexing = false
    @Published private(set) var searching = false
    @Published private(set) var limit = 100
    @Published var selectedID: String?
    @Published var large = false
    @Published var error: String?
    var selected: AICatalogItem? { matches.first { $0.id == selectedID }?.item }
    var canLoadMore: Bool { matches.count >= limit && limit < 500 }
    private var job: Task<Void, Never>?
    private var query: Task<Void, Never>?
    private var operation = UUID()
    private var queryID = UUID()
    private var lastSearch = Date.distantPast

    init(seed: AICatalogItem, root: URL, repository: AICatalogRepository, exclusions: [URL]) {
        self.seed = seed; self.root = root; self.repository = repository; self.exclusions = exclusions
    }
    func start(rebuild: Bool = false, retryFailures: Bool = false) {
        stop(); error = nil; indexing = true
        let id = UUID(); operation = id
        job = Task {
            do {
                if rebuild || retryFailures { try await repository.resetVisualIndex(root: root, excluding: exclusions, failuresOnly: !rebuild) }
                progress = try await repository.visualIndexStatus(root: root, excluding: exclusions)
                try await loadMatches()
                try await repository.indexVisualPhotos(root: root, excluding: exclusions) { [weak self] value in
                    await self?.received(value, operation: id)
                }
                try Task.checkCancellation(); guard operation == id else { return }
                query?.cancel()
                try await loadMatches()
            } catch is CancellationError {}
            catch { if operation == id { self.error = error.localizedDescription } }
            if operation == id { indexing = false; job = nil }
        }
    }
    func stop() {
        job?.cancel(); query?.cancel(); job = nil; query = nil
        operation = UUID(); queryID = UUID(); indexing = false; searching = false
    }
    func refresh() {
        query?.cancel()
        query = Task {
            do { try await loadMatches() }
            catch is CancellationError {}
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func loadMore() { guard canLoadMore && !searching else { return }; limit += 100; refresh() }
    private func received(_ value: AIVisualIndexProgress, operation id: UUID) {
        guard operation == id else { return }
        progress = value
        if Date().timeIntervalSince(lastSearch) >= 2, !searching { lastSearch = Date(); refresh() }
    }
    private func loadMatches() async throws {
        let id = UUID(); queryID = id; searching = true
        defer { if queryID == id { searching = false } }
        let result = try await repository.similarPhotos(to: seed, root: root, excluding: exclusions, limit: limit)
        try Task.checkCancellation(); guard queryID == id else { return }
        matches = result
        if !result.contains(where: { $0.id == selectedID }) { selectedID = result.first?.id; large = false }
    }
}
