import Foundation
@testable import BrowserCore

private actor TaskProbe {
    var active: [BackgroundStage: Int] = [:]
    var peak: [BackgroundStage: Int] = [:]
    var calls: [BackgroundStage: Int] = [:]
    var failOnce = false
    var failed = false
    func begin(_ stage: BackgroundStage) {
        active[stage, default: 0] += 1; calls[stage, default: 0] += 1
        peak[stage] = max(peak[stage, default: 0], active[stage, default: 0])
    }
    func end(_ stage: BackgroundStage) { active[stage, default: 0] -= 1 }
    func shouldFail(_ work: BackgroundWork) -> Bool {
        if failOnce && !failed && work.stage == .ai { failed = true; return true }; return false
    }
    func enableFailure() { failOnce = true }
    func count(_ stage: BackgroundStage) -> Int { calls[stage, default: 0] }
    func maximum(_ stage: BackgroundStage) -> Int { peak[stage, default: 0] }
}

extension CatalogChecks {
    static func backgroundTaskChecks(in temp: URL) async throws {
        let root = temp.appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = temp.appendingPathComponent("tasks.sqlite")
        _ = try AICatalogRepository(databaseURL: url)
        let writer = try AICatalogWriter(url, root: root)
        var photos: [AICatalogItem] = []
        for n in 0..<12 {
            let file = root.appendingPathComponent("p\(n).JPG"); try Data("fixture".utf8).write(to: file)
            photos.append(AICatalogItem(asset: PhotoAsset(id: "p\(n)", name: "p\(n)", files: [PhotoFile(url: file, kind: .rendered, size: 7, modified: Date(timeIntervalSince1970: 1702698361.32))])))
        }
        try writer.transaction { for photo in photos { try writer.put(photo, stamp: "initial", priority: 1, analysisDate: "2026", generation: nil) } }
        let storage = try BackgroundTaskRepository(databaseURL: url), probe = TaskProbe()
        var vector = [Float](repeating: 0, count: 768); vector[0] = 1
        let data = vector.withUnsafeBytes { Data($0) }
        let execute: @Sendable (BackgroundWork) async throws -> BackgroundWorkOutput = { work in
            await probe.begin(work.stage)
            do {
                try await Task.sleep(for: .milliseconds(work.stage == .ai ? 70 : 15))
                if await probe.shouldFail(work) { throw BrowserFailure.message("mock malformed AI output") }
                let output: BackgroundWorkOutput
                switch work.stage {
                case .preview: output = BackgroundWorkOutput(preview: work.item.asset.preferred.url)
                case .vector: output = BackgroundWorkOutput(data: data)
                case .ai: output = BackgroundWorkOutput(metadata: RecognitionMetadata(title: "mock \(work.item.asset.name)", description: "mock description", sections: [], rawResponse: "", modelName: "mock-model", failure: nil))
                }
                await probe.end(work.stage); return output
            } catch { await probe.end(work.stage); throw error }
        }
        let coordinator = BackgroundTaskCoordinator(databaseURL: url, execute: execute)
        try await coordinator.start()
        var options = BackgroundTaskOptions(root: root); options.force = true
        let a = try storage.create(options, configuration: AIModelConfiguration()), b = try storage.create(options, configuration: AIModelConfiguration())
        try await coordinator.resume(a); try await coordinator.resume(b)
        try await waitTask { try storage.tasks().allSatisfy { $0.state == .completed } }
        let aiCalls = await probe.count(.ai), initialVectorCalls = await probe.count(.vector)
        let aiPeak = await probe.maximum(.ai), vectorPeak = await probe.maximum(.vector), previewPeak = await probe.maximum(.preview)
        try require(aiCalls == 12 && initialVectorCalls == 12, "Overlapping jobs share AI requests and vector work")
        try require(aiPeak <= 8 && vectorPeak <= 2 && previewPeak <= 2, "Global queues respect separate concurrency limits")
        let global = try storage.results(root: root)
        try require(global.items.count == 12 && global.items.allSatisfy { $0.ai == .succeeded && $0.vector == .succeeded }, "Both results persist and are independently observable")
        try require(try storage.results(root: root, taskID: a).items.allSatisfy { $0.item.metadata?.title.hasPrefix("mock ") == true }, "Task rows retain AI results")
        options.force = false
        let estimate = try storage.estimate(options)
        try require(estimate.photos == 12 && estimate.ai == 0 && estimate.vectors == 0, "Default planning reuses both existing result types")
        let reused = try storage.create(options, configuration: AIModelConfiguration()); try await coordinator.resume(reused)
        try await waitTask { try storage.tasks().first { $0.id == reused }?.state == .completed }
        try require(try storage.tasks().first { $0.id == reused }?.reused == 12, "All-reused job completes without decoding or paid requests")
        options.force = true; options.vector = false
        let paused = try storage.create(options, configuration: AIModelConfiguration())
        try await coordinator.resume(paused); try await coordinator.pause(paused)
        try await waitTask { try storage.tasks().first { $0.id == paused }?.state == .paused }
        let stoppedCount = await probe.count(.ai)
        try await Task.sleep(for: .milliseconds(100))
        try require(await probe.count(.ai) == stoppedCount, "Pause drains in-flight work without dispatching new requests")
        try await coordinator.resume(paused)
        try await waitTask { try storage.tasks().first { $0.id == paused }?.active ?? 0 > 0 }
        try await coordinator.cancel(paused)
        try await waitTask { try storage.tasks().first { $0.id == paused }?.active == 0 }
        try require(try storage.results(root: root).items.allSatisfy { $0.ai == .succeeded && $0.vector == .succeeded }, "Cancellation preserves previous AI and vector results")
        let interrupted = try storage.create(options, configuration: AIModelConfiguration())
        try await coordinator.resume(interrupted); try await coordinator.shutdown()
        try await waitTask { try storage.tasks().first { $0.id == interrupted }?.active == 0 }
        let resumedCoordinator = BackgroundTaskCoordinator(databaseURL: url, execute: execute)
        try await resumedCoordinator.start()
        let before = await probe.count(.ai)
        try await Task.sleep(for: .milliseconds(100))
        try require(await probe.count(.ai) == before && storage.tasks().first { $0.id == interrupted }?.state == .paused, "Restart restores checkpoints but never automatically resends AI requests")
        try await resumedCoordinator.resume(interrupted)
        try await waitTask { try storage.tasks().first { $0.id == interrupted }?.state == .completed }
        await probe.enableFailure(); options.vector = true
        let failure = try storage.create(options, configuration: AIModelConfiguration()); try await resumedCoordinator.resume(failure)
        try await waitTask { try storage.tasks().first { $0.id == failure }?.state == .errors }
        let failedRows = try storage.results(root: root, taskID: failure, failuresOnly: true)
        try require(failedRows.items.count == 1 && failedRows.items[0].ai == .failed && failedRows.items[0].vector == .succeeded, "AI failure does not prevent vectors and has a filtered error record")
        let vectorCalls = await probe.count(.vector)
        try await resumedCoordinator.resume(failure, retryFailures: true)
        try await waitTask { try storage.tasks().first { $0.id == failure }?.state == .completed }
        try require(await probe.count(.vector) == vectorCalls, "Retry only repeats failed stages")
        try await resumedCoordinator.shutdown()
        let missingRoot = temp.appendingPathComponent("unmounted")
        let w = try AICatalogWriter(url, root: missingRoot)
        let unavailable = AICatalogItem(asset: PhotoAsset(id: "offline", name: "offline", files: [PhotoFile(url: missingRoot.appendingPathComponent("offline.JPG"), kind: .rendered)]))
        try w.transaction { try w.put(unavailable, stamp: "offline", priority: 1, analysisDate: "2026", generation: nil) }
        let offline = BackgroundTaskCoordinator(databaseURL: url, execute: { _ in throw CocoaError(.fileReadNoSuchFile) })
        try await offline.start()
        let offlineID = try storage.create(BackgroundTaskOptions(root: missingRoot), configuration: AIModelConfiguration())
        try await offline.resume(offlineID)
        try await waitTask { try storage.tasks().first { $0.id == offlineID }?.state == .paused }
        try require(try storage.tasks().first { $0.id == offlineID }?.failed == 0, "Offline storage waits for reconnection instead of reporting recognition failures")
        try await offline.shutdown()
        for state in BackgroundState.allCases { try require(BackgroundVocabulary.title(state.rawValue) != state.rawValue, "Every persisted state has a dictionary entry") }
        try await filteredVectorChecks(in: temp)
        print("PASS durable background tasks: independent queues, deduplication, checkpoint/restart, pause/cancel, result reuse, AI failure isolation, retry, offline storage and dictionary codes; no model requests")
    }
    static func waitTask(_ predicate: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while try !predicate() {
            if Date() > deadline { throw BrowserFailure.message("Background task did not reach expected state") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func filteredVectorChecks(in temp: URL) async throws {
        let root = temp.appendingPathComponent("filtered-vectors"), repo = try AICatalogRepository(databaseURL: temp.appendingPathComponent("filtered.sqlite"))
        let writer = try AICatalogWriter(repo.databaseURL, root: root), db = try AICatalogDatabase(repo.databaseURL, write: true)
        var photos: [AICatalogItem] = []
        for n in 0..<8 {
            let asset = PhotoAsset(id: "filtered\(n)", name: "filtered\(n)", files: [PhotoFile(url: root.appendingPathComponent("filtered\(n).JPG"), kind: .rendered, size: 10, modified: Date(timeIntervalSince1970: 1702698361.32))])
            let metadata = RecognitionMetadata(title: n == 6 ? "target" : "other", description: "description", sections: [RecognitionSection(id: "scene_codes", name: "场景", tags: [RecognitionTag(code: n == 6 ? "scene.target" : "scene.other", name: n == 6 ? "目标" : "其他")])], rawResponse: "", modelName: nil, failure: nil)
            let item = AICatalogItem(asset: asset, metadata: metadata, state: "processing.succeeded"); photos.append(item)
            try writer.transaction { try writer.put(item, stamp: "v1", priority: 1, analysisDate: "2026", generation: nil) }
            var values = [Float](repeating: 0, count: 768); values[0] = 1; values[1] = Float(n) / 10
            try AIVisualStorage.put(db, AIVisualOutcome(item: item, data: values.withUnsafeBytes { Data($0) }, issue: nil))
        }
        var filter = AICatalogFilter(); filter.similaritySeedID = photos[0].id; filter.text = "target"; filter.tags = ["scene_codes": ["scene.target"]]
        let hits = try await repo.rankedPhotos(root: root, filter: filter)
        try require(hits.map(\.id) == [photos[6].id], "Text, labels and recognition state filter candidates before nearest-neighbor ranking")
        try require(try await repo.summary(root: root, filter: filter).total == 1, "Similarity counts use the same eligible vector candidates")
        let redecoded = try JSONDecoder().decode(AICatalogItem.self, from: JSONEncoder().encode(photos[0]))
        let oldRevision = try await repo.visualRevision(root: root)
        try require(try AIVisualStorage.vector(db, item: redecoded) != nil, "Date round-trip does not invalidate an existing vector")
        try writer.transaction { try writer.put(redecoded, stamp: "metadata-only", priority: 2, analysisDate: "2027", generation: nil) }
        try require(try AIVisualStorage.vector(db, item: redecoded) != nil, "Metadata regeneration preserves vector snapshots")
        try require(try await repo.visualRevision(root: root) != oldRevision, "Cache revision observes metadata changes")
        let legacy = Data(#"{"state":"processing.succeeded","text":"","tags":{},"descending":true}"#.utf8)
        try require(try JSONDecoder().decode(AICatalogFilter.self, from: legacy).similaritySeedID == nil, "Legacy saved filters remain readable")
    }
}
