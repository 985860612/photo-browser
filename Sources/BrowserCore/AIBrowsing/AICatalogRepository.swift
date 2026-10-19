import Foundation

public actor AICatalogRepository {
    public nonisolated let databaseURL: URL
    let runs: URL
    let generated: URL
    var syncing = false

    public init(databaseURL: URL? = nil, runs: URL? = nil, generated: URL? = nil) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoBrowser")
        self.databaseURL = databaseURL ?? support.appendingPathComponent("AIBrowse/catalog-v1.sqlite")
        self.runs = runs ?? support.appendingPathComponent("RecognitionRuns")
        self.generated = generated ?? support.appendingPathComponent("GeneratedRecognition")
        try AICatalogDatabase.create(self.databaseURL)
    }
    public nonisolated static func scopeID(_ root: URL) -> String { ThumbnailCache.digest(root.aiStandardized.path) }
    public nonisolated func fields() throws -> [AICatalogField] {
        try RecognitionContract.context().fields.filter { $0.dictionary != nil }.map { AICatalogField(id: $0.output_field, name: $0.name) }
    }

    public nonisolated func states() throws -> [AICatalogField] {
        struct Term: Decodable { let code: String; let name: String; let browse_name: String?; let browse_order: Int? }
        struct File: Decodable { let dictionaries: [String: [Term]] }
        let file = try JSONDecoder().decode(File.self, from: RecognitionContract.resource("recognition-dictionary", "json"))
        return (file.dictionaries["processing"] ?? []).filter { $0.browse_order != nil }.sorted { $0.browse_order! < $1.browse_order! }.map { AICatalogField(id: $0.code, name: $0.browse_name ?? $0.name) }
    }
    public nonisolated func knownAssets(in directory: URL) async throws -> [PhotoAsset] {
        let url = databaseURL
        return try await Self.background { try AICatalogKnownAssets.read(url, directory: directory) }
    }
    public nonisolated func lastIndexed(root: URL) async throws -> Date? {
        let url = databaseURL
        return try await Self.background {
            try AICatalogDatabase(url).rows("SELECT updated FROM scope WHERE id=? AND complete=1", [.text(Self.scopeID(root))]).first.map { Date(timeIntervalSince1970: $0[0].double) }
        }
    }

    public nonisolated func page(root: URL, filter: AICatalogFilter, after: AICatalogCursor? = nil, excluding directories: [URL] = []) async throws -> AICatalogPage {
        let url = databaseURL
        return try await Self.background {
            let db = try AICatalogDatabase(url)
            let match = AICatalogSQL.match(root: root, filter: filter, excluding: directories)
            var sql = match.prefix + "SELECT p.item,m.date,p.id " + match.from + match.whereSQL
            var values = match.values
            if let after { sql += filter.descending ? " AND (m.date,p.id)<(?,?)" : " AND (m.date,p.id)>(?,?)"; values += [.real(after.date), .integer(after.row)] }
            let direction = filter.descending ? " DESC" : " ASC"
            sql += " ORDER BY m.date" + direction + ",p.id" + direction + " LIMIT 61"
            let rows = try db.rows(sql, values)
            let displayed = Array(rows.prefix(60))
            let items = try displayed.map { try JSONDecoder().decode(AICatalogItem.self, from: $0[0].bytes) }
            let cursor = displayed.last.map { AICatalogCursor(date: $0[1].double, row: $0[2].int) }
            return AICatalogPage(items: items, cursor: cursor, hasMore: rows.count > 60)
        }
    }
    public nonisolated func summary(root: URL, filter: AICatalogFilter, excluding directories: [URL] = []) async throws -> AICatalogSummary {
        let url = databaseURL
        return try await Self.background {
            let db = try AICatalogDatabase(url), scope = Self.scopeID(root)
            try db.execute("BEGIN")
            defer { try? db.execute("COMMIT") }
            let match = AICatalogSQL.match(root: root, filter: filter, excluding: directories)
            let total = try db.rows(match.prefix + "SELECT count(*) " + match.from + match.whereSQL, match.values).first?.first?.int ?? 0
            let exclusion = AICatalogSQL.exclusion(root: root, directories: directories)
            let states = try db.rows("SELECT p.state,count(*) FROM member m JOIN photo p ON p.id=m.photo_id WHERE m.scope_id=?" + exclusion.sql + " GROUP BY p.state", [.text(scope)] + exclusion.values)
            let status = try db.rows("SELECT complete,updated FROM scope WHERE id=?", [.text(scope)]).first
            return AICatalogSummary(total: Int(total), states: Dictionary(uniqueKeysWithValues: states.map { ($0[0].string, Int($0[1].int)) }),
                                    complete: status?.first?.int == 1, updated: status.map { Date(timeIntervalSince1970: $0[1].double) })
        }
    }
    public nonisolated func facets(root: URL, filter: AICatalogFilter, field: String, search: String = "", limit: Int = 10, excluding directories: [URL] = []) async throws -> [AICatalogFacet] {
        let url = databaseURL
        return try await Self.background {
            let db = try AICatalogDatabase(url)
            try db.execute("BEGIN")
            defer { try? db.execute("COMMIT") }
            let revision = try db.rows("SELECT revision FROM scope WHERE id=?", [.text(Self.scopeID(root))]).first?.first?.int ?? 0
            var other = filter; other.tags[field] = nil
            let parts = [url.path, root.path, String(revision), field, search, String(limit), other.state, other.text] + other.tags.keys.sorted().flatMap { [$0] + (other.tags[$0] ?? []).sorted() }
            let key = String(decoding: try JSONEncoder().encode([parts, AICatalogSQL.excludedPaths(root: root, directories: directories)]), as: UTF8.self)
            if let cached = AIFacetCache.shared.get(key) { return cached }
            let match = AICatalogSQL.match(root: root, filter: other, excluding: directories)
            let sql = match.prefix + (match.prefix.isEmpty ? "WITH " : ", ") + "matched AS MATERIALIZED (SELECT p.id " + match.from + match.whereSQL + ") " +
                "SELECT d.code,d.name,count(*) n FROM term d CROSS JOIN photo_term t ON t.term_id=d.id CROSS JOIN matched x ON x.id=t.photo_id WHERE d.field=? AND d.name LIKE ? ESCAPE '\\' GROUP BY d.id ORDER BY n DESC,d.name LIMIT ?"
            let values = match.values + [.text(field), .text("%" + AICatalogSQL.escape(search) + "%"), .integer(Int64(max(1, min(1000, limit))))]
            let result = try db.rows(sql, values).map { AICatalogFacet(code: $0[0].string, name: $0[1].string, count: Int($0[2].int)) }
            AIFacetCache.shared.put(key, result)
            return result
        }
    }
    public func update(_ asset: PhotoAsset, root: URL) async throws {
        guard !asset.imageFiles.isEmpty, !asset.isVideo, AICatalogPaths.allowed(asset.preferred.url, root: root) else { return }
        let metadata = try await RecognitionReader.shared.read(asset, refresh: true)
        let item = AICatalogItem(asset: asset, metadata: metadata, state: metadata == nil ? "processing.pending" : (metadata?.failure == nil ? "processing.succeeded" : "processing.failed"))
        let writer = try AICatalogWriter(databaseURL, root: root)
        try writer.transaction {
            try writer.put(item, stamp: UUID().uuidString, priority: 30, analysisDate: ISO8601DateFormatter().string(from: Date()), generation: nil)
        }
    }
    nonisolated static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try autoreleasepool { try work() } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

private final class AIFacetCache: @unchecked Sendable {
    static let shared = AIFacetCache()
    private final class Box: NSObject { let rows: [AICatalogFacet]; init(_ rows: [AICatalogFacet]) { self.rows = rows } }
    private let values = NSCache<NSString, Box>()
    init() { values.countLimit = 128 }
    func get(_ key: String) -> [AICatalogFacet]? { values.object(forKey: key as NSString)?.rows }
    func put(_ key: String, _ rows: [AICatalogFacet]) { values.setObject(Box(rows), forKey: key as NSString) }
}

enum AICatalogSQL {
    struct Match { let prefix: String; let from: String; let whereSQL: String; let values: [AIBind] }
    static func escape(_ text: String) -> String { text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") }
    static func excludedPaths(root: URL, directories: [URL]) -> [String] {
        let relevant = Set(directories.filter { AICatalogPaths.contains($0, in: root) || AICatalogPaths.contains(root, in: $0) }.map { $0.aiStandardized.path })
        return relevant.sorted().reduce(into: [String]()) { result, path in
            if !result.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) { result.append(path) }
        }
    }
    static func exclusion(root: URL, directories: [URL]) -> (sql: String, values: [AIBind]) {
        var sql = "", values: [AIBind] = []
        for path in excludedPaths(root: root, directories: directories) {
            // Binary path ranges include descendants without LIKE's wildcard or case-folding rules.
            let prefix = path == "/" ? "/" : path + "/"
            let upper = path == "/" ? "0" : path + "0"
            sql += " AND NOT (p.directory=? OR (p.directory>=? AND p.directory<?))"
            values += [.text(path), .text(prefix), .text(upper)]
        }
        return (sql, values)
    }
    static func match(root: URL, filter: AICatalogFilter, excluding directories: [URL] = []) -> Match {
        let tags = filter.state == "processing.succeeded" ? filter.tags.filter { !$0.value.isEmpty }.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count < $1.value.count } : []
        var prefix = "", from = "FROM member m JOIN photo p ON p.id=m.photo_id ", values: [AIBind] = []
        if let first = tags.first {
            let marks = Array(repeating: "?", count: first.value.count).joined(separator: ",")
            prefix = "WITH chosen AS MATERIALIZED (SELECT DISTINCT t.photo_id FROM term d JOIN photo_term t ON t.term_id=d.id WHERE d.field=? AND d.code IN (" + marks + ")) "
            values += [.text(first.key)] + first.value.sorted().map { .text($0) }
            from += "JOIN chosen x ON x.photo_id=p.id "
        }
        var predicate = "WHERE m.scope_id=? AND p.state=?"
        values += [.text(AICatalogRepository.scopeID(root)), .text(filter.state)]
        let exclusion = exclusion(root: root, directories: directories)
        predicate += exclusion.sql; values += exclusion.values
        for tag in tags.dropFirst() {
            let marks = Array(repeating: "?", count: tag.value.count).joined(separator: ",")
            predicate += " AND EXISTS(SELECT 1 FROM photo_term t JOIN term d ON d.id=t.term_id WHERE t.photo_id=p.id AND d.field=? AND d.code IN (" + marks + "))"
            values += [.text(tag.key)] + tag.value.sorted().map { .text($0) }
        }
        for word in filter.text.lowercased().split(whereSeparator: \.isWhitespace) {
            predicate += " AND p.search LIKE ? ESCAPE '\\'"; values.append(.text("%" + escape(String(word)) + "%"))
        }
        return Match(prefix: prefix, from: from, whereSQL: predicate, values: values)
    }
}

/// Only authoritative, previously identified photos need hints; never sniff arbitrary source files.
enum AICatalogKnownAssets {
    static func read(_ database: URL, directory: URL) throws -> [PhotoAsset] {
        try AICatalogDatabase(database).rows("SELECT asset FROM known_asset WHERE directory=?", [.text(directory.aiStandardized.path)]).map { try JSONDecoder().decode(PhotoAsset.self, from: $0[0].bytes) }
    }
}
