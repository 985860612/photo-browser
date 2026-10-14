import Foundation

/// Folder traversal uses its own serial utility lane, leaving image workers available.
public final class FolderSizeCache: @unchecked Sendable {
    public static let shared = FolderSizeCache()
    private let workers: PreviewWorkQueue
    private let lifetime: TimeInterval
    private let checkInterval: TimeInterval
    private let storage: FolderCacheStorage<Int64>
    private let local = PreviewWorkQueue()

    public init(directory: URL? = nil, lifetime: TimeInterval = 6 * 3600, checkInterval: TimeInterval = 300,
                workers: PreviewWorkQueue = PreviewWorkQueue()) {
        self.lifetime = lifetime; self.workers = workers; self.checkInterval = checkInterval
        storage = FolderCacheStorage(directory: directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoBrowser/FolderSizes", isDirectory: true))
    }
    public func cached(of url: URL) async throws -> CachedFolderValue<Int64>? {
        try await local.run { [storage] _ in try storage.read(url)?.snapshot }
    }
    public func invalidate(_ urls: [URL], descendants: Bool = false) async throws {
        try await local.run { [storage] _ in try storage.invalidate(urls, descendants: descendants) }
    }

    public func size(of url: URL) async throws -> Int64 {
        try await workers.run(background: true) { [self] cancelled in
            let token = storage.token(url)
            let check = { try cancelled(); try self.storage.check(url, token: token) }
            let record: (snapshot: CachedFolderValue<Int64>, modified: Date?)?
            do { record = try storage.read(url) }
            catch is DecodingError { record = nil }
            let fresh = record.map { let age = Date().timeIntervalSince($0.snapshot.computedAt); return age >= 0 && age < lifetime } ?? false
            if fresh, storage.recentlyChecked(url, interval: checkInterval), let record { try check(); return record.snapshot.value }
            let modified = try folderModification(url)
            if fresh, let record, record.modified == modified {
                try storage.markChecked(url, token: token); return record.snapshot.value
            }
            let bytes = try Self.measure(url, check: check)
            try check()
            try storage.write(bytes, for: url, modified: modified, token: token)
            return bytes
        }
    }

    /// Sum file lengths, including sidecars and hidden files. Never follow symbolic links.
    private static func measure(_ url: URL, check: () throws -> Void) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in traversalError = error; return false }) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        var bytes: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            try check()
            let values = try file.resourceValues(forKeys: keys)
            // DirectoryEnumerator does not descend into links; skipDescendants on a file
            // can skip the next sibling directory instead.
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            guard let size = values.fileSize else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
            bytes += Int64(size)
        }
        if let traversalError { throw traversalError }
        return bytes
    }
}
