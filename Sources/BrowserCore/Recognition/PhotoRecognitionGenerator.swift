import AppKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

public actor PhotoRecognitionGenerator {
    public static let shared = PhotoRecognitionGenerator()

    public func generate(_ asset: PhotoAsset, configuration: AIModelConfiguration, apiKey: String, previewURL: URL? = nil, taskItemID: String? = nil, savedPrompt: String? = nil) async throws -> RecognitionMetadata {
        try Task.checkCancellation()
        if let taskItemID, let existing = try await GeneratedRecognitionStore.shared.readTask(asset, token: taskItemID) { return existing }
        try GeneratedRecognitionStore.validateSource(asset)
        let source = asset.preferred
        let previewImage: NSImage
        if let previewURL, let prepared = NSImage(contentsOf: previewURL) { previewImage = prepared }
        else { previewImage = try await ThumbnailCache.shared.image(source, maximum: 720).image }
        try Task.checkCancellation()
        let image = try Self.jpeg(previewImage)
        let prompt = try savedPrompt ?? RecognitionContract.prompt(), start = Date()
        let completion = try await AIModelClient.complete(configuration: configuration, apiKey: apiKey, prompt: prompt, jpeg: image.data)
        try Task.checkCancellation()
        var analysis = try RecognitionContract.analysis(completion.text)
        analysis["created_at"] = ISO8601DateFormatter().string(from: Date())
        analysis["model"] = ["name": configuration.model, "endpoint": try configuration.endpoint().absoluteString,
                             "enable_thinking": configuration.enableThinking]
        analysis["input"] = ["files": GeneratedRecognitionStore.identities(asset), "source_name": source.url.lastPathComponent,
                             "width_px": image.width, "height_px": image.height, "long_edge_limit_px": 720,
                             "image_sha256": SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined(), "jpeg_quality": 85,
                             "color_space": "sRGB", "exif_orientation_applied": true]
        analysis["prompt_sha256"] = ThumbnailCache.digest(prompt)
        if let taskItemID { analysis["task_item_id"] = taskItemID }
        analysis["metrics"] = ["latency_ms": Date().timeIntervalSince(start) * 1000,
                               "prompt_tokens": completion.promptTokens as Any? ?? NSNull(),
                               "completion_tokens": completion.completionTokens as Any? ?? NSNull(), "finish_reason": completion.finishReason]
        return try await GeneratedRecognitionStore.shared.save(asset, analysis: analysis)
    }

    static func jpeg(_ image: NSImage) throws -> (data: Data, width: Int, height: Int) {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw RecognitionContract.invalid() }
        let scale = min(1, 720 / Double(max(source.width, source.height)))
        let width = max(1, Int(Double(source.width) * scale)), height = max(1, Int(Double(source.height) * scale))
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw RecognitionContract.invalid() }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high; context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = NSMutableData()
        guard let cg = context.makeImage(), let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RecognitionContract.invalid()
        }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RecognitionContract.invalid() }
        return (bytes as Data, width, height)
    }
}
