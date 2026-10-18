import AppKit
import ImageIO
@testable import BrowserCore

struct AIGenerationChecks {
    private struct Failure: Error { let message: String }
    private static func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    private static func rejected(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw Failure(message: "Invalid input was accepted")
    }
    static let raw = "标题：飞机\n描述：飞机在蓝色天空中飞行。\n主体：飞机\n场景：天空\n环境：蓝天\n元素：飞机\n主体色：黑\n环境色：蓝\n人物：无人\n空间：室外\n景别：远景\n特征：轮廓模糊，呈深色，有尾翼"

    static func run() throws {
        let imported = try AIModelConfiguration.importCSV("\u{FEFF}id,123\r\napiKey,test-credential\r\nopenAiCompatible,\"https://example.invalid/compatible-mode/v1\"\r\ndescription,\"quoted, text\"")
        var configuration = imported.configuration
        try check(configuration.model == "qwen3.8-flash" && !configuration.enableThinking, "New/imported settings must default to non-thinking")
        let suite = "local.wxj.PhotoBrowser.AIChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try configuration.save(defaults: defaults)
        try check(try AIModelConfiguration.load(defaults: defaults) == configuration, "AI settings did not persist")
        try check(!(String(decoding: defaults.data(forKey: AIModelConfiguration.preferencesKey)!, as: UTF8.self).contains(imported.apiKey)), "Preferences leaked credential")
        for enabled in [false, true] {
            configuration.enableThinking = enabled
            let request = try AIModelClient.request(configuration: configuration, apiKey: imported.apiKey, prompt: "test", jpeg: Data([1, 2]))
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            try check(body["enable_thinking"] as? Bool == enabled && body["stream"] as? Bool == true, "API silently inherited service thinking default")
            try check(request.url?.path == "/compatible-mode/v1/chat/completions", "Invalid endpoint path")
        }
        for address in ["http://example.invalid/v1", "https://user:password@example.invalid/v1", "https://example.invalid/v1?apiKey=secret"] {
            configuration.baseURL = address; try rejected { _ = try configuration.endpoint() }
        }
        try rejected { _ = try AIModelConfiguration.importCSV("apiKey,one\napiKey,two\nopenAiCompatible,https://example.invalid/v1") }
        try rejected { _ = try AIModelClient.request(configuration: imported.configuration, apiKey: "one\ntwo", prompt: "test") }
        var stream = AIModelStream()
        _ = try stream.consume("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"private reasoning\"}}]}")
        _ = try stream.consume("data: {\"choices\":[{\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}")
        _ = try stream.consume("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":2}}")
        let completion = try stream.finish()
        try check(completion.text == "OK" && completion.promptTokens == 12, "Streaming lost usage or leaked reasoning")
        var incomplete = AIModelStream()
        _ = try incomplete.consume("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"length\"}]}")
        try rejected { _ = try incomplete.finish() }
        try rejected { _ = try RecognitionContract.analysis("标题：不完整") }
        _ = try RecognitionContract.analysis(raw)
        guard let context = CGContext(data: nil, width: 2048, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let cg = context.makeImage() else {
            throw Failure(message: "Image fixture failed")
        }
        let jpeg = try PhotoRecognitionGenerator.jpeg(NSImage(cgImage: cg, size: NSSize(width: 2048, height: 1024)))
        let source = CGImageSourceCreateWithData(jpeg.data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        try check(properties[kCGImagePropertyPixelWidth] as? Int == 720 && properties[kCGImagePropertyPixelHeight] as? Int == 360, "Uploaded JPEG does not satisfy 720 resize")
        let box = ResultBox(), done = DispatchSemaphore(value: 0)
        Task.detached { do { try await persistenceChecks(); } catch { box.error = error }; done.signal() }
        done.wait(); if let error = box.error { throw error }
        print("PASS AI generation: thinking toggle request, credential-free preferences, CSV, SSE usage/reasoning, truncation, actual JPEG 720, atomic history/source/cancellation checks")
    }
    private final class ResultBox: @unchecked Sendable { var error: Error? }
    private static func persistenceChecks() async throws {
        let manager = FileManager.default, root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("source.jpg"); try Data("source".utf8).write(to: fileURL)
        let attrs = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let file = PhotoFile(url: fileURL, kind: .rendered, size: Int64(attrs.fileSize!), modified: attrs.contentModificationDate!)
        let asset = PhotoAsset(id: "source", name: "source", files: [file])
        let store = GeneratedRecognitionStore(root: root.appendingPathComponent("results"))
        for _ in 0..<2 { _ = try await store.save(asset, analysis: RecognitionContract.analysis(raw)) }
        let location = try await store.location(asset), before = try Data(contentsOf: location)
        let record = try JSONSerialization.jsonObject(with: before) as! [String: Any]
        try check((record["analyses"] as? [[String: Any]])?.count == 2, "Regeneration discarded prior analyses")
        let result = try await store.read(asset)
        try check(result?.sections.last?.tags.count == 3, "Generated metadata was not readable")
        do { _ = try await store.save(asset, analysis: ["invalid": true]); throw Failure(message: "Invalid analysis overwrote results") }
        catch is Failure { throw Failure(message: "Invalid analysis overwrote results") } catch {}
        try check(try Data(contentsOf: location) == before, "Failed save changed last good result")
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await store.save(asset, analysis: RecognitionContract.analysis(raw)) }
        do { _ = try await cancelled.value; throw Failure(message: "Cancelled generation committed") }
        catch is CancellationError {}
        try check(try Data(contentsOf: location) == before, "Cancelled save changed result")
        try Data("changed source".utf8).write(to: fileURL)
        do { _ = try await store.save(asset, analysis: RecognitionContract.analysis(raw)); throw Failure(message: "Changed source accepted") }
        catch is Failure { throw Failure(message: "Changed source accepted") } catch {}
        try check(try Data(contentsOf: location) == before, "Stale source overwrote results")
    }
}
