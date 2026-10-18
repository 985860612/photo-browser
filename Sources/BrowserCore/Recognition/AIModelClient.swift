import Foundation

public struct AIModelCompletion: Sendable {
    public let text: String
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let finishReason: String
}

public enum AIModelClient {
    /// Explicit thinking in both modes: never inherit the service's default.
    public static func request(configuration: AIModelConfiguration, apiKey: String,
                               prompt: String, jpeg: Data? = nil) throws -> URLRequest {
        try AIModelKeychain.validate(apiKey)
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrowserFailure.message(L10n.text("请输入模型名称。"))
        }
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        if let jpeg { content.insert(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]], at: 0) }
        let body: [String: Any] = ["model": configuration.model, "messages": [["role": "user", "content": content]],
                                 "stream": true, "stream_options": ["include_usage": true],
                                 "enable_thinking": configuration.enableThinking, "temperature": 0,
                                 "max_tokens": configuration.enableThinking ? 4096 : 768]
        var request = URLRequest(url: try configuration.endpoint(), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public static func complete(configuration: AIModelConfiguration, apiKey: String,
                                prompt: String, jpeg: Data? = nil) async throws -> AIModelCompletion {
        let request = try request(configuration: configuration, apiKey: apiKey, prompt: prompt, jpeg: jpeg)
        let options = URLSessionConfiguration.ephemeral
        options.urlCache = nil; options.httpCookieStorage = nil; options.httpShouldSetCookies = false
        options.timeoutIntervalForRequest = 180; options.timeoutIntervalForResource = 240
        let session = URLSession(configuration: options, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw failed() }
        guard response.statusCode == 200 else {
            // Do not echo arbitrary server error bodies: they can include credentials or request payloads.
            throw BrowserFailure.message(L10n.text("AI 请求失败（HTTP \(response.statusCode)），请检查服务地址、模型和密钥。"))
        }
        var stream = AIModelStream()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if try stream.consume(line) { break }
        }
        try Task.checkCancellation()
        return try stream.finish()
    }

    public static func test(configuration: AIModelConfiguration, apiKey: String) async throws {
        _ = try await complete(configuration: configuration, apiKey: apiKey, prompt: "只回复OK")
    }
    static func failed() -> Error { BrowserFailure.message(L10n.text("AI 服务返回了无法识别的响应。")) }
}

/// Parse SSE without retaining or displaying reasoning_content.
struct AIModelStream {
    var text = "", finishReason = ""
    var promptTokens: Int?, completionTokens: Int?
    mutating func consume(_ line: String) throws -> Bool {
        guard line.hasPrefix("data:") else { return false }
        let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if value == "[DONE]" { return true }
        guard let json = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any], json["error"] == nil else {
            throw AIModelClient.failed()
        }
        if let usage = json["usage"] as? [String: Any] {
            promptTokens = usage["prompt_tokens"] as? Int; completionTokens = usage["completion_tokens"] as? Int
        }
        for choice in json["choices"] as? [[String: Any]] ?? [] {
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
            if let delta = choice["delta"] as? [String: Any], let fragment = delta["content"] as? String {
                text += fragment
                guard text.utf8.count <= 65_536 else { throw RecognitionContract.invalid() }
            }
        }
        return false
    }
    func finish() throws -> AIModelCompletion {
        guard finishReason == "stop", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrowserFailure.message(L10n.text("模型输出未完整结束，原结果已保留。"))
        }
        return AIModelCompletion(text: text, promptTokens: promptTokens, completionTokens: completionTokens, finishReason: finishReason)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
