import Foundation

public struct AICatalogItem: Identifiable, Codable, Sendable {
    public let id: String
    public var asset: PhotoAsset
    public var metadata: RecognitionMetadata?
    public var preview: URL?
    public var state: String
    public var issue: String?
    public init(asset: PhotoAsset, metadata: RecognitionMetadata? = nil, preview: URL? = nil,
                state: String = "processing.pending", issue: String? = nil) {
        self.id = Self.identity(asset); self.asset = asset; self.metadata = metadata
        self.preview = preview; self.state = state; self.issue = issue
    }
    public static func identity(_ asset: PhotoAsset) -> String {
        ThumbnailCache.digest((asset.imageFiles.first?.url.deletingLastPathComponent().aiStandardized.path ?? "") + "/" + asset.id)
    }
    public var directory: URL { asset.preferred.url.deletingLastPathComponent().aiStandardized }
    public var title: String { metadata?.title.isEmpty == false ? metadata!.title : asset.name }
    static func snapshot(_ asset: PhotoAsset) -> String {
        asset.imageFiles.sorted { $0.id < $1.id }.map { "\($0.url.lastPathComponent)|\($0.size)|\($0.modified.timeIntervalSince1970)" }.joined(separator: ";")
    }
    static func sameImages(_ lhs: PhotoAsset, _ rhs: PhotoAsset) -> Bool {
        lhs.imageFiles.count == rhs.imageFiles.count && lhs.imageFiles.allSatisfy { file in
            rhs.imageFiles.contains { $0.url.aiStandardized.path == file.url.aiStandardized.path && $0.size == file.size && abs($0.modified.timeIntervalSince(file.modified)) <= 0.01 }
        }
    }
}

public struct AICatalogFilter: Codable, Equatable, Sendable {
    public var similaritySeedID: String?
    public var state = "processing.succeeded"
    public var text = ""
    public var tags: [String: Set<String>] = [:]
    public var descending = true
    public init() {}
}

public struct AICatalogCursor: Codable, Sendable { let date: Double; let row: Int64 }
public struct AICatalogPage: Sendable {
    public let items: [AICatalogItem]
    public let cursor: AICatalogCursor?
    public let hasMore: Bool
}
public struct AICatalogFacet: Identifiable, Sendable {
    public var id: String { code }
    public let code: String
    public let name: String
    public let count: Int
}
public struct AICatalogField: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
}
public struct AICatalogSummary: Sendable {
    public let total: Int
    public let states: [String: Int]
    public let complete: Bool
    public let updated: Date?
}
public struct AICatalogProgress: Sendable {
    public let imported: Int
    public let scanned: Int
    public let complete: Bool
    public let issue: String?
}

public enum AICatalogPaths {
    public static func contains(_ child: URL, in root: URL) -> Bool {
        let base = root.aiStandardized.pathComponents, path = child.aiStandardized.pathComponents
        return path.starts(with: base)
    }
    public static func allowed(_ child: URL, root: URL) -> Bool {
        guard contains(child, in: root) else { return false }
        return !child.aiStandardized.pathComponents.dropFirst(root.aiStandardized.pathComponents.count).contains {
            $0.hasPrefix(".") || ["_del", "#recycle", "@recycle", "$recycle.bin", "@eadir", "@recently-snapshot"].contains($0.lowercased())
        }
    }
}

// Re-create enumerator URLs with an explicit hint before standardizing. Bridged NSURL's
// standardization performs a stat for every entry, defeating prefetched NAS directory attributes.
extension URL {
    var aiStandardized: URL { URL(fileURLWithPath: path, isDirectory: hasDirectoryPath).standardizedFileURL }
}
