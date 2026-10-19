import Foundation

public final class BackgroundTaskRepository: @unchecked Sendable {
    public let databaseURL: URL
    public init(databaseURL: URL? = nil) throws {
        self.databaseURL = try databaseURL ?? AICatalogRepository().databaseURL
        try AICatalogDatabase.create(self.databaseURL)
        let db = try AICatalogDatabase(self.databaseURL, write: true)
        for sql in Self.schema { try db.execute(sql) }
        if try db.rows("SELECT 1 FROM background_catalog_info WHERE version=1").isEmpty {
            try db.execute("BEGIN IMMEDIATE")
            do {
                try db.execute("INSERT OR IGNORE INTO background_source SELECT id,key,directory,state,snapshot," + Self.eligible("item") + " FROM photo")
                try db.execute("INSERT OR IGNORE INTO background_catalog_info VALUES(1)")
                try db.execute("COMMIT")
            } catch { try? db.execute("ROLLBACK"); throw error }
        }
    }
    private static func eligible(_ item: String) -> String {
        "EXISTS(SELECT 1 FROM json_each(\(item),'$.asset.files') f WHERE json_extract(f.value,'$.kind')<>'video' AND lower(json_extract(f.value,'$.url')) NOT LIKE '%.psd' AND lower(json_extract(f.value,'$.url')) NOT LIKE '%.psb')"
    }
    private static let schema = [
        "CREATE TABLE IF NOT EXISTS background_catalog_info(version INTEGER PRIMARY KEY)",
        "CREATE TABLE IF NOT EXISTS background_source(id INTEGER PRIMARY KEY,key TEXT UNIQUE NOT NULL,directory TEXT NOT NULL,state TEXT NOT NULL,snapshot TEXT NOT NULL,eligible INTEGER NOT NULL)",
        "CREATE INDEX IF NOT EXISTS background_source_directory ON background_source(directory,id)",
        "CREATE TRIGGER IF NOT EXISTS background_source_insert AFTER INSERT ON photo BEGIN INSERT INTO background_source SELECT NEW.id,NEW.key,NEW.directory,NEW.state,NEW.snapshot,\(eligible("NEW.item")) ON CONFLICT(id) DO UPDATE SET key=excluded.key,directory=excluded.directory,state=excluded.state,snapshot=excluded.snapshot,eligible=excluded.eligible; END",
        "CREATE TRIGGER IF NOT EXISTS background_source_update AFTER UPDATE OF snapshot,directory,state ON photo BEGIN INSERT INTO background_source SELECT NEW.id,NEW.key,NEW.directory,NEW.state,NEW.snapshot,CASE WHEN NEW.snapshot=OLD.snapshot THEN coalesce((SELECT eligible FROM background_source WHERE id=NEW.id),1) ELSE \(eligible("NEW.item")) END ON CONFLICT(id) DO UPDATE SET key=excluded.key,directory=excluded.directory,state=excluded.state,snapshot=excluded.snapshot,eligible=excluded.eligible; END",
        "CREATE TRIGGER IF NOT EXISTS background_source_delete AFTER DELETE ON photo BEGIN DELETE FROM background_source WHERE id=OLD.id; END",
        "CREATE TABLE IF NOT EXISTS background_task(id TEXT PRIMARY KEY,root TEXT NOT NULL,options BLOB NOT NULL,configuration BLOB NOT NULL,prompt TEXT NOT NULL,state TEXT NOT NULL,created REAL NOT NULL,elapsed REAL NOT NULL DEFAULT 0,started REAL,last_pick REAL NOT NULL DEFAULT 0,ai_blocked INTEGER NOT NULL DEFAULT 0,issue TEXT)",
        "CREATE TABLE IF NOT EXISTS background_item(task_id TEXT NOT NULL,photo_id INTEGER NOT NULL,snapshot TEXT NOT NULL,preview_state TEXT NOT NULL,preview_updated REAL NOT NULL DEFAULT 0,ai_state TEXT NOT NULL,vector_state TEXT NOT NULL,preview_url TEXT,preview_issue TEXT,ai_issue TEXT,vector_issue TEXT,ai_result BLOB,ai_updated REAL NOT NULL DEFAULT 0,vector_updated REAL NOT NULL DEFAULT 0,updated REAL NOT NULL,PRIMARY KEY(task_id,photo_id)) WITHOUT ROWID",
        "CREATE INDEX IF NOT EXISTS background_preview_queue ON background_item(task_id,preview_state,photo_id)",
        "CREATE INDEX IF NOT EXISTS background_ai_queue ON background_item(task_id,ai_state,photo_id)",
        "CREATE INDEX IF NOT EXISTS background_vector_queue ON background_item(task_id,vector_state,photo_id)",
        "CREATE INDEX IF NOT EXISTS background_reuse ON background_item(photo_id,snapshot,updated)",
        "CREATE TRIGGER IF NOT EXISTS background_photo_removed AFTER DELETE ON photo BEGIN UPDATE background_item SET preview_issue='Source photo removed from catalog',ai_state=CASE WHEN ai_state='item.pending' THEN 'item.failed' ELSE ai_state END,vector_state=CASE WHEN vector_state='item.pending' THEN 'item.failed' ELSE vector_state END WHERE photo_id=OLD.id; END",
        "CREATE TABLE IF NOT EXISTS vector_timestamp(photo_id INTEGER PRIMARY KEY,updated REAL NOT NULL)",
        "CREATE TRIGGER IF NOT EXISTS vector_time_insert AFTER INSERT ON photo_vector BEGIN INSERT INTO vector_timestamp VALUES(NEW.photo_id,unixepoch('now')) ON CONFLICT(photo_id) DO UPDATE SET updated=excluded.updated; END",
        "CREATE TRIGGER IF NOT EXISTS vector_time_update AFTER UPDATE ON photo_vector BEGIN INSERT INTO vector_timestamp VALUES(NEW.photo_id,unixepoch('now')) ON CONFLICT(photo_id) DO UPDATE SET updated=excluded.updated; END",
        "CREATE TRIGGER IF NOT EXISTS vector_time_delete AFTER DELETE ON photo_vector BEGIN DELETE FROM vector_timestamp WHERE photo_id=OLD.photo_id; END"
    ]
    private func selection(_ options: BackgroundTaskOptions) throws -> (String, [AIBind]) {
        let path = options.root.aiStandardized.path
        let prefix = path == "/" ? "/" : path + "/", upper = path == "/" ? "0" : path + "0"
        var sql = " WHERE (p.directory=? OR (p.directory>=? AND p.directory<?))", values: [AIBind] = [.text(path), .text(prefix), .text(upper)]
        let exclusion = AICatalogSQL.exclusion(root: options.root, directories: options.exclusions)
        sql += exclusion.sql; values += exclusion.values
        sql += " AND p.eligible=1"
        if let ids = options.photoIDs {
            sql += " AND p.key IN (SELECT value FROM json_each(?))"
            values.append(.text(String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)))
        }
        return (sql, values)
    }
    public func estimate(_ options: BackgroundTaskOptions) throws -> BackgroundTaskEstimate {
        let db = try AICatalogDatabase(databaseURL), match = try selection(options)
        let row = try db.rows("SELECT count(*),sum(p.state<>'processing.succeeded'),sum(v.data IS NULL) FROM background_source p LEFT JOIN photo_vector v ON v.photo_id=p.id AND v.model=? AND v.snapshot=p.snapshot AND v.issue IS NULL" + match.0, [.text(AIImageVector.model)] + match.1)[0]
        let n = Int(row[0].int)
        return BackgroundTaskEstimate(photos: n, ai: options.ai ? (options.force ? n : Int(row[1].int)) : 0, vectors: options.vector ? (options.force ? n : Int(row[2].int)) : 0)
    }
    @discardableResult public func create(_ options: BackgroundTaskOptions, configuration: AIModelConfiguration) throws -> String {
        guard options.ai || options.vector else { throw BrowserFailure.message(L10n.text("请选择至少一种处理内容。")) }
        let db = try AICatalogDatabase(databaseURL, write: true), match = try selection(options), id = UUID().uuidString
        let ai = !options.ai ? "'item.disabled'" : (options.force ? "'item.pending'" : "CASE WHEN p.state='processing.succeeded' THEN 'item.reused' ELSE 'item.pending' END")
        let vector = !options.vector ? "'item.disabled'" : (options.force ? "'item.pending'" : "CASE WHEN v.data IS NOT NULL THEN 'item.reused' ELSE 'item.pending' END")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try db.execute("BEGIN IMMEDIATE")
        do {
            try db.execute("INSERT INTO background_task(id,root,options,configuration,prompt,state,created) VALUES(?,?,?,?,?,'task.queued',?)", [.text(id), .text(options.root.path), .data(try JSONEncoder().encode(options)), .data(try encoder.encode(configuration)), .text(try RecognitionContract.prompt()), .real(Date().timeIntervalSince1970)])
            try db.execute("INSERT INTO background_item(task_id,photo_id,snapshot,preview_state,ai_state,vector_state,updated) SELECT ?,p.id,p.snapshot,'item.pending'," + ai + "," + vector + ",? FROM background_source p LEFT JOIN photo_vector v ON v.photo_id=p.id AND v.model=? AND v.snapshot=p.snapshot AND v.issue IS NULL" + match.0, [.text(id), .real(Date().timeIntervalSince1970), .text(AIImageVector.model)] + match.1)
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
        return id
    }
    public func tasks() throws -> [BackgroundTaskRecord] {
        let db = try AICatalogDatabase(databaseURL)
        return try db.rows("SELECT t.id,t.root,t.state,t.options,t.configuration,t.created,t.elapsed,t.started,t.issue,count(b.photo_id),sum(b.ai_state IN ('item.succeeded','item.reused','item.disabled','item.failed','task.cancelled','item.blocked') AND b.vector_state IN ('item.succeeded','item.reused','item.disabled','item.failed','task.cancelled','item.blocked')),sum(b.ai_state IN ('item.reused','item.disabled') AND b.vector_state IN ('item.reused','item.disabled')),sum(b.ai_state='item.failed' OR b.vector_state='item.failed' OR b.preview_state='item.failed'),sum(b.preview_state='task.running' OR b.ai_state='task.running' OR b.vector_state='task.running'),sum(b.ai_state IN ('item.succeeded','item.reused')),sum(b.vector_state IN ('item.succeeded','item.reused')),sum(b.ai_state='item.failed'),sum(b.vector_state='item.failed') FROM background_task t LEFT JOIN background_item b ON b.task_id=t.id GROUP BY t.id ORDER BY CASE WHEN t.state IN ('task.running','task.queued','task.pausing') THEN 0 ELSE 1 END,t.created DESC").map { row in
            let options = try JSONDecoder().decode(BackgroundTaskOptions.self, from: row[3].bytes)
            let config = try JSONDecoder().decode(AIModelConfiguration.self, from: row[4].bytes)
            let elapsed = row[6].double + (row[7].double > 0 ? max(0, Date().timeIntervalSince1970 - row[7].double) : 0)
            return BackgroundTaskRecord(id: row[0].string, root: URL(fileURLWithPath: row[1].string), state: BackgroundState(rawValue: row[2].string) ?? .paused,
                ai: options.ai, vector: options.vector, model: config.model, total: Int(row[9].int), done: Int(row[10].int), reused: Int(row[11].int), failed: Int(row[12].int), active: Int(row[13].int), aiDone: Int(row[14].int), vectorDone: Int(row[15].int), aiFailed: Int(row[16].int), vectorFailed: Int(row[17].int), created: Date(timeIntervalSince1970: row[5].double), elapsed: elapsed, issue: row[8].string.isEmpty ? nil : row[8].string)
        }
    }
    public func results(root: URL, taskID: String? = nil, after: Int64 = 0, ai: BackgroundState? = nil, vector: BackgroundState? = nil, failuresOnly: Bool = false, exclusions: [URL] = []) throws -> BackgroundResultPage {
        let db = try AICatalogDatabase(databaseURL)
        let aiSQL = "CASE p.state WHEN 'processing.succeeded' THEN 'item.succeeded' WHEN 'processing.failed' THEN 'item.failed' ELSE 'item.pending' END"
        let vectorSQL = "CASE WHEN v.data IS NOT NULL THEN 'item.succeeded' WHEN v.issue IS NOT NULL THEN 'item.failed' ELSE 'item.pending' END"
        var values: [AIBind] = [.text(AIImageVector.model)]
        var from = " FROM photo p JOIN background_source e ON e.id=p.id LEFT JOIN photo_vector v ON v.photo_id=p.id AND v.model=? AND v.snapshot=p.snapshot LEFT JOIN vector_timestamp vt ON vt.photo_id=v.photo_id"
        var predicate = " WHERE p.id>?", columns = "p.id,p.item,\(aiSQL),\(vectorSQL),'item.pending',NULL,v.issue,NULL,vt.updated,NULL"
        if let taskID {
            from += " JOIN background_item b ON b.photo_id=p.id AND b.task_id=?"; values.append(.text(taskID))
            columns = "p.id,p.item,b.ai_state,b.vector_state,b.preview_state,b.ai_issue,b.vector_issue,b.preview_issue,vt.updated,b.ai_result"
        }
        values.append(.integer(after))
        if taskID == nil {
            let match = try selection(BackgroundTaskOptions(root: root))
            predicate += " AND " + String(match.0.dropFirst(7)).replacingOccurrences(of: "p.eligible", with: "e.eligible"); values += match.1
            let exclusion = AICatalogSQL.exclusion(root: root, directories: exclusions); predicate += exclusion.sql; values += exclusion.values
        }
        if let ai { predicate += " AND \(taskID == nil ? aiSQL : "b.ai_state")=?"; values.append(.text(ai.rawValue)) }
        if let vector { predicate += " AND \(taskID == nil ? vectorSQL : "b.vector_state")=?"; values.append(.text(vector.rawValue)) }
        if failuresOnly { predicate += " AND (\(taskID == nil ? aiSQL : "b.ai_state") IN ('item.failed','item.blocked') OR \(taskID == nil ? vectorSQL : "b.vector_state") IN ('item.failed','item.blocked'))" }
        let rows = try db.rows("SELECT " + columns + from + predicate + " ORDER BY p.id LIMIT 61", values)
        let items = try rows.prefix(60).map { row in
            var item = try JSONDecoder().decode(AICatalogItem.self, from: row[1].bytes)
            if !row[9].bytes.isEmpty { item.metadata = try JSONDecoder().decode(RecognitionMetadata.self, from: row[9].bytes) }
            return BackgroundPhotoResult(row: row[0].int, item: item, ai: BackgroundState(rawValue: row[2].string) ?? .pending,
                vector: BackgroundState(rawValue: row[3].string) ?? .pending, preview: BackgroundState(rawValue: row[4].string) ?? .pending,
                aiIssue: row[5].string.isEmpty ? nil : row[5].string, vectorIssue: row[6].string.isEmpty ? nil : row[6].string, previewIssue: row[7].string.isEmpty ? nil : row[7].string,
                vectorUpdated: row[8].double > 0 ? Date(timeIntervalSince1970: row[8].double) : nil)
        }
        return BackgroundResultPage(items: items, after: items.last?.row, hasMore: rows.count > 60)
    }
    func state(_ id: String, _ state: BackgroundState, issue: String? = nil) throws {
        let db = try AICatalogDatabase(databaseURL, write: true)
        if state == .running {
            try db.execute("UPDATE background_task SET state=?,started=coalesce(started,?),issue=NULL,ai_blocked=0 WHERE id=?", [.text(state.rawValue), .real(Date().timeIntervalSince1970), .text(id)])
        } else {
            try db.execute("UPDATE background_task SET state=?,elapsed=elapsed+CASE WHEN started IS NOT NULL THEN max(0,?-started) ELSE 0 END,started=NULL,issue=? WHERE id=?", [.text(state.rawValue), .real(Date().timeIntervalSince1970), issue.map(AIBind.text) ?? .null, .text(id)])
        }
    }
    func recover() throws {
        let db = try AICatalogDatabase(databaseURL, write: true)
        try db.execute("UPDATE background_task SET state='task.paused',elapsed=elapsed+CASE WHEN started IS NOT NULL THEN max(0,?-started) ELSE 0 END,started=NULL WHERE state IN ('task.queued','task.running','task.pausing')", [.real(Date().timeIntervalSince1970)])
        for column in ["preview_state", "ai_state", "vector_state"] { try db.execute("UPDATE background_item SET \(column)='item.pending' WHERE \(column)='task.running'") }
    }
    func recoverOrphans(_ id: String, active: [BackgroundWork]) throws {
        let db = try AICatalogDatabase(databaseURL, write: true)
        for stage in [BackgroundStage.preview, .ai, .vector] {
            let rows = active.filter { $0.taskID == id && $0.stage == stage }.map(\.row)
            let guardSQL = rows.isEmpty ? "" : " AND photo_id NOT IN (" + Array(repeating: "?", count: rows.count).joined(separator: ",") + ")"
            try db.execute("UPDATE background_item SET \(stage.rawValue)_state='item.pending' WHERE task_id=? AND \(stage.rawValue)_state='task.running'" + guardSQL, [.text(id)] + rows.map(AIBind.integer))
        }
    }
    func retry(_ id: String) throws {
        let db = try AICatalogDatabase(databaseURL, write: true)
        for stage in ["preview", "ai", "vector"] {
            try db.execute("UPDATE background_item SET \(stage)_state='item.pending',\(stage)_issue=NULL WHERE task_id=? AND \(stage)_state IN ('item.failed','task.cancelled','item.blocked')", [.text(id)])
        }
    }
    func cancelPending(_ id: String) throws {
        let db = try AICatalogDatabase(databaseURL, write: true)
        for column in ["preview_state", "ai_state", "vector_state"] {
            try db.execute("UPDATE background_item SET \(column)='task.cancelled' WHERE task_id=? AND \(column)='item.pending'", [.text(id)])
        }
    }
    func claim(_ stage: BackgroundStage) throws -> BackgroundWork? {
        let db = try AICatalogDatabase(databaseURL, write: true), column = stage.rawValue + "_state"
        let readiness = stage == .preview ? " AND ((b.ai_state='item.pending' AND t.ai_blocked=0) OR b.vector_state='item.pending')" : " AND b.preview_state='item.succeeded'" + (stage == .ai ? " AND t.ai_blocked=0" : "")
        let duplicate = stage == .ai ? " AND ot.configuration=t.configuration AND ot.prompt=t.prompt" : ""
        try db.execute("BEGIN IMMEDIATE")
        do {
            var picked: [AIBind]?
            let tasks = try db.rows("SELECT id FROM background_task WHERE state='task.running'" + (stage == .ai ? " AND ai_blocked=0" : "") + " ORDER BY last_pick,created")
            for task in tasks {
                picked = try db.rows("SELECT b.task_id,b.photo_id,b.snapshot,p.item,b.preview_url,t.configuration,t.prompt FROM background_item b JOIN background_task t ON t.id=b.task_id JOIN photo p ON p.id=b.photo_id WHERE b.task_id=? AND b.\(column)='item.pending'" + readiness + " AND NOT EXISTS(SELECT 1 FROM background_item o JOIN background_task ot ON ot.id=o.task_id WHERE o.photo_id=b.photo_id AND o.snapshot=b.snapshot AND o.\(column)='task.running'" + duplicate + ") ORDER BY b.photo_id LIMIT 1", [.text(task[0].string)]).first
                if picked != nil { break }
            }
            let row = picked
            guard let row else { try db.execute("COMMIT"); return nil }
            try db.execute("UPDATE background_item SET \(column)='task.running' WHERE task_id=? AND photo_id=?", [.text(row[0].string), .integer(row[1].int)])
            try db.execute("UPDATE background_task SET last_pick=? WHERE id=?", [.real(Date().timeIntervalSince1970), .text(row[0].string)])
            try db.execute("COMMIT")
            return BackgroundWork(taskID: row[0].string, row: row[1].int, snapshot: row[2].string, item: try JSONDecoder().decode(AICatalogItem.self, from: row[3].bytes), stage: stage,
                preview: row[4].string.isEmpty ? nil : URL(fileURLWithPath: row[4].string), configuration: try JSONDecoder().decode(AIModelConfiguration.self, from: row[5].bytes), prompt: row[6].string)
        } catch { try? db.execute("ROLLBACK"); throw error }
    }
    func reuse(_ work: BackgroundWork) throws -> Bool {
        guard work.stage != .preview else { return false }
        let db = try AICatalogDatabase(databaseURL), column = work.stage.rawValue + "_state"
        return try !db.rows("SELECT 1 FROM background_item b JOIN background_task other ON other.id=b.task_id JOIN background_task current ON current.id=? WHERE b.photo_id=? AND b.snapshot=? AND b.task_id<>current.id AND b.\(column) IN ('item.succeeded','item.reused') AND b.\(work.stage.rawValue)_updated>=current.created" + (work.stage == .ai ? " AND other.configuration=current.configuration AND other.prompt=current.prompt" : "") + " LIMIT 1", [.text(work.taskID), .integer(work.row), .text(work.snapshot)]).isEmpty
    }
    func finish(_ work: BackgroundWork, state: BackgroundState, preview: URL? = nil, data: Data? = nil, metadata: RecognitionMetadata? = nil, issue: String? = nil) throws {
        let db = try AICatalogDatabase(databaseURL, write: true), stage = work.stage.rawValue
        try db.execute("BEGIN IMMEDIATE")
        do {
            let current = try db.rows("SELECT snapshot FROM photo WHERE id=?", [.integer(work.row)]).first?.first?.string
            let valid = current == work.snapshot
            let final = valid ? state : .failed
            let error = valid ? issue : L10n.text("照片已变化，请刷新目录后重新生成。")
            if let metadata, valid, let root = try db.rows("SELECT root FROM background_task WHERE id=?", [.text(work.taskID)]).first?.first?.string {
                let writer = try AICatalogWriter(databaseURL, root: URL(fileURLWithPath: root), connection: db)
                let photo = AICatalogItem(asset: work.item.asset, metadata: metadata, preview: work.preview, state: "processing.succeeded")
                try writer.put(photo, stamp: UUID().uuidString, priority: 30, analysisDate: ISO8601DateFormatter().string(from: Date()), generation: nil)
            }
            if let data, valid {
                try db.execute("INSERT INTO photo_vector(photo_id,snapshot,directory,model,data,issue) SELECT id,snapshot,directory,?,?,NULL FROM photo WHERE id=? AND snapshot=? ON CONFLICT(photo_id) DO UPDATE SET snapshot=excluded.snapshot,directory=excluded.directory,model=excluded.model,data=excluded.data,issue=NULL", [.text(AIImageVector.model), .data(data), .integer(work.row), .text(work.snapshot)])
            }
            if let preview, valid, work.stage == .preview,
               let source = try db.rows("SELECT item FROM photo WHERE id=?", [.integer(work.row)]).first {
                var item = try JSONDecoder().decode(AICatalogItem.self, from: source[0].bytes)
                if item.preview != preview {
                    item.preview = preview
                    try db.execute("UPDATE photo SET item=? WHERE id=? AND snapshot=?", [.data(try JSONEncoder().encode(item)), .integer(work.row), .text(work.snapshot)])
                }
            }
            try db.execute("UPDATE background_item SET \(stage)_state=?,\(stage)_issue=?,preview_url=coalesce(?,preview_url),ai_result=coalesce(?,ai_result),\(stage + "_updated")=?,updated=? WHERE task_id=? AND photo_id=?", [.text(final.rawValue), error.map(AIBind.text) ?? .null, preview.map { .text($0.path) } ?? .null, try metadata.map { .data(try JSONEncoder().encode($0)) } ?? .null, .real(Date().timeIntervalSince1970), .real(Date().timeIntervalSince1970), .text(work.taskID), .integer(work.row)])
            if work.stage == .preview, final == .failed {
                for column in ["ai_state", "vector_state"] { try db.execute("UPDATE background_item SET \(column)='item.blocked' WHERE task_id=? AND photo_id=? AND \(column)='item.pending'", [.text(work.taskID), .integer(work.row)]) }
            }
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
    }
    func settle() throws {
        let db = try AICatalogDatabase(databaseURL, write: true)
        for row in try db.rows("SELECT id,state,ai_blocked,issue FROM background_task WHERE state IN ('task.running','task.pausing')") {
            let id = row[0].string, issue = row[3].string.isEmpty ? nil : row[3].string
            func exists(_ column: String, _ states: String) throws -> Bool {
                try !db.rows("SELECT 1 FROM background_item WHERE task_id=? AND \(column) IN (" + states + ") LIMIT 1", [.text(id)]).isEmpty
            }
            let active = try exists("preview_state", "'task.running'") || exists("ai_state", "'task.running'") || exists("vector_state", "'task.running'")
            if row[1].string == BackgroundState.pausing.rawValue && !active { try state(id, .paused, issue: issue); continue }
            let aiPending = try exists("ai_state", "'item.pending'")
            let vectorPending = try exists("vector_state", "'item.pending'")
            if !active && !aiPending && !vectorPending {
                let failed = try exists("preview_state", "'item.failed'") || exists("ai_state", "'item.failed'") || exists("vector_state", "'item.failed'")
                try state(id, failed ? .errors : .completed)
            } else if row[2].int == 1 && !active && !vectorPending { try state(id, .paused, issue: issue) }
        }
    }
    func taskState(_ id: String) throws -> BackgroundState? {
        try AICatalogDatabase(databaseURL).rows("SELECT state FROM background_task WHERE id=?", [.text(id)]).first.flatMap { BackgroundState(rawValue: $0[0].string) }
    }
    func taskRoot(_ id: String) throws -> URL? {
        try AICatalogDatabase(databaseURL).rows("SELECT root FROM background_task WHERE id=?", [.text(id)]).first.map { URL(fileURLWithPath: $0[0].string) }
    }
    func blockAI(_ id: String, issue: String) throws {
        try AICatalogDatabase(databaseURL, write: true).execute("UPDATE background_task SET ai_blocked=1,issue=? WHERE id=?", [.text(issue), .text(id)])
    }
}
