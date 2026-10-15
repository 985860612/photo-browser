import Foundation

/// Owned by ThumbnailDiskStore's I/O lane. Scan once, then account for our own writes/removals.
struct ThumbnailDiskIndex {
    struct File {
        let url: URL
        let key: String
        let bytes: Int64
        let modified: Date
    }
    struct Group {
        var files: [String: File] = [:]
        var revision = UUID()
        var modified: Date { files.values.map(\.modified).max() ?? .distantPast }
    }
    let directory: URL
    private(set) var groups: [String: Group] = [:]
    private(set) var bytes: Int64 = 0
    private(set) var images = 0
    private var loadedAt: Date?

    init(directory: URL) { self.directory = directory }

    mutating func ensureLoaded(force: Bool = false) throws {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 300 { return }
        // Build separately so a failed reconciliation cannot publish partial statistics.
        var rebuilt = ThumbnailDiskIndex(directory: directory)
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { urls = [] }
        for url in urls {
            let suffix = url.pathExtension
            guard suffix == "jpg" || suffix == "json" else { continue }
            // Normalize Foundation path substrings once, instead of bridging at every hash lookup.
            let key = String(decoding: url.deletingPathExtension().lastPathComponent.utf8, as: UTF8.self)
            guard key.utf8.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            rebuilt.record(File(url: url, key: key, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
        }
        rebuilt.loadedAt = Date(); self = rebuilt
    }

    mutating func written(_ data: Data, key: String, suffix: String) {
        guard loadedAt != nil else { return } // The first scan will include this write.
        record(File(url: directory.appendingPathComponent(key + suffix), key: key, bytes: Int64(data.count), modified: Date()))
    }

    private mutating func record(_ file: File) {
        let suffix = file.url.pathExtension
        var group = groups[file.key] ?? Group()
        if let old = group.files[suffix] { bytes -= old.bytes }
        else if suffix == "jpg" { images += 1 }
        group.files[suffix] = file; group.revision = UUID()
        groups[file.key] = group; bytes += file.bytes
    }

    mutating func removed(key: String, suffix: String) {
        guard var group = groups[key], let old = group.files.removeValue(forKey: suffix) else { return }
        bytes -= old.bytes
        if suffix == "jpg" { images -= 1 }
        group.revision = UUID()
        if group.files.isEmpty { groups.removeValue(forKey: key) } else { groups[key] = group }
    }

    mutating func reset() {
        groups = [:]; bytes = 0; images = 0; loadedAt = Date()
    }

    mutating func invalidate() { loadedAt = nil }
}
