import Foundation
import SQLite3

struct RecognitionFileIdentity: Codable, Sendable {
    let name: String
    let size_bytes: Int64?
    let mtime_ns: String?

    func matches(_ file: PhotoFile) -> Bool {
        guard name.precomposedStringWithCanonicalMapping.lowercased() == file.url.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() else { return false }
        if let size_bytes, size_bytes != file.size { return false }
        if let mtime_ns, let nanos = Double(mtime_ns), abs(nanos / 1_000_000_000 - file.modified.timeIntervalSince1970) > 0.01 { return false }
        return true
    }
}

struct RecognitionCandidate: Codable, Sendable {
    let record: URL
    let context: URL
    let files: [RecognitionFileIdentity]
}

/// Local staging queues are read-only; the inspector never needs the development web server.
struct RecognitionLocalIndex {
    let root: URL

    func candidates(in directory: URL, check: () throws -> Void) throws -> [RecognitionCandidate] {
        guard try RecognitionFiles.isDirectory(root) else { return [] }
        let stages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var result: [RecognitionCandidate] = []
        for stage in stages.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            try check()
            guard try RecognitionFiles.isDirectory(stage) else { continue }
            let manifestURL = stage.appendingPathComponent("manifest.json")
            guard try RecognitionFiles.exists(manifestURL) else { continue }
            guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
                  manifest["schema_version"] as? String == "2.0.0", let source = manifest["source_root"] as? String else { continue }
            let sourceRoot = URL(fileURLWithPath: source).standardizedFileURL
            let folder = directory.standardizedFileURL
            guard folder.path == sourceRoot.path || folder.path.hasPrefix(sourceRoot.path + "/") else { continue }
            let relative = folder.path == sourceRoot.path ? "." : String(folder.path.dropFirst(sourceRoot.path.count + 1))
            result += try query(stage: stage, directory: relative, check: check)
        }
        return result
    }

    private func query(stage: URL, directory: String, check: () throws -> Void) throws -> [RecognitionCandidate] {
        let database = stage.appendingPathComponent("queue.sqlite")
        guard try RecognitionFiles.exists(database) else { return [] }
        var db: OpaquePointer?
        let status = sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let db { sqlite3_close(db) } }
        guard status == SQLITE_OK, let db else { throw failure(db) }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        let sql = "SELECT payload,record_path FROM assets WHERE json_extract(payload,'$.directory')=? AND state IN ('succeeded','failed') ORDER BY asset_key"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure(db) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, directory, -1, transient) == SQLITE_OK else { throw failure(db) }
        struct Asset: Decodable { let files: [RecognitionFileIdentity] }
        var result: [RecognitionCandidate] = []
        while true {
            try check()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure(db) }
            guard let payload = sqlite3_column_text(statement, 0), let path = sqlite3_column_text(statement, 1) else { continue }
            let record = URL(fileURLWithPath: String(cString: path)).standardizedFileURL
            guard record.path.hasPrefix(stage.standardizedFileURL.path + "/mirror/") else {
                throw BrowserFailure.message(L10n.text("AI 元数据索引包含无效路径。"))
            }
            let asset = try JSONDecoder().decode(Asset.self, from: Data(String(cString: payload).utf8))
            result.append(RecognitionCandidate(record: record, context: stage.appendingPathComponent("format"), files: asset.files))
        }
        return result
    }

    private func failure(_ db: OpaquePointer?) -> Error {
        let details = db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed"
        return BrowserFailure.message(L10n.text("读取 AI 本地索引失败：\(details)"))
    }
}

/// Only a genuinely absent optional metadata path is a cache miss; permission/I/O errors surface.
enum RecognitionFiles {
    static func exists(_ url: URL) throws -> Bool {
        do { _ = try url.resourceValues(forKeys: [.isDirectoryKey]); return true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return false }
    }
    static func isDirectory(_ url: URL) throws -> Bool {
        do { return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return false }
    }
}
