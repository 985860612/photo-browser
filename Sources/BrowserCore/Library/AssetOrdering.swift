import Foundation

public enum PreviewSortField: String, CaseIterable {
    case original, name, captured, modified, size
    public var title: String {
        switch self {
        case .original: return L10n.text("默认顺序")
        case .name: return L10n.text("名称")
        case .captured: return L10n.text("拍摄时间")
        case .modified: return L10n.text("修改时间")
        case .size: return L10n.text("文件大小")
        }
    }
}

/// Stateless ordering shared by browsing and any future review view.
public enum AssetOrdering {
    public static func visible(_ assets: [PhotoAsset], groups: [PhotoGroup], scope: String,
                               search: String, field: PreviewSortField, descending: Bool) -> [PhotoAsset] {
        let base: [PhotoAsset]
        if let group = groups.first(where: { $0.id == scope }) {
            let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            base = group.assetIDs.compactMap { byID[$0] }
        } else if scope == "ungrouped" {
            let assigned = Set(groups.flatMap(\.assetIDs))
            base = assets.filter { !assigned.contains($0.id) }
        } else { base = assets }
        let matching = search.isEmpty ? base : base.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.formatLabel.localizedCaseInsensitiveContains(search)
        }
        return sorted(matching, by: field, descending: descending)
    }

    public static func sorted(_ input: [PhotoAsset], by field: PreviewSortField, descending: Bool) -> [PhotoAsset] {
        guard field != .original else { return descending ? Array(input.reversed()) : input }
        func modified(_ asset: PhotoAsset) -> Date { asset.mediaFiles.map(\.modified).max() ?? .distantPast }
        func bytes(_ asset: PhotoAsset) -> Int64 { asset.files.reduce(0) { $0 + max(0, $1.size) } }
        return input.sorted { a, b in
            let comparison: ComparisonResult
            switch field {
            case .name: comparison = a.name.localizedStandardCompare(b.name)
            case .captured: comparison = (a.metadata?.captured ?? modified(a)).compare(b.metadata?.captured ?? modified(b))
            case .modified: comparison = modified(a).compare(modified(b))
            case .size:
                let x = bytes(a), y = bytes(b)
                comparison = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            case .original: comparison = .orderedSame
            }
            if comparison != .orderedSame { return comparison == (descending ? .orderedDescending : .orderedAscending) }
            let name = a.name.localizedStandardCompare(b.name)
            return name == .orderedSame ? a.id < b.id : name == .orderedAscending
        }
    }
}
