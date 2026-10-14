import Foundation
import BrowserCore

enum SessionRepositoryChecks {
    static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SessionRepository-" + UUID().uuidString)
        let library = root.appendingPathComponent("照片"), storage = root.appendingPathComponent("Sessions")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("original-a".utf8).write(to: library.appendingPathComponent("a.jpg"))
        try Data("original-b".utf8).write(to: library.appendingPathComponent("b.jpg"))
        let assets = try DirectoryScanner.scan(library)
        let repository = BrowserSessionRepository(directory: storage)
        let csv = library.appendingPathComponent("全景素材筛选/全景候选文件清单.csv")
        try fm.createDirectory(at: csv.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("组号,分类,文件名,判断依据\n1,全景候选,b.jpg,legacy\n1,全景候选,a.jpg,legacy\n".utf8).write(to: csv)
        let imported = try repository.restore(assets, in: library)
        try require(imported.groups.first?.assetIDs == ["b", "a"], "first access still imports the legacy CSV in its original order")

        // Reproduce the previous on-disk schema, including metadata predating the lens field.
        let group = PhotoGroup(id: "legacy", name: "保留原名", assetIDs: ["b", "a", "gone"])
        let empty = PhotoGroup(id: "empty", name: "empty", assetIDs: ["gone"])
        let groupsJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode([group, empty]))
        let saved: [String: Any] = [
            "groups": groupsJSON,
            "metadata": ["a": ["fingerprint": assets[0].fingerprint, "value": ["camera": "Legacy Camera", "captured": 123.0]]]
        ]
        try fm.createDirectory(at: storage, withIntermediateDirectories: true)
        let sessionURL = storage.appendingPathComponent(ThumbnailCache.digest(library.resolvingSymlinksInPath().path) + ".json")
        try JSONSerialization.data(withJSONObject: saved).write(to: sessionURL)
        let restored = try repository.restore(assets, in: library)
        try require(restored.groups.count == 1 && restored.groups[0].assetIDs == ["b", "a"] && restored.groups[0].name == group.name,
                    "legacy sessions preserve group names/order and prune only missing members")
        try require(restored.assets[0].metadata?.camera == "Legacy Camera" && restored.assets[0].metadata?.lensModel == nil,
                    "metadata saved before lens support still restores")
        try require(restored.groups[0].id == "legacy", "saved sessions take precedence over the legacy CSV")

        try Data("edited-source-with-a-different-size".utf8).write(to: library.appendingPathComponent("a.jpg"))
        let changed = try DirectoryScanner.scan(library)
        let refreshed = try repository.restore(changed, in: library)
        try require(refreshed.assets[0].metadata == nil && refreshed.groups[0].assetIDs == ["b", "a"],
                    "changed source fingerprints discard stale metadata without discarding manual groups")
        var enriched = changed
        var metadata = PhotoMetadata(captured: Date(timeIntervalSinceReferenceDate: 321), sequence: 4, focalLength: 85)
        metadata.camera = "New Camera"; metadata.lensModel = "Test 85mm"
        enriched[0].metadata = metadata
        try repository.save(assets: enriched, groups: refreshed.groups, in: library)
        let reopened = try BrowserSessionRepository(directory: storage).restore(changed, in: library)
        try require(reopened.assets[0].metadata?.lensModel == "Test 85mm" && reopened.assets[0].metadata?.sequence == 4,
                    "a fresh repository restores enriched metadata and retains the existing session path")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL)) as! [String: Any]
        try require(Set(json.keys) == ["groups", "metadata"], "session extraction keeps the original top-level JSON schema")

        try Data("broken-session".utf8).write(to: sessionURL)
        var rejected = false
        do { _ = try repository.restore(changed, in: library) } catch is DecodingError { rejected = true }
        try require(rejected, "invalid saved sessions report errors instead of silently replacing manual decisions with CSV")
        let blocked = root.appendingPathComponent("storage-is-a-file")
        try Data("keep".utf8).write(to: blocked)
        rejected = false
        do { try BrowserSessionRepository(directory: blocked).save(assets: enriched, groups: [group], in: library) }
        catch { rejected = true }
        let remaining = try Data(contentsOf: library.appendingPathComponent("a.jpg"))
        try require(rejected && remaining == Data("edited-source-with-a-different-size".utf8),
                    "persistence failures are surfaced and leave media bytes untouched")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw BrowserFailure.message(message) }
        print("PASS \(message)")
    }
}
