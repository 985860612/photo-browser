import Foundation
import BrowserCore
import CullingCore

extension CullingStore {
    func mark(for asset: PhotoAsset) -> CullingMark { session.decisions[asset.id]?.mark ?? .unreviewed }
    func decisionNeedsReview(_ asset: PhotoAsset) -> Bool {
        session.decisions[asset.id].map { $0.fingerprint != asset.fingerprint } ?? false
    }
    func analysis(for asset: PhotoAsset) -> PhotoAnalysis? {
        guard let value = analyses[asset.id], value.isCurrent(for: asset, options: session.options) else { return nil }
        return value
    }
    func group(for id: String) -> SimilarityGroup? { groupByAsset[id] }
    func rankedIDs(in group: SimilarityGroup) -> [String] {
        return group.assetIDs.filter { id in assetByID[id].flatMap { analysis(for: $0)?.aesthetics } != nil }.sorted {
            let a = analyses[$0]?.aesthetics ?? -1, b = analyses[$1]?.aesthetics ?? -1
            return a == b ? $0 < $1 : a > b
        }
    }
    var recommendedIDs: Set<String> {
        Set(similarityGroups.flatMap { group -> [String] in
            let ranked = rankedIDs(in: group)
            guard ranked.count == group.assetIDs.count, let first = ranked.first, let score = analyses[first]?.aesthetics else { return [] }
            return ranked.filter { abs((analyses[$0]?.aesthetics ?? -1) - score) < 0.0001 }
        })
    }
    func rank(of id: String, in group: SimilarityGroup) -> Int? {
        let ranked = rankedIDs(in: group)
        guard ranked.count == group.assetIDs.count, ranked.contains(id), let score = analyses[id]?.aesthetics else { return nil }
        return 1 + ranked.filter { (analyses[$0]?.aesthetics ?? -1) > score + 0.0001 }.count
    }
    var counts: [Filter: Int] {
        let recommendations = recommendedIDs
        var result: [Filter: Int] = [:]
        for asset in assets where !asset.isVideo {
            result[.all, default: 0] += 1
            switch mark(for: asset) {
            case .unreviewed: result[.unreviewed, default: 0] += 1
            case .keep: result[.keep, default: 0] += 1
            case .maybe: result[.maybe, default: 0] += 1
            case .reject: result[.reject, default: 0] += 1
            }
            if group(for: asset.id) != nil { result[.similar, default: 0] += 1 }
            if recommendations.contains(asset.id) { result[.recommended, default: 0] += 1 }
            if matches(asset, filter: .review) { result[.review, default: 0] += 1 }
        }
        return result
    }
    func matches(_ asset: PhotoAsset, filter: Filter) -> Bool {
        switch filter {
        case .all: return true
        case .unreviewed: return mark(for: asset) == .unreviewed
        case .keep: return mark(for: asset) == .keep
        case .maybe: return mark(for: asset) == .maybe
        case .reject: return mark(for: asset) == .reject
        case .similar: return group(for: asset.id) != nil
        case .recommended: return recommendedIDs.contains(asset.id)
        case .review: return decisionNeedsReview(asset) || failures[asset.id] != nil || analysis(for: asset)?.isUtility == true
        }
    }
    func filtered(_ input: [PhotoAsset]) -> [PhotoAsset] {
        let members = selectedGroupID.flatMap { id in similarityGroups.first { $0.id == id }.map { Set($0.assetIDs) } }
        let recommended = filter == .recommended ? recommendedIDs : []
        return input.filter { asset in
            guard !asset.isVideo else { return false }
            if let members, !members.contains(asset.id) { return false }
            if let selectedLabel, analysis(for: asset)?.labels.contains(where: { $0.identifier == selectedLabel }) != true { return false }
            if filter == .recommended { return recommended.contains(asset.id) }
            return matches(asset, filter: filter)
        }
    }
    var labels: [String] {
        Array(Set(assets.compactMap { analysis(for: $0) }.flatMap { $0.labels.map(\.identifier) })).sorted()
    }
    var rejectedAssets: [PhotoAsset] { assets.filter { !$0.isVideo && mark(for: $0) == .reject } }
    var reviewedCount: Int { assets.filter { !$0.isVideo && mark(for: $0) != .unreviewed }.count }
}

extension CullingMark {
    var title: String {
        switch self {
        case .unreviewed: return L10n.text("未处理")
        case .keep: return L10n.text("保留")
        case .maybe: return L10n.text("待定")
        case .reject: return L10n.text("淘汰")
        }
    }
    var symbol: String {
        switch self {
        case .unreviewed: return "circle.dashed"
        case .keep: return "checkmark.circle.fill"
        case .maybe: return "questionmark.circle.fill"
        case .reject: return "xmark.circle.fill"
        }
    }
}

extension CullingStore.Filter {
    var title: String {
        switch self {
        case .all: return L10n.text("全部照片")
        case .unreviewed: return CullingMark.unreviewed.title
        case .keep: return CullingMark.keep.title
        case .maybe: return CullingMark.maybe.title
        case .reject: return CullingMark.reject.title
        case .similar: return L10n.text("相似照片")
        case .recommended: return L10n.text("建议优先查看")
        case .review: return L10n.text("建议复核")
        }
    }
}
