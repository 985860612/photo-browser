import AppKit
import BrowserCore
import CullingCore

extension BrowserStore {
    func reconcileCulling() {
        culling.reconcile(assets, protectedIDs: Set(groups.flatMap(\.assetIDs)))
    }
    func setCullingActive(_ active: Bool) {
        culling.active = active
        video.stop(); livePhotoMotionID = nil
        selectedFolderID = nil; visibleOrdering = nil
        repairCullingSelection()
        if active, culling.referenceID == nil { culling.referenceID = focusedID }
    }
    func setCullingFilter(_ filter: CullingStore.Filter, groupID: String? = nil, label: String? = nil) {
        culling.filter = filter; culling.selectedGroupID = groupID; culling.selectedLabel = label
        scope = "all"; visibleOrdering = nil; selectedFolderID = nil
        repairCullingSelection()
        if let groupID, let group = culling.similarityGroups.first(where: { $0.id == groupID }) {
            culling.referenceID = culling.rankedIDs(in: group).first ?? group.assetIDs.first
        }
    }
    func repairCullingSelection(preferred: String? = nil) {
        visibleOrdering = nil
        let list = visibleAssets
        let next = list.first { $0.id == (preferred ?? focusedID) } ?? list.first
        focusedID = next?.id; selection = next.map { [$0.id] } ?? []
        preferredFileID = nil; selectionAnchorID = focusedID; rangeSelectionBase = nil
        navigationScrollTarget = focusedID
    }
    func markCullingSelection(_ mark: CullingMark) {
        guard !isMoving, !isLoading, selectedFolderID == nil else { return }
        let list = visibleAssets, chosen = list.filter { selection.contains($0.id) }
        let index = list.firstIndex { $0.id == focusedID } ?? 0
        let next = list.dropFirst(index + 1).first { !selection.contains($0.id) }?.id
        guard culling.mark(mark, assets: chosen) else { return }
        repairCullingSelection(preferred: chosen.count == 1 && culling.autoAdvance ? next : focusedID)
    }
    func stepCullingGroup(_ offset: Int) {
        let groups = culling.similarityGroups
        guard !groups.isEmpty else { return }
        let index = groups.firstIndex { $0.id == (culling.selectedGroupID ?? culling.group(for: focusedID ?? "")?.id) } ?? 0
        let next = groups[max(0, min(groups.count - 1, index + offset))]
        setCullingFilter(.similar, groupID: next.id)
    }
    func cullingDeletionPlan(_ chosen: [PhotoAsset]) throws -> ArchivePlan {
        guard let directory, canArchive, !isLoading, !chosen.isEmpty,
              chosen.allSatisfy({ candidate in
                  assets.contains { $0.id == candidate.id && $0.fingerprint == candidate.fingerprint }
                      && culling.mark(for: candidate) == .reject && !culling.decisionNeedsReview(candidate)
              }) else { throw BrowserFailure.message(L10n.text("淘汰清单已变化，请重新核对选片结果。")) }
        return try ArchivePlan.pendingDeletion(directory: directory, assets: chosen, groups: groups)
    }
}
