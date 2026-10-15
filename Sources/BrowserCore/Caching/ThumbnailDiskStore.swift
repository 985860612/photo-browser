import Foundation

public struct ThumbnailDiskUsage: Sendable {
    public let bytes: Int64
    public let entries: Int
    public let limit: Int64
}

/// Local files only. Short state locking keeps RAM hits independent of maintenance I/O.
final class ThumbnailDiskStore: @unchecked Sendable {
    let directory: URL
    private let stateLock = NSLock()
    private let ioLock = NSLock()
    private var generation = UUID()
    private var versions: [String: UUID] = [:]
    private var accesses: [String: Date] = [:]
    private var loadedAccesses = false
    private var accessRevision = 0
    private var persistedRevision = -1
    private var lastPersisted = Date.distantPast
    private var limit: Int64
    private var index: ThumbnailDiskIndex

    init(directory: URL, limit: Int64) {
        self.directory = directory; self.limit = max(0, limit)
        index = ThumbnailDiskIndex(directory: directory)
    }
    private func state<T>(_ work: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }; return work()
    }
    private func io<T>(_ work: () throws -> T) rethrows -> T {
        ioLock.lock(); defer { ioLock.unlock() }; return try work()
    }
    func token(_ key: String) -> UUID { state { versions[key] ?? generation } }
    func touch(_ key: String) { state { accesses[key] = Date(); accessRevision += 1 } }
    func setLimit(_ value: Int64) { state { limit = max(0, value) } }
    func read<T>(_ work: () throws -> T) rethrows -> T { try io(work) }

    func write(_ data: Data, key: String, suffix: String, token: UUID) throws {
        try io {
            guard self.token(key) == token else { throw CancellationError() }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(key + suffix), options: .atomic)
            }
            catch { index.invalidate(); throw error }
            index.written(data, key: key, suffix: suffix)
            touch(key)
        }
    }

    /// Called on the I/O lane; initial JSON reading/decoding never holds the state lock.
    private func loadAccesses() throws {
        guard !state({ loadedAccesses }) else { return }
        let saved: [String: Date]
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("Accesses.json"))
            do { saved = try JSONDecoder().decode([String: Date].self, from: data) }
            catch is DecodingError { saved = [:] }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { saved = [:] }
        state { accesses.merge(saved, uniquingKeysWith: max); loadedAccesses = true }
    }

    func usage() throws -> ThumbnailDiskUsage {
        try io {
            try index.ensureLoaded()
            return ThumbnailDiskUsage(bytes: index.bytes, entries: index.images, limit: state { limit })
        }
    }

    private struct Candidate {
        let key: String
        let group: ThumbnailDiskIndex.Group
        let access: Date?
        var rank: Date { access ?? group.modified }
    }

    func trim(protecting: Set<String>, check: () throws -> Void) throws {
        let snapshot: (UUID, [Candidate]) = try io {
            try check(); try index.ensureLoaded()
            let settings = state { (generation, limit) }
            // No grouping, sorting, or full scan on the normal under-quota path.
            guard index.bytes > settings.1 else { return (settings.0, []) }
            try loadAccesses()
            let dates = state { accesses }
            return (settings.0, index.groups.map { Candidate(key: $0.key, group: $0.value, access: dates[$0.key]) })
        }
        // Ranking can be expensive for a large cache, so do it outside both locks.
        let ordered = snapshot.1.sorted { $0.rank == $1.rank ? $0.key < $1.key : $0.rank < $1.rank }
        for candidate in ordered where !protecting.contains(candidate.key) {
            try check()
            let underQuota = try io { () -> Bool in
                let settings = state { (generation, limit, accesses[candidate.key]) }
                guard settings.0 == snapshot.0 else { throw CancellationError() }
                if index.bytes <= settings.1 { return true }
                // Do not remove a key touched or rewritten while ranking was in progress.
                guard settings.2 == candidate.access, index.groups[candidate.key]?.revision == candidate.group.revision else { return false }
                state { accesses.removeValue(forKey: candidate.key); accessRevision += 1 }
                do {
                    for file in candidate.group.files.values { try removeRegular(file.url, key: candidate.key) }
                } catch { index.invalidate(); throw error }
                return index.bytes <= state { limit }
            }
            if underQuota { break }
        }
        try persistAccesses(force: false)
    }

    private func removeRegular(_ url: URL, key: String) throws {
        var fresh = url; fresh.removeAllCachedResourceValues()
        do {
            let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true { try FileManager.default.removeItem(at: fresh) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { /* Already removed externally. */ }
        index.removed(key: key, suffix: url.pathExtension)
    }

    func clear() throws {
        try io {
            state {
                generation = UUID(); versions = [:]; accesses = [:]; loadedAccesses = true
                accessRevision += 1; persistedRevision = accessRevision; lastPersisted = .distantPast
            }
            do {
                // Explicit clear reconciles first, including externally added cache files.
                try index.ensureLoaded(force: true)
                let groups = index.groups
                for (key, group) in groups { for file in group.files.values { try removeRegular(file.url, key: key) } }
                let url = directory.appendingPathComponent("Accesses.json")
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                index.reset()
            } catch { index.invalidate(); throw error }
        }
    }

    func persistAccesses(force: Bool = true) throws {
        guard state({ force || (accessRevision != persistedRevision && Date().timeIntervalSince(lastPersisted) >= 30) }) else { return }
        try io { try loadAccesses() }
        let snapshot = state { (generation, accesses, accessRevision) }
        // Encoding a large LRU dictionary does not delay lookups or pixel-cache reads.
        let data = try JSONEncoder().encode(snapshot.1)
        try io {
            guard state({ generation == snapshot.0 && snapshot.2 >= persistedRevision }) else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("Accesses.json"), options: .atomic)
            state { persistedRevision = snapshot.2; lastPersisted = Date() }
        }
    }

    func invalidate(_ keys: Set<String>) throws {
        try io {
            state { for key in keys { versions[key] = UUID(); accesses.removeValue(forKey: key) }; accessRevision += 1 }
            do {
                for key in keys { for suffix in [".jpg", ".json"] { try removeRegular(directory.appendingPathComponent(key + suffix), key: key) } }
            } catch { index.invalidate(); throw error }
        }
    }
}
