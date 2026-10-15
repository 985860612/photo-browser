import Foundation
import Vision
import BrowserCore

public enum SimilarityBuilder {
    /// Conservative v2-feature threshold. Compare a bounded time neighborhood and every group member
    /// to its anchor, so A≈B≈C cannot silently turn dissimilar A/C into one group.
    public static func build(assets: [PhotoAsset], analyses: [String: PhotoAnalysis], protectedIDs: Set<String>,
                             session: CullingSession, threshold: Float = 0.35,
                             check: () throws -> Void = {}) throws -> [SimilarityGroup] {
        let eligible = assets.filter { !($0.isVideo || protectedIDs.contains($0.id)) }
        let existing = Set(eligible.map(\.id))
        let manual = session.manualGroups.compactMap { group -> SimilarityGroup? in
            let ids = group.assetIDs.filter { existing.contains($0) }
            return ids.count >= 2 ? SimilarityGroup(id: group.id, assetIDs: ids) : nil
        }
        let excluded = session.excludedFromSimilarity.union(manual.flatMap(\.assetIDs))
        let sorted = eligible.filter { !excluded.contains($0.id) }.sorted {
            let a = analyses[$0.id]?.captured ?? $0.metadata?.captured
            let b = analyses[$1.id]?.captured ?? $1.metadata?.captured
            if let a, let b, a != b { return a < b }
            if (a != nil) != (b != nil) { return a != nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        var features: [String: VNFeaturePrintObservation] = [:]
        for asset in sorted {
            try check()
            if let analysis = analyses[asset.id], analysis.isCurrent(for: asset), let data = analysis.featurePrint {
                // Corrupt replaceable features are ignored, not confused with an exact match.
                features[asset.id] = try? VisionPhotoAnalyzer.feature(data)
            }
        }
        var groups: [SimilarityGroup] = [], anchorPositions: [Int] = []
        for (index, asset) in sorted.enumerated() {
            try check()
            guard let feature = features[asset.id] else { continue }
            var best: (Int, Float)?
            for groupIndex in groups.indices.reversed() {
                if index - anchorPositions[groupIndex] > 32 { break }
                let anchor = groups[groupIndex].assetIDs[0]
                let a = analyses[anchor]?.captured, b = analyses[asset.id]?.captured
                if let a, let b, abs(a.timeIntervalSince(b)) > 90 { continue }
                guard let reference = features[anchor] else { continue }
                let distance = try VisionPhotoAnalyzer.distance(feature, reference)
                if distance <= threshold, best == nil || distance < best!.1 { best = (groupIndex, distance) }
            }
            if let best { groups[best.0].assetIDs.append(asset.id) }
            else { groups.append(SimilarityGroup(id: "similar-" + asset.id, assetIDs: [asset.id])); anchorPositions.append(index) }
        }
        return groups.filter { $0.assetIDs.count > 1 } + manual
    }
}
