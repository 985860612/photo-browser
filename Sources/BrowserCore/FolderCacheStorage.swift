import Foundation

public struct CachedFolderValue<Value: Codable & Sendable>: Codable, Sendable {
    public let value: Value
    public let computedAt: Date
}

/// Local JSON and RAM only. The lock also prevents obsolete scans from publishing
/// after a move or explicit refresh invalidates their generation.
final class FolderCacheStorage<Value: Codable & Sendable>: @unchecked Sendable {
    private struct Record: Codable {
        let version: Int
        let path: String
        let modified: Date?
        let snapshot: CachedFolderValue<Value>
    }
    private final class Entry: NSObject {
        let record: Record
        init(_ record: Record) { self.record = record }
    }
    private let directory: URL
    private let lock = NSLock()
    private let memory = NSCache<NSString, Entry>()
    private var generations: [String: UUID] = [:]
    private var checked: [String: Date] = [:]
    private var invalidated: Set<String> = []

    init(directory: URL) { self.directory = directory; memory.countLimit = 512 }
    static func path(_ url: URL) -> String { url.standardizedFileURL.path }
    private func file(_ path: String) -> URL { directory.appendingPathComponent(ThumbnailCache.digest(path) + ".json") }

    func token(_ url: URL) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let path = Self.path(url)
        if let token = generations[path] { return token }
        let token = UUID(); generations[path] = token; return token
    }
    func check(_ url: URL, token: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if generations[Self.path(url)] != token { throw CancellationError() }
    }
    func recentlyChecked(_ url: URL, interval: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return checked[Self.path(url)].map {
            let age = Date().timeIntervalSince($0); return age >= 0 && age < interval
        } ?? false
    }
    func markChecked(_ url: URL, token: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let path = Self.path(url)
        guard generations[path] == token else { throw CancellationError() }
        checked[path] = Date()
    }
    func read(_ url: URL) throws -> (snapshot: CachedFolderValue<Value>, modified: Date?)? {
        lock.lock(); defer { lock.unlock() }
        let path = Self.path(url)
        if invalidated.contains(path) { return nil }
        if let entry = memory.object(forKey: path as NSString) { return (entry.record.snapshot, entry.record.modified) }
        let bytes: Data
        do { bytes = try Data(contentsOf: file(path)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let record = try JSONDecoder().decode(Record.self, from: bytes)
        guard record.version == 1, record.path == path else { return nil }
        memory.setObject(Entry(record), forKey: path as NSString)
        return (record.snapshot, record.modified)
    }
    func write(_ value: Value, for url: URL, modified: Date?, token: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let path = Self.path(url)
        guard generations[path] == token else { throw CancellationError() }
        let record = Record(version: 1, path: path, modified: modified,
                            snapshot: CachedFolderValue(value: value, computedAt: Date()))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: file(path), options: .atomic)
        invalidated.remove(path)
        memory.setObject(Entry(record), forKey: path as NSString); checked[path] = Date()
    }

    /// Invalidate changed directories and their ancestors; refresh may include descendants.
    func invalidate(_ urls: [URL], descendants: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let roots = urls.map(Self.path)
        func matches(_ path: String) -> Bool {
            roots.contains { root in path == root || root.hasPrefix(path == "/" ? "/" : path + "/")
                || (descendants && path.hasPrefix(root == "/" ? "/" : root + "/")) }
        }
        for path in generations.keys.filter(matches) {
            invalidated.insert(path)
            generations[path] = UUID(); checked.removeValue(forKey: path); memory.removeObject(forKey: path as NSString)
        }
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        for url in files where url.pathExtension == "json" {
            let record: Record
            do { record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url)) }
            catch is DecodingError { try FileManager.default.removeItem(at: url); continue }
            if matches(record.path) {
                invalidated.insert(record.path)
                memory.removeObject(forKey: record.path as NSString); checked.removeValue(forKey: record.path)
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

func folderModification(_ url: URL) throws -> Date? {
    var fresh = url; fresh.removeAllCachedResourceValues()
    let values = try fresh.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    return values.contentModificationDate
}
