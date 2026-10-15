import SwiftUI
import BrowserCore
import CullingCore

struct CullingInspector: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject var culling: CullingStore
    @State private var information = false
    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.text("照片面板"), selection: $information) {
                Text(L10n.text("选片")).tag(false)
                Text(L10n.text("信息")).tag(true)
            }.pickerStyle(.segmented).padding(12)
            if information { InspectorView() }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let asset = store.focusedAsset {
                            Text(asset.name).font(.headline).textSelection(.enabled)
                            Text(asset.formatLabel).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.text("你的标记")).font(.headline)
                            CullingMarkBadge(mark: culling.mark(for: asset))
                            CullingMarkControls().controlSize(.large)
                            Text(L10n.text("P 保留 · M 待定 · X 淘汰 · U 清除"))
                                .font(.caption2).foregroundStyle(.secondary)
                            Toggle(L10n.text("标记后自动前进"), isOn: $culling.autoAdvance).font(.caption)
                            Button(L10n.text("撤销标记或分组")) { culling.undo(); store.repairCullingSelection() }
                                .disabled(culling.undoCount == 0)
                            if culling.decisionNeedsReview(asset) {
                                Label(L10n.text("文件已变化，请重新确认标记。"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            Divider()
                            Text(L10n.text("分析参考")).font(.headline)
                            if let failure = culling.failures[asset.id] {
                                Label(L10n.text("分析失败"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                Text(failure).font(.caption).textSelection(.enabled)
                            } else if let analysis = culling.analysis(for: asset) {
                                analysisFields(analysis, asset: asset)
                            } else {
                                Text(L10n.text("尚未分析，或原文件与分析设置已变化。"))
                                    .font(.caption).foregroundStyle(.secondary)
                                Button(L10n.text("分析当前照片")) { culling.start(assets: [asset], options: culling.session.options) }
                                    .disabled(culling.running || !culling.available)
                            }
                            if culling.protectedIDs.contains(asset.id) {
                                Label(L10n.text("已有分组：不参与相似归组"), systemImage: "rectangle.stack")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(L10n.text("分析建议不会改变你的标记；淘汰标记不会移动文件。"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else { Text(L10n.text("选择照片查看选片信息")).foregroundStyle(.secondary) }
                    }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
            }
        }
    }
    @ViewBuilder private func analysisFields(_ analysis: PhotoAnalysis, asset: PhotoAsset) -> some View {
        if let group = culling.group(for: asset.id) {
            let ranked = culling.rankedIDs(in: group)
            if let rank = culling.rank(of: asset.id, in: group) {
                Label(L10n.text("组内综合排名 \(rank) / \(ranked.count)"), systemImage: "sparkles")
                if rank == 1 { Text(L10n.text("综合评分在本组最高，建议优先查看。")).font(.caption).foregroundStyle(.secondary) }
            } else if !ranked.isEmpty {
                Text(L10n.text("已评分 \(ranked.count) / \(group.assetIDs.count) 张，完成后显示排名。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Menu(L10n.text("调整相似组")) {
                Button(L10n.text("将所选照片移出相似组")) { culling.removeFromSimilarity(store.selection) }
                Button(L10n.text("从当前照片拆开相似组")) { culling.split(group, at: asset.id) }
                    .disabled(group.assetIDs.first == asset.id)
            }
        }
        if !analysis.faces.isEmpty {
            Text(L10n.text("检测到 \(analysis.faces.count) 张人脸"))
            ForEach(Array(analysis.faces.enumerated()), id: \.offset) { index, face in
                if let quality = face.quality {
                    HStack {
                        Text(L10n.text("人脸 \(index + 1) 拍摄质量"))
                        Spacer(); Text(quality.formatted(.number.precision(.fractionLength(2)))).monospacedDigit()
                    }.font(.caption)
                }
            }
            Text(L10n.text("人脸分数适合比较同一人物的连续照片。"))
                .font(.caption2).foregroundStyle(.secondary)
        }
        if analysis.isUtility == true {
            Label(L10n.text("模型判为实用型图片，请按用途复核。"), systemImage: "doc.text")
        }
        if !analysis.labels.isEmpty {
            Text(L10n.text("内容标签")).font(.headline)
            ForEach(analysis.labels, id: \.identifier) { label in
                Button(label.identifier) { store.setCullingFilter(.all, label: label.identifier) }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        DisclosureGroup(L10n.text("分析详情")) {
            VStack(alignment: .leading, spacing: 8) {
                if let score = analysis.aesthetics {
                    Text(L10n.text("综合评分：\(score.formatted(.number.precision(.fractionLength(3))))"))
                } else if !VisionPhotoAnalyzer.supportsAesthetics {
                    Text(L10n.text("综合评分需要 macOS 15 或更高版本。"))
                }
                Text(L10n.text("综合评分不单独说明模糊、曝光或闭眼原因。"))
                Text(L10n.text("在本机分析，使用统一尺寸预览；细节请核对原图。"))
            }.font(.caption2).foregroundStyle(.secondary).padding(.top, 6)
        }
    }
}
