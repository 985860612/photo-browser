import Foundation

private struct StoredMetadata: Codable {
    let fingerprint: String
    let value: PhotoMetadata
}
private struct BrowserSession: Codable {
    let groups: [PhotoGroup]
    let metadata: [String: StoredMetadata]
}

public struct RestoredBrowserSession: Sendable {
    public let assets: [PhotoAsset]
    public let groups: [PhotoGroup]
    public let note: String
}

/// Persists library decisions independently of view state and disposable image caches.
public struct BrowserSessionRepository: Sendable {
    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func file(for library: URL) -> URL {
        directory.appendingPathComponent(ThumbnailCache.digest(library.resolvingSymlinksInPath().path) + ".json")
    }

    public func restore(_ assets: [PhotoAsset], in library: URL) throws -> RestoredBrowserSession {
        let url = file(for: library)
        var photos = assets
        if FileManager.default.fileExists(atPath: url.path) {
            let session = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: url))
            let existing = Set(photos.map(\.id))
            let groups = session.groups.compactMap { group -> PhotoGroup? in
                var value = group
                value.assetIDs = value.assetIDs.filter { existing.contains($0) }
                return value.assetIDs.isEmpty ? nil : value
            }
            for index in photos.indices {
                if let saved = session.metadata[photos[index].id], saved.fingerprint == photos[index].fingerprint {
                    photos[index].metadata = saved.value
                }
            }
            return RestoredBrowserSession(assets: photos, groups: groups, note: L10n.text("已恢复保存的分组"))
        }
        let csv = library.appendingPathComponent("全景素材筛选/全景候选文件清单.csv")
        if FileManager.default.fileExists(atPath: csv.path) {
            let groups = try Grouping.importCSV(Data(contentsOf: csv), assets: photos)
            return RestoredBrowserSession(assets: photos, groups: groups, note: L10n.text("已导入已有全景清单"))
        }
        return RestoredBrowserSession(assets: photos, groups: [], note: "")
    }

    public func save(assets: [PhotoAsset], groups: [PhotoGroup], in library: URL) throws {
        let url = file(for: library)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var metadata: [String: StoredMetadata] = [:]
        for asset in assets {
            if let value = asset.metadata { metadata[asset.id] = StoredMetadata(fingerprint: asset.fingerprint, value: value) }
        }
        try JSONEncoder().encode(BrowserSession(groups: groups, metadata: metadata)).write(to: url, options: .atomic)
    }
}
