import Foundation

public struct AIVisualMatch: Identifiable, Sendable {
    public let item: AICatalogItem
    public let distance: Float
    public var id: String { item.id }
}
public struct AIVisualIndexProgress: Sendable {
    public let total: Int
    public let indexed: Int
    public let failed: Int
    public let issue: String?
    public var complete: Bool { indexed + failed >= total }
}

extension AICatalogRepository {
    public nonisolated func item(id: String) async throws -> AICatalogItem? {
        let url = databaseURL
        return try await Self.background { try AICatalogDatabase(url).rows("SELECT item FROM photo WHERE key=?", [.text(id)]).first.map { try JSONDecoder().decode(AICatalogItem.self, from: $0[0].bytes) } }
    }
    public nonisolated func visualRevision(root: URL) async throws -> String {
        let url = databaseURL
        return try await Self.background {
            let db = try AICatalogDatabase(url)
            return String(try db.rows("SELECT revision FROM visual_revision WHERE id=1")[0][0].int) + ":" + String(try db.rows("SELECT revision FROM scope WHERE id=?", [.text(Self.scopeID(root))]).first?.first?.int ?? 0)
        }
    }
    /// Read-only browsing: opening a filter never extracts images or starts an index job.
    public nonisolated func rankedPhotos(root: URL, filter: AICatalogFilter, excluding directories: [URL] = []) async throws -> [AIVisualMatch] {
        guard let id = filter.similaritySeedID, let seed = try await item(id: id) else { throw BrowserFailure.message(L10n.text("相似参考图已不存在，请清除相似筛选。")) }
        let url = databaseURL
        return try await Self.background {
            let db = try AICatalogDatabase(url)
            guard let vector = try AIVisualStorage.vector(db, item: seed) else { throw BrowserFailure.message(L10n.text("参考图尚未建立向量，请在后台任务中生成。")) }
            return try AIVisualStorage.nearest(db, vector: vector, seed: seed, root: root, excluding: directories, limit: 500, filter: filter)
        }
    }
    public nonisolated func visualIndexStatus(root: URL, excluding directories: [URL] = []) async throws -> AIVisualIndexProgress {
        let url = databaseURL
        return try await Self.background { try AIVisualStorage.status(AICatalogDatabase(url), root: root, excluding: directories) }
    }
    public nonisolated func similarPhotos(to seed: AICatalogItem, root: URL, excluding directories: [URL] = [], limit: Int = 100) async throws -> [AIVisualMatch] {
        let url = databaseURL, vector = try await visualVector(seed)
        return try await Self.background { try AIVisualStorage.nearest(AICatalogDatabase(url), vector: vector, seed: seed, root: root, excluding: directories, limit: limit) }
    }
    public nonisolated func indexVisualPhotos(root: URL, excluding directories: [URL] = [], progress: @escaping @Sendable (AIVisualIndexProgress) async -> Void) async throws {
        let url = databaseURL
        var status = try await visualIndexStatus(root: root, excluding: directories), cursor: Int64 = 0
        await progress(status)
        while true {
            try Task.checkCancellation()
            let after = cursor
            let batch = try await Self.background { try AIVisualStorage.pending(AICatalogDatabase(url), root: root, excluding: directories, after: after) }
            guard !batch.isEmpty else { break }
            cursor = batch.last!.row
            let outcomes = try await withThrowingTaskGroup(of: AIVisualOutcome.self) { group in
                var next = 0, results: [AIVisualOutcome] = []
                func add(_ item: AICatalogItem) {
                    group.addTask {
                        do { return AIVisualOutcome(item: item, data: try await AIImageVector.generate(item).data, issue: nil) }
                        catch is CancellationError { throw CancellationError() }
                        catch { return AIVisualOutcome(item: item, data: nil, issue: error.localizedDescription) }
                    }
                }
                while next < min(2, batch.count) { add(batch[next].item); next += 1 }
                while let outcome = try await group.next() {
                    results.append(outcome)
                    if next < batch.count { add(batch[next].item); next += 1 }
                }
                return results
            }
            try Task.checkCancellation()
            let written = try await Self.background {
                let db = try AICatalogDatabase(url, write: true)
                try db.execute("BEGIN IMMEDIATE")
                do {
                    var indexed = 0, failed = 0
                    for result in outcomes where try AIVisualStorage.put(db, result) {
                        if result.data != nil { indexed += 1 } else { failed += 1 }
                    }
                    try db.execute("COMMIT"); return (indexed, failed)
                } catch { try? db.execute("ROLLBACK"); throw error }
            }
            status = AIVisualIndexProgress(total: status.total, indexed: status.indexed + written.0,
                                           failed: status.failed + written.1, issue: outcomes.compactMap(\.issue).last ?? status.issue)
            await progress(status)
        }
        await progress(try await visualIndexStatus(root: root, excluding: directories))
    }
    public nonisolated func resetVisualIndex(root: URL, excluding directories: [URL] = [], failuresOnly: Bool = false) async throws {
        let url = databaseURL
        try await Self.background {
            let db = try AICatalogDatabase(url, write: true), exclusion = AICatalogSQL.exclusion(root: root, directories: directories, alias: "v")
            try db.execute("DELETE FROM photo_vector WHERE photo_id IN (SELECT v.photo_id FROM photo_vector v JOIN member m ON m.photo_id=v.photo_id WHERE m.scope_id=? AND v.model=?" + (failuresOnly ? " AND v.issue IS NOT NULL" : "") + exclusion.sql + ")", [.text(Self.scopeID(root)), .text(AIImageVector.model)] + exclusion.values)
        }
    }
    private nonisolated func visualVector(_ item: AICatalogItem) async throws -> AIImageVector {
        let url = databaseURL
        if let stored = try await Self.background({ try AIVisualStorage.vector(AICatalogDatabase(url), item: item) }) { return stored }
        let vector = try await AIImageVector.generate(item)
        try await Self.background {
            guard try AIVisualStorage.put(AICatalogDatabase(url, write: true), AIVisualOutcome(item: item, data: vector.data, issue: nil)) else {
                throw BrowserFailure.message(L10n.text("照片已变化，请刷新后重试。"))
            }
        }
        return vector
    }
}

struct AIVisualOutcome: Sendable { let item: AICatalogItem; let data: Data?; let issue: String? }
enum AIVisualStorage {
    static func vector(_ db: AICatalogDatabase, item: AICatalogItem) throws -> AIImageVector? {
        let row = try db.rows("SELECT v.data,v.issue,p.item FROM photo_vector v JOIN photo p ON p.id=v.photo_id WHERE p.key=? AND v.snapshot=p.snapshot AND v.model=?", [.text(item.id), .text(AIImageVector.model)]).first
        guard let row else { return nil }
        guard AICatalogItem.sameImages(item.asset, try JSONDecoder().decode(AICatalogItem.self, from: row[2].bytes).asset) else { return nil }
        if case .text(let issue) = row[1] { throw BrowserFailure.message(issue) }
        return try AIImageVector(data: row[0].bytes)
    }
    @discardableResult static func put(_ db: AICatalogDatabase, _ result: AIVisualOutcome) throws -> Bool {
        let item = result.item
        guard let source = try db.rows("SELECT snapshot,item FROM photo WHERE key=?", [.text(item.id)]).first,
              AICatalogItem.sameImages(item.asset, try JSONDecoder().decode(AICatalogItem.self, from: source[1].bytes).asset) else { return false }
        let snapshot = source[0].string
        try db.execute("INSERT INTO photo_vector(photo_id,snapshot,directory,model,data,issue) SELECT id,snapshot,directory,?,?,? FROM photo WHERE key=? AND snapshot=? ON CONFLICT(photo_id) DO UPDATE SET snapshot=excluded.snapshot,directory=excluded.directory,model=excluded.model,data=excluded.data,issue=excluded.issue", [
            .text(AIImageVector.model), result.data.map(AIBind.data) ?? .null, result.issue.map(AIBind.text) ?? .null, .text(item.id), .text(snapshot)])
        return try db.rows("SELECT changes()").first?.first?.int == 1
    }
    static func status(_ db: AICatalogDatabase, root: URL, excluding directories: [URL]) throws -> AIVisualIndexProgress {
        try db.execute("BEGIN"); defer { try? db.execute("COMMIT") }
        let exclusion = AICatalogSQL.exclusion(root: root, directories: directories)
        let row = try db.rows("SELECT count(*),sum(v.data IS NOT NULL),sum(v.issue IS NOT NULL) FROM member m JOIN photo p ON p.id=m.photo_id LEFT JOIN photo_vector v ON v.photo_id=p.id AND v.model=? WHERE m.scope_id=?" + exclusion.sql, [.text(AIImageVector.model), .text(AICatalogRepository.scopeID(root))] + exclusion.values)[0]
        let issue = try db.rows("SELECT v.issue FROM photo_vector v JOIN photo p ON p.id=v.photo_id JOIN member m ON m.photo_id=p.id WHERE m.scope_id=? AND v.model=? AND v.issue IS NOT NULL" + exclusion.sql + " LIMIT 1", [.text(AICatalogRepository.scopeID(root)), .text(AIImageVector.model)] + exclusion.values).first?.first?.string
        return AIVisualIndexProgress(total: Int(row[0].int), indexed: Int(row[1].int), failed: Int(row[2].int), issue: issue)
    }
    static func pending(_ db: AICatalogDatabase, root: URL, excluding directories: [URL], after: Int64) throws -> [(row: Int64, item: AICatalogItem)] {
        let exclusion = AICatalogSQL.exclusion(root: root, directories: directories)
        return try db.rows("SELECT m.photo_id,p.item FROM member m JOIN photo p ON p.id=m.photo_id LEFT JOIN photo_vector v ON v.photo_id=p.id AND v.model=? WHERE m.scope_id=? AND m.photo_id>? AND v.photo_id IS NULL" + exclusion.sql + " ORDER BY m.photo_id LIMIT 64", [.text(AIImageVector.model), .text(AICatalogRepository.scopeID(root)), .integer(after)] + exclusion.values).map { ($0[0].int, try JSONDecoder().decode(AICatalogItem.self, from: $0[1].bytes)) }
    }
    static func nearest(_ db: AICatalogDatabase, vector: AIImageVector, seed: AICatalogItem, root: URL, excluding directories: [URL], limit: Int, filter: AICatalogFilter? = nil) throws -> [AIVisualMatch] {
        try db.execute("BEGIN"); defer { try? db.execute("COMMIT") }
        let exclusion = AICatalogSQL.exclusion(root: root, directories: directories, alias: "v")
        let seedRow = try db.rows("SELECT id FROM photo WHERE key=?", [.text(seed.id)]).first?.first?.int ?? -1
        // Metadata blobs are large. Use the maintained lightweight source index for
        // label/state-only ranking; text searches still use the catalog search field.
        let hasSlim = try !db.rows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='background_source'").isEmpty
        let slim = filter?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true && hasSlim
        var heap = AIVisualHeap(limit: max(1, min(500, limit))), after: Int64 = 0
        while true {
            let rows: [[AIBind]]
            if let filter {
                let match = AICatalogSQL.match(root: root, filter: filter, excluding: directories)
                let from = slim ? match.from.replacingOccurrences(of: "JOIN photo p ON", with: "JOIN background_source p ON") : match.from
                rows = try db.rows(match.prefix + "SELECT m.photo_id,v.data " + from + " JOIN photo_vector v ON v.photo_id=p.id " + match.whereSQL + " AND m.photo_id>? AND m.photo_id<>? AND v.model=? AND v.data IS NOT NULL AND v.snapshot=p.snapshot ORDER BY m.photo_id LIMIT 512", match.values + [.integer(after), .integer(seedRow), .text(AIImageVector.model)])
            } else {
                rows = try db.rows("SELECT m.photo_id,v.data FROM member m JOIN photo_vector v ON v.photo_id=m.photo_id WHERE m.scope_id=? AND m.photo_id>? AND m.photo_id<>? AND v.model=? AND v.data IS NOT NULL" + exclusion.sql + " ORDER BY m.photo_id LIMIT 512", [.text(AICatalogRepository.scopeID(root)), .integer(after), .integer(seedRow), .text(AIImageVector.model)] + exclusion.values)
            }
            guard !rows.isEmpty else { break }
            for row in rows {
                try Task.checkCancellation()
                heap.add(row: row[0].int, distance: vector.distance(to: try AIImageVector(data: row[1].bytes)))
            }
            after = rows.last![0].int
        }
        let ranked = heap.sorted()
        guard !ranked.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ranked.count).joined(separator: ",")
        let items = try db.rows("SELECT id,item FROM photo WHERE id IN (" + marks + ")", ranked.map { .integer($0.row) })
        let byID = try Dictionary(uniqueKeysWithValues: items.map { ($0[0].int, try JSONDecoder().decode(AICatalogItem.self, from: $0[1].bytes)) })
        return ranked.compactMap { hit in byID[hit.row].map { AIVisualMatch(item: $0, distance: hit.distance) } }
    }
}

/// A bounded max-heap keeps only the nearest K IDs; image blobs are loaded after ranking.
struct AIVisualHeap {
    struct Hit { let row: Int64; let distance: Float }
    let limit: Int
    private var values: [Hit] = []
    init(limit: Int) { self.limit = limit }
    private func worse(_ a: Hit, than b: Hit) -> Bool { a.distance == b.distance ? a.row > b.row : a.distance > b.distance }
    mutating func add(row: Int64, distance: Float) {
        let hit = Hit(row: row, distance: distance)
        if values.count < limit {
            values.append(hit); var i = values.count - 1
            while i > 0 { let parent = (i - 1) / 2; if !worse(values[i], than: values[parent]) { break }; values.swapAt(i, parent); i = parent }
        } else if let first = values.first, worse(first, than: hit) {
            values[0] = hit; var i = 0
            while i * 2 + 1 < values.count {
                let left = i * 2 + 1, right = left + 1
                let child = right < values.count && worse(values[right], than: values[left]) ? right : left
                if !worse(values[child], than: values[i]) { break }; values.swapAt(i, child); i = child
            }
        }
    }
    func sorted() -> [Hit] { values.sorted { worse($1, than: $0) } }
}
