import Foundation
import BrowserCore
import SQLite3

struct RecognitionChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    private static func bytes(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private static let wire: [String: Any] = ["missing": "-", "fields": [
        ["name": "标题", "output_field": "title"], ["name": "描述", "output_field": "description"],
        ["name": "元素", "output_field": "element_codes", "dictionary": "element", "multiple": true],
        ["name": "环境", "output_field": "environment_codes", "dictionary": "environment", "multiple": true],
        ["name": "特征", "output_field": "visual_codes", "dictionary": "visual", "multiple": true],
        ["name": "空间", "output_field": "space_code", "dictionary": "space"]
    ]]
    private static let dictionary: [String: Any] = ["dictionaries": [
        "element": [["code": "element.aircraft", "name": "飞机"], ["code": "element.tree", "name": "树木"]],
        "environment": [], "visual": [], "space": [["code": "space.outdoor", "name": "室外"]]
    ]]

    static func run() throws {
        try require(RecognitionLabels.split("轮廓模糊，呈深色，有尾翼") == ["轮廓模糊", "呈深色", "有尾翼"], "Chinese commas were not split")
        try require(RecognitionLabels.split("天空｜水面、绿叶,白花;黑影；灰墙\n天空|-|") == ["天空", "水面", "绿叶", "白花", "黑影", "灰墙"], "Mixed separators/missing values/dedup failed")
        try require(RecognitionLabels.split("标识（红，蓝）|\"white, blue\"|绿色") == ["标识（红，蓝）", "white, blue", "绿色"], "Bracketed or quoted label was split")
        try require(RecognitionLabels.split("[\"飞机\",\"树木\"]") == ["飞机", "树木"], "JSON array string was not handled")
        try require(RecognitionContext.termCode(dictionary: "scene", name: "天空") == "scene.term.6c8c7a77cdfd4fd3e8d872de821ed94b78d8a967978cb3b460f06602c6e5ee67", "Canonical code differs from published Python golden value")
        let context = try RecognitionContext(protocolData: bytes(wire), dictionaryData: bytes(dictionary))
        var record = fixture()
        let decoded = try context.decode(bytes(record))
        try require(decoded.title == "飞机，天空" && decoded.description == "天空呈淡蓝色，无云层或地物。", "Prose was split or changed")
        try require(decoded.sections.first { $0.id == "visual_codes" }?.tags.map(\.name) == ["轮廓模糊", "呈深色", "有尾翼"], "Combined observed term was not normalized")
        try require(decoded.sections.first { $0.id == "space_code" }?.tags.first?.code == "space.outdoor", "Finite dictionary code was lost")
        let original = (record["analyses"] as! [[String: Any]])[0]["raw_response"] as! String
        try require(decoded.rawResponse == original, "Original output was rewritten")
        var analysis = (record["analyses"] as! [[String: Any]])[0]
        analysis["output"] = ["title": "string lists", "description": "保留，整句。", "element_codes": "element.aircraft|element.tree", "space_code": "室外"]
        record["analyses"] = [analysis]
        try require(try context.decode(bytes(record)).sections.first?.tags.map(\.name) == ["飞机", "树木"], "Delimited code string did not resolve through dictionary")
        analysis["output"] = nil
        analysis["raw_response"] = "```\n标题: 兼容文本\n描述：19:57 的天空，色彩渐变。\n元素：飞机、树木\n环境：天空呈淡蓝色，无云层或地物\n特征：轮廓模糊;呈深色；有尾翼\n空间：室外\n```"
        record["analyses"] = [analysis]
        let text = try context.decode(bytes(record))
        try require(text.title == "兼容文本" && text.description == "19:57 的天空，色彩渐变。", "Labeled text parsing corrupted prose/colons")
        try require(text.sections.first?.tags.count == 2, "Bare labels were not split")
        record = fixture()
        var stale = (record["analyses"] as! [[String: Any]])[0]
        stale["analysis_id"] = "stale"; stale["output"] = ["title": "wrong"]
        record["analyses"] = [analysisForFixture(), stale]
        try require(try context.decode(bytes(record)).title == "飞机，天空", "Decoder used last analysis instead of current_analysis_id")
        record["processing"] = ["state_code": "processing.succeeded", "current_analysis_id": "missing"]
        do { _ = try context.decode(bytes(record)); throw Failure(description: "Missing current ID silently used a stale analysis") }
        catch is Failure { throw Failure(description: "Missing current ID silently used a stale analysis") } catch {}
        record["processing"] = ["state_code": "processing.failed", "last_error": ["message": "source is all zeros"]]
        try require(try context.decode(bytes(record)).failure == "source is all zeros", "A failed record was presented as valid AI tags")
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        Task.detached {
            do { try await readerChecks(); result.error = nil } catch { result.error = error }
            done.signal()
        }
        done.wait()
        if let error = result.error { throw error }
        print("PASS AI metadata: separator/prose/code compatibility, current analyses, failure states, local/NAS association, readonly index, refresh, cancellation")
    }

    private static func analysisForFixture() -> [String: Any] {
        ["analysis_id": "current", "created_at": "2026-10-19T00:00:00+08:00", "model": ["name": "test-model"],
         "observed_terms": [["dictionary": "visual", "code": "visual.combined", "name": "轮廓模糊，呈深色，有尾翼"]],
         "output": ["title": "飞机，天空", "description": "天空呈淡蓝色，无云层或地物。", "element_codes": ["element.aircraft"],
                    "visual_codes": ["visual.combined"], "space_code": "space.outdoor"],
         "raw_response": "标题：飞机，天空\n描述：天空呈淡蓝色，无云层或地物。\n元素：飞机\n特征：轮廓模糊，呈深色，有尾翼\n空间：室外"]
    }

    private static func fixture() -> [String: Any] {
        ["processing": ["state_code": "processing.succeeded", "current_analysis_id": "current"], "analyses": [analysisForFixture()]]
    }

    private final class ResultBox: @unchecked Sendable { var error: Error? }

    private static func writeContext(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes(wire).write(to: folder.appendingPathComponent("text-format.json"))
        try bytes(dictionary).write(to: folder.appendingPathComponent("dictionary.json"))
    }

    private static func readerChecks() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("RecognitionChecks-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let photos = root.appendingPathComponent("photos/trip")
        try manager.createDirectory(at: photos, withIntermediateDirectories: true)
        let image = photos.appendingPathComponent("SAME.JPG")
        try Data("original".utf8).write(to: image)
        let attrs = try image.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let file = PhotoFile(url: image, kind: .rendered, size: Int64(attrs.fileSize!), modified: attrs.contentModificationDate!)
        let asset = PhotoAsset(id: "same", name: "SAME", files: [file])
        var record = fixture()
        let files: [[String: Any]] = [["name": "SAME.JPG", "size_bytes": file.size, "mtime_ns": String(Int64(file.modified.timeIntervalSince1970 * 1_000_000_000))]]
        record["files"] = files
        let stage = root.appendingPathComponent("runs/run")
        try writeContext(stage.appendingPathComponent("format"))
        try bytes(["schema_version": "2.0.0", "source_root": root.appendingPathComponent("photos").path]).write(to: stage.appendingPathComponent("manifest.json"))
        let stored = stage.appendingPathComponent("mirror/trip/.photobrowser/v2/run/assets/00/photo.json")
        try manager.createDirectory(at: stored.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes(record).write(to: stored)
        let dbURL = stage.appendingPathComponent("queue.sqlite")
        var db: OpaquePointer?; sqlite3_open(dbURL.path, &db)
        defer { if let db { sqlite3_close(db) } }
        try sql(db, "CREATE TABLE assets(asset_key TEXT,payload TEXT,record_path TEXT,state TEXT)")
        let payload = String(data: try bytes(["directory": "trip", "files": files]), encoding: .utf8)!
        try sql(db, "INSERT INTO assets VALUES('same','\(payload.replacingOccurrences(of: "'", with: "''"))','\(stored.path.replacingOccurrences(of: "'", with: "''"))','succeeded')")
        let before = try Data(contentsOf: dbURL)
        let reader = RecognitionReader(localRuns: root.appendingPathComponent("runs"))
        try require(try await reader.read(asset)?.title == "飞机，天空", "Local staging lookup failed")
        try require(try Data(contentsOf: dbURL) == before, "Read-only lookup modified recognition queue")
        let changed = PhotoAsset(id: "same", name: "SAME", files: [PhotoFile(url: image, kind: .rendered, size: file.size + 1, modified: file.modified)])
        try require(try await reader.read(changed) == nil, "Changed source reused stale tags")
        let nas = photos.appendingPathComponent(".photobrowser/v2/run")
        try writeContext(nas)
        let nasRecord = nas.appendingPathComponent("assets/00/photo.json")
        try manager.createDirectory(at: nasRecord.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes(record).write(to: nasRecord)
        let nasReader = RecognitionReader(localRuns: nil)
        try require(try await nasReader.read(asset)?.title == "飞机，天空", "NAS-only metadata lookup failed")
        let sibling = root.appendingPathComponent("photos/other/SAME.JPG")
        let other = PhotoAsset(id: "same", name: "SAME", files: [PhotoFile(url: sibling, kind: .rendered, size: file.size, modified: file.modified)])
        try require(try await reader.read(other) == nil, "Same basename in another directory reused tags")
        let missing = PhotoAsset(id: "missing", name: "missing", files: [PhotoFile(url: photos.appendingPathComponent("missing.jpg"), kind: .rendered)])
        try require(try await nasReader.read(missing) == nil, "Unrecognised file did not remain empty")
        var newer = record
        var newAnalysis = analysisForFixture(); var newOutput = newAnalysis["output"] as! [String: Any]
        newOutput["title"] = "updated"; newAnalysis["output"] = newOutput; newer["analyses"] = [newAnalysis]
        try bytes(newer).write(to: nasRecord)
        try require(try await nasReader.read(asset, refresh: true)?.title == "updated", "Refresh did not read new metadata")
        let cancelled = Task { try await nasReader.read(asset, refresh: true) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure(description: "Cancelled metadata task published a result") }
        catch is CancellationError {} catch { throw error }
    }

    private static func sql(_ db: OpaquePointer?, _ text: String) throws {
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw Failure(description: "Test SQLite setup failed") }
    }
}
