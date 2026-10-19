import Foundation
import SQLite3

enum AIBind: Sendable {
    case text(String), integer(Int64), real(Double), data(Data), null
    var string: String { if case .text(let value) = self { return value }; return "" }
    var int: Int64 { if case .integer(let value) = self { return value }; return 0 }
    var double: Double { if case .real(let value) = self { return value }; return Double(int) }
    var bytes: Data { if case .data(let value) = self { return value }; return Data() }
}

/// One connection per operation. Writers use WAL; cancelled readers never interrupt another query.
final class AICatalogDatabase {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    init(_ url: URL, write: Bool = false) throws {
        let flags = write ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        let code = sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK else { let failure = error(); sqlite3_close(handle); handle = nil; throw failure }
        sqlite3_busy_timeout(handle, 1500)
        sqlite3_progress_handler(handle, 1000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
        if write { try execute("PRAGMA journal_mode=WAL"); try execute("PRAGMA synchronous=NORMAL") }
        try execute("PRAGMA cache_size=-32768")
    }
    deinit { for value in statements.values { sqlite3_finalize(value) }; sqlite3_close(handle) }
    private func statement(_ sql: String, _ values: [AIBind]) throws -> OpaquePointer {
        try Task.checkCancellation()
        let statement: OpaquePointer
        if let saved = statements[sql] { statement = saved; sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        else {
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw error() }
            statement = pointer; statements[sql] = pointer
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .null: result = sqlite3_bind_null(statement, index)
            case .data(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            }
            guard result == SQLITE_OK else { throw error() }
        }
        return statement
    }
    func execute(_ sql: String, _ values: [AIBind] = []) throws { _ = try rows(sql, values) }
    func rows(_ sql: String, _ values: [AIBind] = []) throws -> [[AIBind]] {
        let statement = try statement(sql, values)
        defer { sqlite3_reset(statement) }
        var result: [[AIBind]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { try Task.checkCancellation(); throw error() }
            var row: [AIBind] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, column))))
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_BLOB:
                    let size = Int(sqlite3_column_bytes(statement, column))
                    row.append(.data(size == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column)!, count: size)))
                default: row.append(.null)
                }
            }
            result.append(row)
        }
    }
    func error() -> Error {
        BrowserFailure.message(L10n.text("AI 分类索引错误：\(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed")"))
    }
    static func create(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try Self(url, write: true)
        for sql in schema { try db.execute(sql) }
    }
    private static let schema = [
        "CREATE TABLE IF NOT EXISTS catalog_info(version INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS known_asset(key TEXT PRIMARY KEY,directory TEXT NOT NULL,asset BLOB NOT NULL)",
        "CREATE INDEX IF NOT EXISTS known_asset_directory ON known_asset(directory)",
        "CREATE TABLE IF NOT EXISTS source(path TEXT PRIMARY KEY,stamp TEXT NOT NULL,photo_id INTEGER NOT NULL)",
        "INSERT INTO catalog_info SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM catalog_info)",
        "CREATE TABLE IF NOT EXISTS photo(id INTEGER PRIMARY KEY,key TEXT UNIQUE NOT NULL,directory TEXT NOT NULL,item BLOB NOT NULL,state TEXT NOT NULL,search TEXT NOT NULL,date REAL NOT NULL,snapshot TEXT NOT NULL,stamp TEXT NOT NULL,priority INTEGER NOT NULL,analysis_date TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS term(id INTEGER PRIMARY KEY,field TEXT NOT NULL,code TEXT NOT NULL,name TEXT NOT NULL,UNIQUE(field,code))",
        "CREATE INDEX IF NOT EXISTS term_field ON term(field,id)",
        "CREATE TABLE IF NOT EXISTS photo_term(term_id INTEGER,photo_id INTEGER,PRIMARY KEY(term_id,photo_id)) WITHOUT ROWID",
        "CREATE INDEX IF NOT EXISTS photo_term_reverse ON photo_term(photo_id,term_id)",
        "CREATE TABLE IF NOT EXISTS scope(id TEXT PRIMARY KEY,root TEXT NOT NULL,complete INTEGER NOT NULL DEFAULT 0,updated REAL,revision INTEGER NOT NULL DEFAULT 0)",
        "CREATE TABLE IF NOT EXISTS member(scope_id TEXT,photo_id INTEGER,date REAL NOT NULL,generation TEXT NOT NULL,PRIMARY KEY(scope_id,date DESC,photo_id DESC)) WITHOUT ROWID",
        "CREATE UNIQUE INDEX IF NOT EXISTS member_identity ON member(scope_id,photo_id)",
        "CREATE INDEX IF NOT EXISTS member_photo ON member(photo_id)",
        "CREATE TABLE IF NOT EXISTS photo_vector(photo_id INTEGER PRIMARY KEY,snapshot TEXT NOT NULL,directory TEXT NOT NULL,model TEXT NOT NULL,data BLOB,issue TEXT)",
        "CREATE TABLE IF NOT EXISTS visual_revision(id INTEGER PRIMARY KEY,revision INTEGER NOT NULL)",
        "INSERT OR IGNORE INTO visual_revision VALUES(1,0)",
        "CREATE TRIGGER IF NOT EXISTS visual_insert AFTER INSERT ON photo_vector BEGIN UPDATE visual_revision SET revision=revision+1 WHERE id=1; END",
        "CREATE TRIGGER IF NOT EXISTS visual_update AFTER UPDATE ON photo_vector BEGIN UPDATE visual_revision SET revision=revision+1 WHERE id=1; END",
        "CREATE TRIGGER IF NOT EXISTS visual_delete AFTER DELETE ON photo_vector BEGIN UPDATE visual_revision SET revision=revision+1 WHERE id=1; END",
        "CREATE TRIGGER IF NOT EXISTS photo_vector_changed AFTER UPDATE OF snapshot,directory ON photo WHEN OLD.snapshot<>NEW.snapshot OR OLD.directory<>NEW.directory BEGIN DELETE FROM photo_vector WHERE photo_id=NEW.id; END",
        "CREATE TRIGGER IF NOT EXISTS photo_vector_removed AFTER DELETE ON photo BEGIN DELETE FROM photo_vector WHERE photo_id=OLD.id; END"
    ]
}
