import Foundation

public struct FolderSummary: Codable, Sendable {
    public let count: Int
    public let cover: PhotoFile?
}

/// Directory listings use one utility lane. Saved summaries load independently
/// from local disk, without touching the NAS or waiting for a remote scan.
public final class FolderSummaryCache: @unchecked Sendable {
    public static let shared = FolderSummaryCache()
    private let storage: FolderCacheStorage<FolderSummary>
    private let workers: PreviewWorkQueue
    private let local = PreviewWorkQueue()
    private let lifetime: TimeInterval
    private let checkInterval: TimeInterval

    public init(directory: URL? = nil, lifetime: TimeInterval = 24 * 3600, checkInterval: TimeInterval = 300,
                workers: PreviewWorkQueue = PreviewWorkQueue()) {
        storage = FolderCacheStorage(directory: directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoBrowser/FolderSummaries", isDirectory: true))
        self.workers = workers; self.lifetime = lifetime; self.checkInterval = checkInterval
    }
    public func cached(of url: URL) async throws -> CachedFolderValue<FolderSummary>? {
        try await local.run { [storage] _ in try storage.read(url)?.snapshot }
    }
    public func invalidate(_ urls: [URL], descendants: Bool = false) async throws {
        try await local.run { [storage] _ in try storage.invalidate(urls, descendants: descendants) }
    }
    public func summary(of url: URL) async throws -> FolderSummary {
        try await workers.run(background: true) { [self] cancelled in
            let token = storage.token(url)
            let check = { try cancelled(); try self.storage.check(url, token: token) }
            let record: (snapshot: CachedFolderValue<FolderSummary>, modified: Date?)?
            do { record = try storage.read(url) }
            catch is DecodingError { record = nil } // The card reports damaged saved data before rebuilding it.
            let fresh = record.map { let age = Date().timeIntervalSince($0.snapshot.computedAt); return age >= 0 && age < lifetime } ?? false
            if fresh, storage.recentlyChecked(url, interval: checkInterval), let record { try check(); return record.snapshot.value }
            let modified = try folderModification(url)
            if fresh, let record, record.modified == modified {
                let cover = record.snapshot.value.cover
                var unchanged = true
                if var fileURL = cover?.url {
                    fileURL.removeAllCachedResourceValues()
                    do {
                        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                        unchanged = values.isRegularFile == true && values.isSymbolicLink != true && Int64(values.fileSize ?? -1) == cover?.size
                            && values.contentModificationDate == cover?.modified
                    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                        unchanged = false
                    }
                }
                if unchanged { try storage.markChecked(url, token: token); return record.snapshot.value }
            }
            let files = try FileManager.default.contentsOfDirectory(at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            var images: [PhotoFile] = []
            let extensions = DirectoryScanner.rawExtensions.union(DirectoryScanner.renderedExtensions)
            for file in files where extensions.contains(file.pathExtension.lowercased()) {
                try check()
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                images.append(PhotoFile(url: file, kind: DirectoryScanner.rawExtensions.contains(file.pathExtension.lowercased()) ? .raw : .rendered,
                                        size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
            }
            images.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            let count = Set(images.map { $0.url.deletingPathExtension().lastPathComponent.lowercased() }).count
            let result = FolderSummary(count: count, cover: images.first { $0.kind == .rendered } ?? images.first)
            try check(); try storage.write(result, for: url, modified: modified, token: token)
            return result
        }
    }
}
