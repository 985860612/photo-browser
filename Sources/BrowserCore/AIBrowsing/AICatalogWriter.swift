import Foundation

final class AICatalogWriter {
    let db: AICatalogDatabase
    let dbURL: URL
    let root: URL
    let scope: String
    private let encoder = JSONEncoder()
    private var termIDs: [String: Int64] = [:]
    init(_ url: URL, root: URL, connection: AICatalogDatabase? = nil) throws {
        dbURL = url; db = try connection ?? AICatalogDatabase(url, write: true); self.root = root; scope = AICatalogRepository.scopeID(root)
        try db.execute("INSERT OR IGNORE INTO scope(id,root) VALUES(?,?)", [.text(scope), .text(root.aiStandardized.path)])
    }
    func transaction(_ body: () throws -> Void) throws {
        try db.execute("BEGIN IMMEDIATE")
        do { try body(); try db.execute("UPDATE scope SET revision=revision+1 WHERE id=?", [.text(scope)]); try db.execute("COMMIT") }
        catch { try? db.execute("ROLLBACK"); throw error }
    }
    func put(_ item: AICatalogItem, stamp: String, priority: Int, analysisDate: String, generation: String?) throws {
        guard AICatalogPaths.allowed(item.asset.preferred.url, root: root) else { return }
        let existing = try db.rows("SELECT id,stamp,priority,analysis_date,date,item,snapshot FROM photo WHERE key=?", [.text(item.id)]).first
        if let existing, existing[1].string == stamp || existing[2].int > priority || (existing[2].int == priority && existing[3].string > analysisDate) {
            try member(existing[0].int, date: existing[4].double, generation: generation); return
        }
        if item.asset.imageFiles.contains(where: { !DirectoryScanner.rawExtensions.union(DirectoryScanner.renderedExtensions).contains($0.url.pathExtension.lowercased()) }) {
            try db.execute("INSERT INTO known_asset(key,directory,asset) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET asset=excluded.asset", [.text(item.id), .text(item.directory.path), .data(try encoder.encode(item.asset))])
        }
        var cached = item
        var snapshot = AICatalogItem.snapshot(item.asset)
        if let existing {
            let previous = try JSONDecoder().decode(AICatalogItem.self, from: existing[5].bytes)
            if AICatalogItem.sameImages(previous.asset, item.asset) {
                snapshot = existing[6].string
                if cached.preview == nil { cached.preview = previous.preview }
                if cached.asset.metadata == nil {
                    cached.asset = PhotoAsset(id: item.asset.id, name: item.asset.name, files: item.asset.files, metadata: previous.asset.metadata)
                }
            }
        }
        if let m = item.metadata {
            cached.metadata = RecognitionMetadata(title: m.title, description: m.description, sections: m.sections, rawResponse: "", modelName: m.modelName, failure: m.failure)
        }
        let date = cached.asset.metadata?.captured ?? cached.asset.imageFiles.map(\.modified).max() ?? .distantPast
        let search = searchText(item)
        try db.execute("INSERT INTO photo(key,directory,item,state,search,date,snapshot,stamp,priority,analysis_date) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET directory=excluded.directory,item=excluded.item,state=excluded.state,search=excluded.search,date=excluded.date,snapshot=excluded.snapshot,stamp=excluded.stamp,priority=excluded.priority,analysis_date=excluded.analysis_date", [
            .text(item.id), .text(item.directory.path), .data(try encoder.encode(cached)), .text(item.state), .text(search), .real(date.timeIntervalSince1970),
            .text(snapshot), .text(stamp), .integer(Int64(priority)), .text(analysisDate)])
        let row = try db.rows("SELECT id FROM photo WHERE key=?", [.text(item.id)])[0][0].int
        try db.execute("DELETE FROM photo_term WHERE photo_id=?", [.integer(row)])
        if item.state == "processing.succeeded" {
            for section in item.metadata?.sections ?? [] {
                for tag in section.tags {
                    let key = section.id + "|" + tag.code
                    let term: Int64
                    if let cached = termIDs[key] { term = cached }
                    else {
                        try db.execute("INSERT INTO term(field,code,name) VALUES(?,?,?) ON CONFLICT(field,code) DO UPDATE SET name=excluded.name", [.text(section.id), .text(tag.code), .text(tag.name)])
                        term = try db.rows("SELECT id FROM term WHERE field=? AND code=?", [.text(section.id), .text(tag.code)])[0][0].int; termIDs[key] = term
                    }
                    try db.execute("INSERT OR IGNORE INTO photo_term(term_id,photo_id) VALUES(?,?)", [.integer(term), .integer(row)])
                }
            }
        }
        // A regeneration changes ordering and facet counts in every cached scope containing this photo.
        try db.execute("UPDATE scope SET revision=revision+1 WHERE id IN(SELECT scope_id FROM member WHERE photo_id=?)", [.integer(row)])
        try db.execute("UPDATE member SET date=? WHERE photo_id=?", [.real(date.timeIntervalSince1970), .integer(row)])
        try member(row, date: date.timeIntervalSince1970, generation: generation)
    }
    func inventory(_ asset: PhotoAsset, generation: String) throws -> Bool {
        let key = AICatalogItem.identity(asset)
        if let row = try db.rows("SELECT id,snapshot,item,date FROM photo WHERE key=?", [.text(key)]).first {
            let cached = try JSONDecoder().decode(AICatalogItem.self, from: row[2].bytes)
            let same = AICatalogItem.sameImages(cached.asset, asset)
            if same {
                let oldSidecars = cached.asset.files.filter { $0.kind == .sidecar }.map { $0.url.lastPathComponent }.sorted()
                let newSidecars = asset.files.filter { $0.kind == .sidecar }.map { $0.url.lastPathComponent }.sorted()
                if oldSidecars != newSidecars {
                    var refreshed = cached
                    refreshed.asset = PhotoAsset(id: asset.id, name: asset.name, files: asset.files, metadata: cached.asset.metadata)
                    try db.execute("UPDATE photo SET item=?,search=? WHERE id=?", [.data(try encoder.encode(refreshed)), .text(searchText(refreshed)), .integer(row[0].int)])
                    try db.execute("UPDATE scope SET revision=revision+1 WHERE id IN(SELECT scope_id FROM member WHERE photo_id=?)", [.integer(row[0].int)])
                }
                try member(row[0].int, date: row[3].double, generation: generation); return cached.state != "processing.pending"
            }
            var changed = asset
            // Metadata from a different source snapshot must not classify the new file.
            changed.metadata = nil
            try put(AICatalogItem(asset: changed), stamp: UUID().uuidString, priority: 100, analysisDate: "", generation: generation)
            try db.execute("UPDATE photo SET priority=0 WHERE key=?", [.text(key)])
        } else { try put(AICatalogItem(asset: asset), stamp: UUID().uuidString, priority: 0, analysisDate: "", generation: generation) }
        return false
    }
    func member(_ id: Int64, date: Double, generation: String?) throws {
        try db.execute("INSERT INTO member(scope_id,photo_id,date,generation) VALUES(?,?,?,?) ON CONFLICT(scope_id,photo_id) DO UPDATE SET date=excluded.date,generation=CASE WHEN excluded.generation='' THEN member.generation ELSE excluded.generation END", [.text(scope), .integer(id), .real(date), .text(generation ?? "")])
    }
    private func searchText(_ item: AICatalogItem) -> String {
        ([item.title, item.metadata?.description ?? "", item.directory.path] + item.asset.files.map { $0.url.lastPathComponent } + (item.metadata?.sections.flatMap { $0.tags.map(\.name) } ?? [])).joined(separator: " ").lowercased()
    }
}
