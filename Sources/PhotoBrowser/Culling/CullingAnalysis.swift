import Foundation
import BrowserCore
import CullingCore

extension CullingStore {
    func pause() {
        analysisTask?.cancel(); analysisTask = nil; generation = UUID(); running = false
    }
    func start(assets chosen: [PhotoAsset], options: AnalysisOptions) {
        guard available, let directory, !options.isEmpty else { return }
        pause()
        let live = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.fingerprint) })
        let candidates = chosen.filter { !$0.isVideo && live[$0.id] == $0.fingerprint }
        guard !candidates.isEmpty else { return }
        var next = session; next.options = options
        guard commit(next, remember: false) else { return }
        let ticket = generation, provider = provider, repository = repository, workers = workers
        failures = [:]; total = candidates.count
        completed = candidates.filter { analyses[$0.id]?.isCurrent(for: $0, options: options) == true }.count
        let pending = candidates.filter { analyses[$0.id]?.isCurrent(for: $0, options: options) != true }
        running = !pending.isEmpty
        rebuildGroups()
        analysisTask = Task { [weak self] in
            for asset in pending {
                guard let self, !Task.isCancelled, self.generation == ticket else { return }
                do {
                    let value = try await provider(asset, options)
                    try Task.checkCancellation()
                    guard self.generation == ticket else { return }
                    guard value.isCurrent(for: asset, options: options) else {
                        throw BrowserFailure.message(L10n.text("照片分析未返回结果，请重试。"))
                    }
                    // Checkpoint each completed photo before presenting it, so pausing/relaunching resumes.
                    try await workers.run(background: true) { check in
                        try check(); try repository.save(value, in: directory)
                    }
                    guard self.generation == ticket, !Task.isCancelled else { return }
                    self.analyses[asset.id] = value
                } catch is CancellationError { return }
                catch {
                    guard self.generation == ticket, !Task.isCancelled else { return }
                    self.failures[asset.id] = error.localizedDescription
                }
                self.completed += 1
                if self.completed.isMultiple(of: 8) { self.rebuildGroups() }
                // Let foreground navigation and decode requests run between photos.
                await Task.yield()
            }
            guard let self, self.generation == ticket, !Task.isCancelled else { return }
            self.running = false; self.analysisTask = nil; self.rebuildGroups()
        }
    }
    func rebuildGroups() {
        groupingTask?.cancel()
        groupingGeneration = UUID()
        let ticket = groupingGeneration
        let session = session
        let assets = assets, analyses = analyses.filter { $0.value.signature == session.options.signature }
        let protectedIDs = protectedIDs
        grouping = true
        groupingTask = Task { [weak self, workers] in
            do {
                let groups = try await workers.run(background: true) { check in
                    try SimilarityBuilder.build(assets: assets, analyses: analyses, protectedIDs: protectedIDs,
                                                session: session, threshold: session.options.similarityThreshold, check: check)
                }
                guard let self, self.groupingGeneration == ticket, !Task.isCancelled else { return }
                self.similarityGroups = groups
                if let id = self.selectedGroupID, !groups.contains(where: { $0.id == id }) { self.selectedGroupID = nil }
                self.grouping = false
            } catch is CancellationError {}
            catch {
                guard let self, self.groupingGeneration == ticket else { return }
                self.grouping = false; self.errorMessage = L10n.text("相似分组失败：\(error.localizedDescription)")
            }
        }
    }
}
