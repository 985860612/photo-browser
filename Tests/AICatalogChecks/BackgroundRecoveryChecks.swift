import Foundation
@testable import BrowserCore

private actor RetryProbe {
    var attempts = 0
    func next() -> Int { attempts += 1; return attempts }
}
extension CatalogChecks {
    static func backgroundRecoveryChecks(in temp: URL) async throws {
        let retry = RetryProbe()
        let answer: Int = try await BackgroundWorker.retry {
            let attempt = await retry.next()
            if attempt < 3 { throw AIModelHTTPError(status: 429, retryAfter: 0) }
            return 42
        }
        let attempts = await retry.attempts
        try require(answer == 42 && attempts == 3, "Rate-limited requests retry twice and obey Retry-After")
        let malformed = RetryProbe()
        do {
            _ = try await BackgroundWorker.retry {
                _ = await malformed.next()
                throw RecognitionContract.invalid()
            } as Int
            throw BrowserFailure.message("Malformed response accepted")
        } catch {}
        try require(await malformed.attempts == 1, "Malformed model output is not automatically resent")
        try require(AIModelClient.retryDelay("15") == 15 && AIModelClient.retryDelay("Wed, 21 Oct 2015 07:28:00 GMT") == 0, "Retry-After supports seconds and HTTP dates")

        let root = temp.appendingPathComponent("auth", isDirectory: true), url = temp.appendingPathComponent("auth.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try AICatalogRepository(databaseURL: url)
        let writer = try AICatalogWriter(url, root: root)
        for n in 0..<4 {
            let file = root.appendingPathComponent("auth\(n).JPG"); try Data("test".utf8).write(to: file)
            let item = AICatalogItem(asset: PhotoAsset(id: "auth\(n)", name: "auth\(n)", files: [PhotoFile(url: file, kind: .rendered, size: 4)]))
            try writer.transaction { try writer.put(item, stamp: "v1", priority: 1, analysisDate: "2026", generation: nil) }
        }
        let storage = try BackgroundTaskRepository(databaseURL: url)
        let coordinator = BackgroundTaskCoordinator(databaseURL: url) { work in
            switch work.stage {
            case .preview: return BackgroundWorkOutput(preview: work.item.asset.preferred.url)
            case .ai: throw AIModelHTTPError(status: 401, retryAfter: nil)
            case .vector:
                var vector = [Float](repeating: 0, count: 768); vector[0] = 1
                return BackgroundWorkOutput(data: vector.withUnsafeBytes { Data($0) })
            }
        }
        try await coordinator.start(aiConcurrency: 1)
        let id = try storage.create(BackgroundTaskOptions(root: root), configuration: AIModelConfiguration())
        try await coordinator.resume(id)
        try await waitTask { try storage.tasks().first { $0.id == id }?.state == .paused }
        let results = try storage.results(root: root, taskID: id)
        try require(results.items.allSatisfy { $0.vector == .succeeded && $0.ai == .pending }, "An authentication error pauses AI while local vectors finish")
        try require(try storage.tasks().first { $0.id == id }?.issue != nil, "Authentication pause exposes a reason")
        try await coordinator.cancel(id)
        try await coordinator.shutdown()
        let damaged = BackgroundTaskCoordinator(databaseURL: url) { _ in throw BrowserFailure.message("Cannot decode local thumbnail") }
        try await damaged.start()
        var options = BackgroundTaskOptions(root: root); options.force = true
        let damagedID = try storage.create(options, configuration: AIModelConfiguration())
        try await damaged.resume(damagedID)
        try await waitTask { try storage.tasks().first { $0.id == damagedID }?.state == .errors }
        let blocked = try storage.results(root: root, taskID: damagedID, failuresOnly: true)
        try require(blocked.items.count == 4 && blocked.items.allSatisfy { $0.ai == .blocked && $0.vector == .blocked && $0.preview == .failed }, "A thumbnail error is separate from AI and vector recognition failures")
        try await damaged.shutdown()
        print("PASS background recovery: Retry-After, malformed-output policy, authentication pause with continued vectors and separate thumbnail errors")
    }
}
