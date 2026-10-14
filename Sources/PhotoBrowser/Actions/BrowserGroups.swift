import AppKit
import BrowserCore

extension BrowserStore {
    func rename(_ group: PhotoGroup, to input: String) {
        guard !isMoving, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\0"), !name.contains("\n") else { report(BrowserFailure.message(L10n.text("请输入有效的分组名称。"))); return }
        groups[index].name = name; renameGroup = nil
        persistChanges(L10n.text("分组已重命名为“\(name)”"))
    }
    func createGroup() {
        let ids = visibleAssets.filter { selection.contains($0.id) }.map(\.id)
        guard ids.count >= 2 else { report(BrowserFailure.message(L10n.text("请选择至少两张照片。⌘ 点击可多选，⇧ 点击可选择连续范围。"))); return }
        removeMembership(ids)
        let group = PhotoGroup(name: L10n.text("手动组 \(groups.count + 1)"), assetIDs: ids)
        groups.append(group); scope = group.id; showGroupOverview = true
        persistChanges(L10n.text("已创建分组，共 \(ids.count) 张照片"))
    }

    func splitGroup() {
        guard let group = currentGroup, let id = focusedID else { return }
        do {
            let split = try Grouping.split(group, at: id)
            guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
            groups.replaceSubrange(index...index, with: split); scope = split[1].id
            persistChanges(L10n.text("已从当前照片处分成两组"))
        } catch { report(error) }
    }

    func mergeGroup(into targetID: String) {
        guard let group = currentGroup, let target = groups.first(where: { $0.id == targetID }), target.id != group.id else { return }
        let combined = Set(group.assetIDs + target.assetIDs)
        let merged = PhotoGroup(name: group.name + " + " + target.name, assetIDs: assets.filter { combined.contains($0.id) }.map(\.id))
        groups.removeAll { $0.id == group.id || $0.id == target.id }
        groups.append(merged); scope = merged.id; showMerge = false
        persistChanges(L10n.text("已合并两个分组"))
    }

    func removeFromGroup() {
        guard let group = currentGroup, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].assetIDs.removeAll { selection.contains($0) }
        if groups[index].assetIDs.isEmpty { groups.remove(at: index); scope = "ungrouped" }
        changeScope(); persistChanges(L10n.text("已将所选照片移出分组，原文件未移动"))
    }

    func dissolveGroup(_ group: PhotoGroup) {
        groups.removeAll { $0.id == group.id }
        if scope == group.id { scope = "all"; changeScope() }
        persistChanges(L10n.text("已取消分组，原文件未移动"))
    }

    func autoGroup() {
        guard let directory, !isReadingMetadata, !isMoving, !assets.isEmpty else { return }
        let snapshot = assets.filter { !$0.isVideo }, job = MetadataReader(), ticket = UUID()
        guard !snapshot.isEmpty else { return }
        metadataJob = job; metadataID = ticket; isReadingMetadata = true
        status = L10n.text("读取 \(snapshot.count) 张照片的拍摄信息…NAS 首次读取可能需要几分钟，可继续浏览")
        Task {
            do {
                let metadata = try await Task.detached(priority: .utility) { try job.read(directory: directory, assets: snapshot) }.value
                guard metadataID == ticket else { return }
                for index in assets.indices where !assets[index].isVideo { assets[index].metadata = metadata[assets[index].id] }
                groups = Grouping.candidates(assets)
                scope = "all"; showGroupOverview = false; metadataJob = nil; isReadingMetadata = false
                persistChanges(L10n.text("生成 \(groups.count) 个候选组；请检查画面重叠，自动分组不代表已确认全景"))
            } catch {
                guard metadataID == ticket else { return }
                metadataJob = nil; isReadingMetadata = false
                if error is CancellationError { status = L10n.text("已取消自动分组") } else { status = L10n.text("自动分组失败"); report(error) }
            }
        }
    }

    func cancelMetadata() {
        metadataID = UUID(); metadataJob?.cancel(); metadataJob = nil; isReadingMetadata = false
        status = L10n.text("已取消自动分组，已有分组保留")
    }

    func importCSV() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            do {
                groups = try Grouping.importCSV(Data(contentsOf: url), assets: assets)
                scope = "all"; changeScope(); persistChanges(L10n.text("已导入 \(groups.count) 个分组"))
            } catch { report(error) }
        }
    }

    func removeMembership(_ ids: [String]) {
        let removed = Set(ids)
        for index in groups.indices { groups[index].assetIDs.removeAll { removed.contains($0) } }
        groups.removeAll { $0.assetIDs.isEmpty }
    }

    func restoreDeletedMembership(_ savedGroups: [PhotoGroup], assetIDs: Set<String>) {
        let restoredIDs = assetIDs.intersection(assets.map(\.id))
        let currentGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        removeMembership(Array(restoredIDs))
        for saved in savedGroups {
            let recovered = saved.assetIDs.filter { restoredIDs.contains($0) }
            guard !recovered.isEmpty else { continue }
            if let index = groups.firstIndex(where: { $0.id == saved.id }) {
                var ordered = groups[index].assetIDs
                for id in recovered {
                    let position = saved.assetIDs.firstIndex(of: id)!
                    if let next = saved.assetIDs.dropFirst(position + 1).first(where: { ordered.contains($0) }),
                       let anchor = ordered.firstIndex(of: next) {
                        ordered.insert(id, at: anchor)
                    } else if let previous = saved.assetIDs.prefix(position).last(where: { ordered.contains($0) }),
                              let anchor = ordered.firstIndex(of: previous) {
                        ordered.insert(id, at: anchor + 1)
                    } else { ordered.append(id) }
                }
                groups[index].assetIDs = ordered
            } else {
                var group = currentGroups[saved.id] ?? saved
                group.assetIDs = recovered; groups.append(group)
            }
        }
    }

}
