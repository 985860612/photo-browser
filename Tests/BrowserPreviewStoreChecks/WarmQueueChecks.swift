import AppKit
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func warmQueueChecks() async throws {
        let files = (0..<4500).map {
            PhotoFile(url: URL(fileURLWithPath: "/warm-queue-fixture/\($0).jpg"), kind: .rendered)
        }
        let queue = ThumbnailWarmQueue(files: files, priority: [files[4499], files[4499]])
        let first = await queue.next(), normal = await queue.next()
        try expect(first == files[4499] && normal == files[0], "priority requests are deduplicated while normal warming preserves source order")
        await queue.prioritize([files[4499], files[4000], files[4001]], revision: 1)
        let next = await queue.next()
        try expect(next == files[4000], "consumed priorities are skipped without rebuilding the ordinary queue")
        await queue.prioritize([files[3000]], revision: 3)
        await queue.prioritize([files[2000]], revision: 2)
        let latest = await queue.next(), fallback = await queue.next()
        try expect(latest == files[3000] && fallback == files[1], "late older priority results cannot overwrite newer requests")
        var drained: [PhotoFile] = [first!, normal!, next!, latest!, fallback!]
        while let file = await queue.next() { drained.append(file) }
        try expect(drained.count == files.count && Set(drained) == Set(files), "every photo is warmed exactly once across priority replacements")

        let duplicates = ThumbnailWarmQueue(files: [files[0], files[1], files[0]], priority: [files[0]])
        var repeated: [PhotoFile] = []
        while let file = await duplicates.next() { repeated.append(file) }
        try expect(repeated == [files[0], files[0], files[1]], "repeated source entries retain their original request count")
        let cancellation = ThumbnailWarmQueue(files: [files[0]], priority: [])
        let cancelled = Task { () -> PhotoFile? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await cancellation.next()
        }
        let discarded = await cancelled.value, retained = await cancellation.next()
        try expect(discarded == nil && retained == files[0], "cancelled dequeue does not steal a request from the batch")
        let reversed = files.prefix(100).reversed().map { PhotoAsset(id: $0.id, name: $0.id, files: [$0]) }
        let ranged = ThumbnailWarmQueue(files: Array(files.prefix(100)), priority: [])
        await ranged.prioritize(around: 20, in: reversed, revision: 1)
        let rangedFirst = await ranged.next()
        try expect(rangedFirst == reversed[16].preferred, "nearby warming follows the displayed order rather than the source order")
        try await coalescedPriorityChecks()
    }

    @MainActor static func coalescedPriorityChecks() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("WarmBatch-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "WarmBatch-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let workers = PreviewWorkQueue(), thumbnails = ThumbnailCache(directory: root.appendingPathComponent("cache"), workers: workers)
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"), thumbnails: thumbnails, defaults: defaults, monitoringEnabled: false)
        let assets = (0..<600).map { index in
            PhotoAsset(id: "asset-\(index)", name: "asset-\(index)", files: [
                PhotoFile(url: root.appendingPathComponent(String(format: "missing-%04d.jpg", index)), kind: .rendered)
            ])
        }
        store.assets = assets
        let started = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let blocker = Task { try await workers.run(background: true) { _ in
            started.signal()
            guard gate.wait(timeout: .now() + 8) == .success else { throw BrowserFailure.message("priority batching gate timed out") }
        } }
        defer { gate.signal(); store.cancelPreviewGeneration() }
        let began = await Task.detached { waitForStart(started) }.value
        try expect(began, "batching fixture blocks background decoding")
        store.previewCoordinator.start(files: assets.map(\.preferred), priority: [])
        try await Task.sleep(for: .milliseconds(30))
        for asset in assets[200..<240] { store.previewAppeared(asset) }
        store.previewAppeared(assets[550])
        try await Task.sleep(for: .milliseconds(200))
        gate.signal(); try await blocker.value
        try await until { !store.isGeneratingPreviews }
        try expect(store.previewCompleted == assets.count && store.previewFailures == assets.count,
                   "coalesced priorities retain complete and accurate progress")
        try expect(store.previewFailureDetails.contains("missing-0546.jpg") && !store.previewFailureDetails.contains("missing-0196.jpg"),
                   "rapid card appearances warm the latest neighborhood before the untouched library")

        store.previewCoordinator.start(files: assets.map(\.preferred), priority: [])
        store.previewAppeared(assets[550])
        store.previewCoordinator.cancel()
        store.previewCoordinator.start(files: [assets[0].preferred], priority: [])
        try await until { !store.isGeneratingPreviews }
        try await Task.sleep(for: .milliseconds(150))
        try expect(store.previewTotal == 1 && store.previewCompleted == 1 && store.previewFailures == 1,
                   "pending scrolling priorities are cancelled when the directory batch changes")
    }
}
