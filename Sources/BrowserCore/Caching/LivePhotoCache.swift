import Foundation

/// Bounded local original-member cache. Per-archive locks share extraction without serializing NAS reads.
public final class LivePhotoCache: @unchecked Sendable {
    public static let shared = LivePhotoCache()
    public struct Usage: Sendable { public let bytes: Int64; public let limit: Int64 }
    private struct Entry { let bytes: Int64; var touched: Date }
    private let directory: URL
    private let limit: Int64
    private let state = NSLock()
    private var gates: [String: NSLock] = [:]
    private var entries: [URL: Entry] = [:]
    private var components: [String: URL] = [:]
    private var members: [String: LivePhotoArchive.Members] = [:]
    private var pins: [URL: Int] = [:]
    private var bytes: Int64 = 0
    private var generation = UUID()
    private var indexed = false

    public init(directory: URL? = nil, limit: Int64 = 1_000_000_000) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoBrowser/LivePhotos")
        self.limit = max(0, limit)
    }
    private func locked<T>(_ work: () throws -> T) rethrows -> T { state.lock(); defer { state.unlock() }; return try work() }
    private func key(_ file: PhotoFile) -> String { ThumbnailCache.digest("livp-v1|\(file.id)|\(file.size)|\(file.modified.timeIntervalSince1970)") }
    private func ensureIndex() throws {
        guard !indexed else { return }
        let fm = FileManager.default
        var rebuilt: [URL: Entry] = [:], total: Int64 = 0
        if fm.fileExists(atPath: directory.path) {
            for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) {
                guard recognized(url) else { continue }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let entry = Entry(bytes: Int64(values.fileSize ?? 0), touched: values.contentModificationDate ?? .distantPast)
                rebuilt[url] = entry; total += entry.bytes
            }
        }
        entries = rebuilt; bytes = total
        components = Dictionary(rebuilt.keys.map { (componentKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        indexed = true
        try trim(to: limit)
    }
    private func componentKey(_ url: URL) -> String {
        String(url.lastPathComponent.prefix(64)) + (url.lastPathComponent.contains("-motion.") ? "|motion" : "|photo")
    }
    private func recognized(_ url: URL) -> Bool {
        let name = url.lastPathComponent, hash = name.prefix(64)
        return hash.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && ((name.dropFirst(64).hasPrefix("-photo.") && DirectoryScanner.renderedExtensions.subtracting(["livp"]).contains(url.pathExtension)) || name.dropFirst(64) == "-motion.mov")
    }

    public func photoData(_ file: PhotoFile, check: () throws -> Void = {}) throws -> Data {
        let url = try component(file, movie: false, check: check)
        defer { unpin(url) }
        try check(); let data = try Data(contentsOf: url); try check(); return data
    }
    public func movie(_ file: PhotoFile, check: () throws -> Void = {}) throws -> LivePhotoMovie {
        let url = try component(file, movie: true, check: check)
        return LivePhotoMovie(url: url, cache: self)
    }
    private func component(_ file: PhotoFile, movie: Bool, check: () throws -> Void) throws -> URL {
        try check()
        let key = key(file), gate = locked { () -> NSLock in
            if let gate = gates[key] { return gate }
            let gate = NSLock(); gates[key] = gate; return gate
        }
        gate.lock(); defer { gate.unlock() }; try check()
        let ticket = locked { generation }
        if let cached = try locked({ () throws -> URL? in
            try ensureIndex()
            let id = key + (movie ? "|motion" : "|photo")
            guard let url = components[id] else { return nil }
            if FileManager.default.fileExists(atPath: url.path) {
                entries[url]?.touched = Date(); pins[url, default: 0] += 1; return url
            }
            if let old = entries.removeValue(forKey: url) { bytes -= old.bytes }
            components.removeValue(forKey: id)
            return nil
        }) { return cached }
        let known = locked { members[key] }
        let names = try known ?? LivePhotoArchive.members(file.url, check: check)
        let member: String
        if movie {
            guard let name = names.movie else { throw BrowserFailure.message(L10n.text("此 LIVP 没有可播放的实况视频。")) }
            member = name
        } else { member = names.photo }
        let suffix = movie ? "-motion.mov" : "-photo." + URL(fileURLWithPath: member).pathExtension.lowercased()
        let url = directory.appendingPathComponent(key + suffix)
        if try locked({ () throws -> Bool in
            try ensureIndex()
            if entries[url] != nil, FileManager.default.fileExists(atPath: url.path) {
                entries[url]?.touched = Date(); pins[url, default: 0] += 1; members[key] = names; return true
            }
            return false
        }) { return url }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".extract-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw BrowserFailure.message(L10n.text("无法创建 LIVP 本地缓存。")) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let ceiling = min(limit, movie ? 1_000_000_000 : 64 * 1024 * 1024)
        try LivePhotoArchive.extract(file.url, member: member, to: temporary, limit: Int(ceiling), check: check)
        try check()
        return try locked {
            guard generation == ticket else { throw CancellationError() }
            let size = Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            try trim(to: max(0, limit - size))
            guard bytes + size <= limit else { throw BrowserFailure.message(L10n.text("LIVP 缓存已满，请停止其他实况播放后重试。")) }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.moveItem(at: temporary, to: url)
            if let old = entries[url] { bytes -= old.bytes }
            entries[url] = Entry(bytes: size, touched: Date()); bytes += size
            components[componentKey(url)] = url
            members[key] = names; pins[url, default: 0] += 1
            return url
        }
    }
    private func trim(to target: Int64) throws {
        guard bytes > target else { return }
        let candidates = entries.filter { pins[$0.key, default: 0] == 0 }.sorted { $0.value.touched < $1.value.touched }
        for (url, entry) in candidates {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            entries.removeValue(forKey: url); components.removeValue(forKey: componentKey(url)); bytes -= entry.bytes
            if bytes <= target { break }
        }
    }
    fileprivate func unpin(_ url: URL) { locked { pins[url] = max(0, pins[url, default: 0] - 1) } }
    public func usage() throws -> Usage { try locked { try ensureIndex(); return Usage(bytes: bytes, limit: limit) } }
    public func clear() throws {
        try locked {
            generation = UUID(); members.removeAll(); try ensureIndex()
            try trim(to: 0) // Active movie leases remain usable until playback stops.
        }
    }
}

public final class LivePhotoMovie: @unchecked Sendable {
    public let url: URL
    private let cache: LivePhotoCache
    fileprivate init(url: URL, cache: LivePhotoCache) { self.url = url; self.cache = cache }
    deinit { cache.unpin(url) }
}
