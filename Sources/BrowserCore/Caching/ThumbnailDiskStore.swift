import Foundation

public struct ThumbnailDiskUsage: Sendable {
    public let bytes: Int64
    public let entries: Int
    public let limit: Int64
}

/// Local cache files only. Generation fencing makes clear safe against in-flight decoders.
final class ThumbnailDiskStore: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var generation = UUID()
    private var versions: [String: UUID] = [:]
    private var accesses: [String: Date] = [:]
    private var loadedAccesses = false
    private var limit: Int64
    init(directory: URL, limit: Int64) { self.directory = directory; self.limit = max(0, limit) }
    func token(_ key: String) -> UUID { lock.lock(); defer { lock.unlock() }; return versions[key] ?? generation }
    func touch(_ key: String) { lock.lock(); defer { lock.unlock() }; accesses[key] = Date() }
    func setLimit(_ value: Int64) { lock.lock(); defer { lock.unlock() }; limit = max(0, value) }
    func read<T>(_ work: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try work() }
    func write(_ data: Data, key: String, suffix: String, token: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard (versions[key] ?? generation) == token else { throw CancellationError() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(key + suffix), options: .atomic)
        accesses[key] = Date()
    }
    private struct Entry {
        let url: URL
        let key: String
        let bytes: Int64
        let modified: Date
    }
    private func entries() throws -> [Entry] {
        let fm = FileManager.default
        let urls: [URL]
        do { urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return try urls.compactMap { url in
            let key = url.deletingPathExtension().lastPathComponent
            guard ["jpg", "json"].contains(url.pathExtension), key.count == 64,
                  key.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return Entry(url: url, key: key, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
        }
    }
    private func loadAccesses() throws {
        guard !loadedAccesses else { return }
        let data: Data
        do { data = try Data(contentsOf: directory.appendingPathComponent("Accesses.json")) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { loadedAccesses = true; return }
        do {
            let saved = try JSONDecoder().decode([String: Date].self, from: data)
            accesses.merge(saved, uniquingKeysWith: max)
        } catch is DecodingError { /* A damaged LRU index can be rebuilt from cache modification times. */ }
        loadedAccesses = true
    }
    func usage() throws -> ThumbnailDiskUsage {
        lock.lock(); defer { lock.unlock() }
        let files = try entries()
        return ThumbnailDiskUsage(bytes: files.reduce(0) { $0 + $1.bytes }, entries: files.filter { $0.url.pathExtension == "jpg" }.count, limit: limit)
    }
    func trim(protecting: Set<String>, check: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try check(); try loadAccesses()
        let files = try entries(), grouped = Dictionary(grouping: files, by: \.key)
        var bytes = files.reduce(Int64(0)) { $0 + $1.bytes }
        let ordered = grouped.keys.sorted {
            let a = accesses[$0] ?? grouped[$0]!.map(\.modified).max()!
            let b = accesses[$1] ?? grouped[$1]!.map(\.modified).max()!
            return a == b ? $0 < $1 : a < b
        }
        var retained = Set(grouped.keys)
        for key in ordered where bytes > limit && !protecting.contains(key) {
            try check()
            for file in grouped[key]! { try FileManager.default.removeItem(at: file.url); bytes -= file.bytes }
            retained.remove(key)
        }
        accesses = accesses.filter { retained.contains($0.key) }
        if !files.isEmpty {
            try JSONEncoder().encode(accesses).write(to: directory.appendingPathComponent("Accesses.json"), options: .atomic)
        }
    }
    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); versions.removeAll()
        for entry in try entries() { try FileManager.default.removeItem(at: entry.url) }
        let index = directory.appendingPathComponent("Accesses.json")
        if FileManager.default.fileExists(atPath: index.path) { try FileManager.default.removeItem(at: index) }
        accesses = [:]; loadedAccesses = true
    }
    func persistAccesses() throws {
        lock.lock(); defer { lock.unlock() }
        try loadAccesses()
        guard !accesses.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(accesses).write(to: directory.appendingPathComponent("Accesses.json"), options: .atomic)
    }
    func invalidate(_ keys: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        for key in keys { versions[key] = UUID(); accesses.removeValue(forKey: key) }
        for key in keys {
            for suffix in [".jpg", ".json"] {
                let url = directory.appendingPathComponent(key + suffix)
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values.isRegularFile == true, values.isSymbolicLink != true { try FileManager.default.removeItem(at: url) }
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { continue }
            }
        }
    }
}
