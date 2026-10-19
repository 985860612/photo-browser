import Foundation

extension AICatalogRepository {
    /// Metadata imports are local. Only the inventory walks the selected source, two folders at a time.
    public func synchronize(root: URL, progress: @escaping @Sendable (AICatalogProgress) -> Void) async throws {
        while syncing { try await Task.sleep(for: .milliseconds(25)) }
        syncing = true
        defer { syncing = false }
        let url = databaseURL, runs = runs, generated = generated
        try await Self.background {
            let importer = try AICatalogImport(database: url, root: root, generated: generated, report: progress)
            try importer.local(runs)
        }
        let writer = try AICatalogWriter(url, root: root), generation = UUID().uuidString
        try writer.db.execute("UPDATE scope SET complete=0 WHERE id=?", [.text(writer.scope)])
        var pending = [root], scanned = 0, issues: [String] = []
        while !pending.isEmpty {
            try Task.checkCancellation()
            let batch = Array(pending.prefix(2)); pending.removeFirst(batch.count)
            let results = await withTaskGroup(of: AIDirectoryResult.self) { group in
                for directory in batch { group.addTask { await Self.scan(directory, root: root, database: url) } }
                var values: [AIDirectoryResult] = []
                for await value in group { values.append(value) }
                return values
            }
            for result in results {
                pending += result.children
                if let issue = result.issue { issues.append(issue) }
                // One directory per transaction, avoiding an I/O wait while holding the write lock.
                let importer = try AICatalogImport(database: url, root: root, generated: generated, report: progress)
                try importer.inventory(result.assets, directory: result.directory, generation: generation)
                scanned += result.assets.count
                progress(AICatalogProgress(imported: 0, scanned: scanned, complete: false, issue: issues.last))
            }
            await Task.yield()
        }
        try writer.transaction {
            if issues.isEmpty { try writer.db.execute("DELETE FROM member WHERE scope_id=? AND generation<>?", [.text(writer.scope), .text(generation)]) }
            try writer.db.execute("UPDATE scope SET complete=?,updated=? WHERE id=?", [.integer(issues.isEmpty ? 1 : 0), .real(Date().timeIntervalSince1970), .text(writer.scope)])
        }
        progress(AICatalogProgress(imported: 0, scanned: scanned, complete: issues.isEmpty, issue: issues.isEmpty ? nil : issues.joined(separator: "\n")))
        if !issues.isEmpty { throw BrowserFailure.message(issues.joined(separator: "\n")) }
    }

    private nonisolated static func scan(_ directory: URL, root: URL, database: URL) async -> AIDirectoryResult {
        do {
            return try await background {
                let fm = FileManager.default
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
                let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]).filter {
                    let values = try $0.resourceValues(forKeys: keys)
                    return values.isDirectory == true && values.isSymbolicLink != true && AICatalogPaths.allowed($0, root: root)
                }
                return AIDirectoryResult(directory: directory, assets: try DirectoryScanner.scan(directory, knownAssets: AICatalogKnownAssets.read(database, directory: directory)).filter { !$0.isVideo && !$0.imageFiles.isEmpty }, children: children, issue: nil)
            }
        } catch { return AIDirectoryResult(directory: directory, assets: [], children: [], issue: directory.path + ": " + error.localizedDescription) }
    }
}

private struct AIDirectoryResult: Sendable { let directory: URL; let assets: [PhotoAsset]; let children: [URL]; let issue: String? }

final class AICatalogImport {
    let writer: AICatalogWriter
    let generated: URL
    let report: @Sendable (AICatalogProgress) -> Void
    var contexts: [URL: RecognitionContext] = [:]
    let dateFormatter = ISO8601DateFormatter()
    let localDateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return formatter
    }()
    init(database: URL, root: URL, generated: URL, report: @escaping @Sendable (AICatalogProgress) -> Void) throws {
        writer = try AICatalogWriter(database, root: root); self.generated = generated; self.report = report
    }
    func local(_ runs: URL) throws {
        guard try RecognitionFiles.isDirectory(runs) else { return }
        var imported = 0
        for stage in try FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let manifest = stage.appendingPathComponent("manifest.json"), queue = stage.appendingPathComponent("queue.sqlite")
            guard try RecognitionFiles.exists(manifest), try RecognitionFiles.exists(queue) else { continue }
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
            guard object?["schema_version"] as? String == "2.0.0", let source = object?["source_root"] as? String else { continue }
            let base = URL(fileURLWithPath: source, isDirectory: true).aiStandardized
            guard AICatalogPaths.contains(base, in: writer.root) || AICatalogPaths.contains(writer.root, in: base) else { continue }
            let db = try AICatalogDatabase(queue)
            let rows = try db.rows("SELECT payload,record_path,asset_id FROM assets WHERE state IN ('succeeded','failed')")
            for start in stride(from: 0, to: rows.count, by: 256) {
                try writer.transaction {
                    for row in rows[start..<min(start + 256, rows.count)] {
                        try Task.checkCancellation()
                        let payload = try JSONSerialization.jsonObject(with: Data(row[0].string.utf8)) as? [String: Any] ?? [:]
                        let directory = base.appendingPathComponent(payload["directory"] as? String ?? ".", isDirectory: true).aiStandardized
                        guard AICatalogPaths.allowed(directory, root: writer.root) else { continue }
                        let record = URL(fileURLWithPath: row[1].string).aiStandardized
                        guard AICatalogPaths.contains(record, in: stage.appendingPathComponent("mirror")) else { throw RecognitionContract.invalid() }
                        let preview = stage.appendingPathComponent("previews/" + row[2].string + ".jpg")
                        try autoreleasepool { try ingest(record, directory: directory, context: stage.appendingPathComponent("format"), preview: preview, priority: 20, fileHints: payload["files"] as? [[String: Any]] ?? [], assetStem: payload["stem"] as? String) }
                        imported += 1
                    }
                }
                report(AICatalogProgress(imported: imported, scanned: 0, complete: false, issue: nil))
            }
        }
    }
    func inventory(_ assets: [PhotoAsset], directory: URL, generation: String) throws {
        var needsNAS = assets.isEmpty
        try writer.transaction {
            for asset in assets {
                let cached = try writer.inventory(asset, generation: generation)
                if !cached { needsNAS = true }
                let folder = generated.appendingPathComponent(ThumbnailCache.digest(asset.preferred.url.deletingLastPathComponent().aiStandardized.path))
                let record = folder.appendingPathComponent(ThumbnailCache.digest(asset.id) + ".json")
                if try RecognitionFiles.exists(record) {
                    try ingest(record, directory: asset.preferred.url.deletingLastPathComponent(), context: nil, preview: nil, priority: 30, actual: asset)
                }
            }
        }
        guard needsNAS else { return }
        let root = directory.appendingPathComponent(".photobrowser/v2")
        guard try RecognitionFiles.isDirectory(root) else { return }
        for run in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let records = run.appendingPathComponent("assets")
            guard try RecognitionFiles.isDirectory(records) else { continue }
            for shard in try FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil) where try RecognitionFiles.isDirectory(shard) {
                let files = try FileManager.default.contentsOfDirectory(at: shard, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
                try writer.transaction {
                    for file in files {
                        try ingest(file, directory: directory, context: run, preview: nil, priority: 10, candidates: assets)
                    }
                }
            }
        }
        // NAS metadata may identify photos whose filenames have no recognizable extension.
        // Validate those hints against the actual directory entries before keeping membership.
        let refreshed = try DirectoryScanner.scan(directory, knownAssets: AICatalogKnownAssets.read(writer.dbURL, directory: directory))
        try writer.transaction {
            for asset in refreshed where !asset.isVideo { _ = try writer.inventory(asset, generation: generation) }
        }
    }
    func ingest(_ record: URL, directory: URL, context: URL?, preview: URL?, priority: Int,
                actual: PhotoAsset? = nil, candidates: [PhotoAsset]? = nil, fileHints: [[String: Any]] = [], assetStem: String? = nil) throws {
        let stamp = "catalog-parser-v2|" + (try Self.stamp(record)) + (try context.map { try Self.stamp($0.appendingPathComponent("dictionary.json")) + Self.stamp($0.appendingPathComponent("text-format.json")) } ?? "bundled-v2")
        if let source = try writer.db.rows("SELECT s.photo_id,p.date,p.priority FROM source s JOIN photo p ON p.id=s.photo_id WHERE s.path=? AND s.stamp=?", [.text(record.path), .text(stamp)]).first, source[2].int > 0 {
            try writer.member(source[0].int, date: source[1].double, generation: nil); return
        }
        let data = try Data(contentsOf: record)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RecognitionContract.invalid() }
        let identities = try JSONDecoder().decode([RecognitionFileIdentity].self, from: JSONSerialization.data(withJSONObject: object["files"] ?? []))
        let recordedFiles = object["files"] as? [[String: Any]] ?? []
        let files = identities.compactMap { identity -> PhotoFile? in
            let url = directory.appendingPathComponent(identity.name, isDirectory: false).aiStandardized
            guard url.deletingLastPathComponent() == directory.aiStandardized else { return nil }
            let ext = url.pathExtension.lowercased(), kind: PhotoKind
            guard !["psd", "psb"].contains(ext), !DirectoryScanner.videoExtensions.contains(ext) else { return nil }
            let hint = fileHints.first { $0["name"] as? String == identity.name }
            let role = recordedFiles.first { $0["name"] as? String == identity.name }?["role_code"] as? String
            if DirectoryScanner.rawExtensions.contains(ext) { kind = .raw }
            else if DirectoryScanner.renderedExtensions.contains(ext) { kind = .rendered }
            else if ext == "xmp" { kind = .sidecar }
            else if let role, role.hasPrefix("file."), let parsed = PhotoKind(rawValue: String(role.dropFirst(5))), parsed != .video { kind = parsed }
            else { return nil }
            let formatHint = DirectoryScanner.rawExtensions.union(DirectoryScanner.renderedExtensions).contains(ext) || ext == "xmp" ? nil : (hint?["format"] as? String ?? "")
            return PhotoFile(url: url, kind: kind, size: identity.size_bytes ?? 0, modified: Date(timeIntervalSince1970: (Double(identity.mtime_ns ?? "0") ?? 0) / 1_000_000_000), formatHint: formatHint)
        }
        guard let image = files.first(where: { $0.kind != .sidecar }) else { return }
        let ext = image.url.pathExtension.lowercased()
        let hasExtension = DirectoryScanner.rawExtensions.union(DirectoryScanner.renderedExtensions).contains(ext)
        let stem = hasExtension ? image.url.deletingPathExtension().lastPathComponent : image.url.lastPathComponent
        var asset = actual ?? candidates?.first { $0.id == stem.lowercased() } ?? PhotoAsset(id: assetStem ?? stem.lowercased(), name: stem, files: files)
        if actual != nil || candidates != nil {
            guard !asset.imageFiles.isEmpty, asset.imageFiles.allSatisfy({ file in identities.contains(where: { $0.matches(file) }) }) else { return }
        }
        if let facts = object["facts"] as? [String: Any] {
            var metadata = PhotoMetadata()
            if let exif = facts["exif"] as? [String: Any] {
                let text = exif["captured_local"] as? String ?? ""
                if let offset = exif["utc_offset"] as? String, !offset.isEmpty { metadata.captured = dateFormatter.date(from: text + offset) }
                else { metadata.captured = localDateFormatter.date(from: text) }
                metadata.camera = exif["camera"] as? String; metadata.lensModel = exif["lens"] as? String
                metadata.aperture = exif["aperture"] as? Double; metadata.iso = exif["iso"] as? Int
                metadata.focalLength = exif["focal_length_mm"] as? Double
            }
            metadata.width = facts["display_width_px"] as? Int; metadata.height = facts["display_height_px"] as? Int
            asset.metadata = metadata
        }
        let decoder: RecognitionContext
        if let context {
            if contexts[context] == nil { contexts[context] = try RecognitionContext(directory: context) }
            decoder = contexts[context]!
        } else { decoder = try RecognitionContract.context() }
        let metadata: RecognitionMetadata?, issue: String?
        do { metadata = try decoder.decode(data); issue = metadata?.failure }
        catch { metadata = nil; issue = error.localizedDescription }
        let processing = object["processing"] as? [String: Any] ?? [:]
        let current = processing["current_analysis_id"] as? String
        let analysis = (object["analyses"] as? [[String: Any]])?.first { $0["analysis_id"] as? String == current }
        let date = analysis?["created_at"] as? String ?? object["updated_at"] as? String ?? ""
        let item = AICatalogItem(asset: asset, metadata: metadata, preview: preview, state: issue == nil ? "processing.succeeded" : "processing.failed", issue: issue)
        try writer.put(item, stamp: stamp, priority: priority, analysisDate: date, generation: nil)
        try writer.db.execute("INSERT INTO source(path,stamp,photo_id) SELECT ?,?,id FROM photo WHERE key=? ON CONFLICT(path) DO UPDATE SET stamp=excluded.stamp,photo_id=excluded.photo_id", [.text(record.path), .text(stamp), .text(item.id)])
    }
    static func stamp(_ file: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return file.path + ":" + String((attributes[.size] as? NSNumber)?.int64Value ?? 0) + ":" + String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }
}
