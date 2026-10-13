import Foundation

/// Folder traversal uses its own serial utility lane, leaving image workers available.
public final class FolderSizeCache: @unchecked Sendable {
    public static let shared = FolderSizeCache()
    private let workers: PreviewWorkQueue
    private let lifetime: TimeInterval
    private let entries = NSCache<NSURL, Entry>()

    private final class Entry: NSObject {
        let bytes: Int64
        let modified: Date?
        let expires: Date
        init(bytes: Int64, modified: Date?, expires: Date) {
            self.bytes = bytes; self.modified = modified; self.expires = expires
        }
    }

    public init(lifetime: TimeInterval = 60, workers: PreviewWorkQueue = PreviewWorkQueue()) {
        self.lifetime = lifetime; self.workers = workers
        entries.countLimit = 512
    }

    public func size(of url: URL) async throws -> Int64 {
        try await workers.run(background: true) { [self] check in
            var freshURL = url
            freshURL.removeAllCachedResourceValues()
            let values = try freshURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            let key = url.standardizedFileURL as NSURL
            if let entry = entries.object(forKey: key), entry.expires > Date(),
               entry.modified == values.contentModificationDate { return entry.bytes }
            let bytes = try Self.measure(url, check: check)
            try check()
            entries.setObject(Entry(bytes: bytes, modified: values.contentModificationDate,
                                   expires: Date().addingTimeInterval(lifetime)), forKey: key)
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
