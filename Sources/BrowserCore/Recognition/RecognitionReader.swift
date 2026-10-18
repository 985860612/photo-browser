import Foundation

/// Indexes only the selected folder; slow disk work runs on the actor executor, never the UI actor.
public actor RecognitionReader {
    public static let shared = RecognitionReader()
    private struct Index {
        let candidates: [String: [RecognitionCandidate]]
        let created: Date
    }
    private let localRuns: URL?
    private var localIndexes: [URL: Index] = [:]
    private var nasIndexes: [URL: Index] = [:]
    private var contexts: [URL: RecognitionContext] = [:]

    public init(localRuns: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("PhotoBrowser/RecognitionRuns", isDirectory: true)) {
        self.localRuns = localRuns
    }

    public func read(_ asset: PhotoAsset, refresh: Bool = false) async throws -> RecognitionMetadata? {
        try Task.checkCancellation()
        guard !asset.isVideo, let first = asset.imageFiles.first else { return nil }
        if let generated = try await GeneratedRecognitionStore.shared.read(asset) { return generated }
        let directory = first.url.deletingLastPathComponent().standardizedFileURL
        if refresh { localIndexes[directory] = nil; nasIndexes[directory] = nil; contexts.removeAll() }
        if let localRuns {
            if localIndexes[directory].map({ Date().timeIntervalSince($0.created) < 30 }) != true {
                let candidates = try RecognitionLocalIndex(root: localRuns).candidates(in: directory, check: Task.checkCancellation)
                localIndexes[directory] = makeIndex(candidates)
                trim(&localIndexes)
            }
            if let result = try find(asset, in: localIndexes[directory]) { return result }
        }
        if let result = try find(asset, in: nasIndexes[directory]) { return result }
        if nasIndexes[directory].map({ Date().timeIntervalSince($0.created) < 30 }) != true {
            nasIndexes[directory] = makeIndex(try nasCandidates(directory))
            trim(&nasIndexes)
        }
        return try find(asset, in: nasIndexes[directory])
    }

    private func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    private func makeIndex(_ candidates: [RecognitionCandidate]) -> Index {
        var files: [String: [RecognitionCandidate]] = [:]
        for candidate in candidates {
            for file in candidate.files { files[key(file.name), default: []].append(candidate) }
        }
        return Index(candidates: files, created: Date())
    }

    private func trim(_ indices: inout [URL: Index]) {
        if indices.count > 8, let oldest = indices.min(by: { $0.value.created < $1.value.created })?.key { indices[oldest] = nil }
    }

    private func find(_ asset: PhotoAsset, in index: Index?) throws -> RecognitionMetadata? {
        guard let index else { return nil }
        var visited: Set<URL> = [], matches: [(RecognitionCandidate, [String: Any])] = []
        for file in asset.imageFiles {
            for candidate in index.candidates[key(file.url.lastPathComponent)] ?? [] where visited.insert(candidate.record).inserted {
                try Task.checkCancellation()
                guard candidate.files.contains(where: { identity in asset.imageFiles.contains(where: identity.matches) }) else { continue }
                guard try RecognitionFiles.exists(candidate.record) else { continue }
                let data = try Data(contentsOf: candidate.record)
                guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw BrowserFailure.message(L10n.text("无法解析 AI 识别结果。"))
                }
                let identities = try JSONSerialization.data(withJSONObject: record["files"] ?? [])
                let current = try JSONDecoder().decode([RecognitionFileIdentity].self, from: identities)
                guard current.contains(where: { identity in asset.imageFiles.contains(where: identity.matches) }) else { continue }
                matches.append((candidate, record))
            }
        }
        // A newer analysis wins when multiple V2 runs refer to the same file snapshot.
        guard let chosen = matches.max(by: { timestamp($0.1) < timestamp($1.1) }) else { return nil }
        if contexts[chosen.0.context] == nil {
            if contexts.count > 8 { contexts.removeAll() }
            contexts[chosen.0.context] = try RecognitionContext(directory: chosen.0.context)
        }
        try Task.checkCancellation()
        return try contexts[chosen.0.context]!.decode(JSONSerialization.data(withJSONObject: chosen.1))
    }

    private func timestamp(_ record: [String: Any]) -> Date {
        let current = (record["processing"] as? [String: Any])?["current_analysis_id"] as? String
        let analysis = (record["analyses"] as? [[String: Any]])?.first { $0["analysis_id"] as? String == current }
        let text = analysis?["created_at"] as? String ?? record["updated_at"] as? String ?? record["created_at"] as? String ?? ""
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text) ?? .distantPast
    }

    private func nasCandidates(_ directory: URL) throws -> [RecognitionCandidate] {
        let root = directory.appendingPathComponent(".photobrowser/v2", isDirectory: true)
        guard try RecognitionFiles.isDirectory(root) else { return [] }
        let manager = FileManager.default
        let runs = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var result: [RecognitionCandidate] = []
        struct Record: Decodable { let files: [RecognitionFileIdentity] }
        for run in runs where try RecognitionFiles.isDirectory(run) {
            try Task.checkCancellation()
            let assets = run.appendingPathComponent("assets", isDirectory: true)
            guard try RecognitionFiles.isDirectory(assets) else { continue }
            // Exactly assets/<UUID-prefix>/<UUID>.json, rather than recursing over original media.
            for shard in try manager.contentsOfDirectory(at: assets, includingPropertiesForKeys: [.isDirectoryKey]) {
                try Task.checkCancellation()
                guard try RecognitionFiles.isDirectory(shard) else { continue }
                for file in try manager.contentsOfDirectory(at: shard, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                    try Task.checkCancellation()
                    let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
                    result.append(RecognitionCandidate(record: file, context: run, files: record.files))
                }
            }
        }
        return result
    }
}
