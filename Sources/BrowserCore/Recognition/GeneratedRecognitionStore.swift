import Foundation

/// Native cloud analyses have their own envelope: hosted-model weights are unavailable, so they must
/// not masquerade as the batch pipeline's stricter V2 provenance schema. V2 sources stay untouched.
public actor GeneratedRecognitionStore {
    public nonisolated static let didSave = Notification.Name("PhotoBrowser.GeneratedRecognitionSaved")
    public static let shared = GeneratedRecognitionStore()
    private let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoBrowser/GeneratedRecognition", isDirectory: true)
    }
    public func location(_ asset: PhotoAsset) throws -> URL {
        guard let source = asset.imageFiles.first else { throw RecognitionContract.invalid() }
        let parent = source.url.deletingLastPathComponent().standardizedFileURL.path
        return root.appendingPathComponent(ThumbnailCache.digest(parent)).appendingPathComponent(ThumbnailCache.digest(asset.id) + ".json")
    }
    public func read(_ asset: PhotoAsset) throws -> RecognitionMetadata? {
        let url = try location(asset)
        guard try RecognitionFiles.exists(url) else { return nil }
        let data = try Data(contentsOf: url)
        let record = try object(data)
        let files = try JSONDecoder().decode([RecognitionFileIdentity].self, from: JSONSerialization.data(withJSONObject: record["files"] ?? []))
        guard files.contains(where: { identity in asset.imageFiles.contains(where: identity.matches) }) else { return nil }
        return try RecognitionContract.context().decode(data)
    }
    public func save(_ asset: PhotoAsset, analysis: [String: Any]) throws -> RecognitionMetadata {
        try Task.checkCancellation()
        try Self.validateSource(asset)
        guard let analysisID = analysis["analysis_id"] as? String, UUID(uuidString: analysisID) != nil else { throw RecognitionContract.invalid() }
        let url = try location(asset), now = ISO8601DateFormatter().string(from: Date())
        var record: [String: Any] = ["schema_version": "photo-browser.cloud-analysis.v1", "created_at": now, "analyses": []]
        if try RecognitionFiles.exists(url) { record = try object(Data(contentsOf: url)) }
        var history = record["analyses"] as? [[String: Any]] ?? []
        history.append(analysis)
        record["analyses"] = history; record["updated_at"] = now
        record["files"] = Self.identities(asset)
        record["processing"] = ["state_code": "processing.succeeded", "current_analysis_id": analysisID]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        let result = try RecognitionContract.context().decode(data)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        NotificationCenter.default.post(name: Self.didSave, object: nil, userInfo: ["asset": asset])
        return result
    }
    private func object(_ data: Data) throws -> [String: Any] {
        guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["schema_version"] as? String == "photo-browser.cloud-analysis.v1" else { throw RecognitionContract.invalid() }
        return record
    }
    static func identities(_ asset: PhotoAsset) -> [[String: Any]] {
        asset.imageFiles.map { ["name": $0.url.lastPathComponent, "size_bytes": $0.size,
                               "mtime_ns": String(Int64($0.modified.timeIntervalSince1970 * 1_000_000_000))] }
    }
    static func validateSource(_ asset: PhotoAsset) throws {
        guard !asset.isVideo, !asset.imageFiles.isEmpty else { throw RecognitionContract.invalid() }
        for file in asset.imageFiles {
            // URL resource values may still hold the scanner's cached stat after a file changes.
            let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == file.size, let date = attributes[.modificationDate] as? Date,
                  abs(date.timeIntervalSince(file.modified)) <= 0.01 else {
                throw BrowserFailure.message(L10n.text("照片文件已变化，请刷新目录后重新生成。"))
            }
        }
    }
}
