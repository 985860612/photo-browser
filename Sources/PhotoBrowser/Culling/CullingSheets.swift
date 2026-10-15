import SwiftUI
import BrowserCore
import CullingCore

struct CullingAnalysisSheet: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject var culling: CullingStore
    @Environment(\.dismiss) private var dismiss
    @State private var options = AnalysisOptions()
    @State private var scope = "directory"
    private var chosen: [PhotoAsset] {
        switch scope {
        case "visible": return store.visibleAssets.filter { !$0.isVideo }
        case "selected": return store.visibleAssets.filter { store.selection.contains($0.id) && !$0.isVideo }
        default: return store.assets.filter { !$0.isVideo }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("选片分析")).font(.title2)
            Picker(L10n.text("分析范围"), selection: $scope) {
                Text(L10n.text("当前目录")).tag("directory")
                Text(L10n.text("当前筛选或分组")).tag("visible")
                Text(L10n.text("选中的照片")).tag("selected")
            }
            Toggle(L10n.text("相似照片归组"), isOn: $options.similarity)
            if options.similarity {
                HStack {
                    Text(L10n.text("更严格"))
                    Slider(value: $options.similarityThreshold, in: 0.15...0.65, step: 0.05)
                    Text(L10n.text("更宽松"))
                }.font(.caption)
            }
            Toggle(L10n.text("综合评分与实用型图片识别"), isOn: $options.aesthetics)
                .disabled(!VisionPhotoAnalyzer.supportsAesthetics)
            if !VisionPhotoAnalyzer.supportsAesthetics {
                Text(L10n.text("综合评分需要 macOS 15 或更高版本。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(L10n.text("人脸拍摄质量"), isOn: $options.faces)
            Toggle(L10n.text("内容标签"), isOn: $options.classification)
            Text(L10n.text("分析在本机进行；复用已完成的结果。暂停、退出后再次开始会继续剩余照片，失败项会重试。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(L10n.text("已有全景与手动分组不参与相似归组。视频暂不分析；实况照片只分析静态画面。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(L10n.text("\(chosen.count) 张照片")).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("开始分析")) { culling.start(assets: chosen, options: options); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || options.isEmpty || culling.running || !culling.available)
            }
        }.padding(24).frame(width: 520)
            .onAppear { options = culling.session.options; if !VisionPhotoAnalyzer.supportsAesthetics { options.aesthetics = false } }
    }
}

struct CullingResultsSheet: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    let chosen: [PhotoAsset]
    var body: some View {
        let plan = try? store.cullingDeletionPlan(chosen)
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("核对选片结果")).font(.title2)
            HStack(spacing: 18) {
                ForEach([CullingMark.keep, .maybe, .reject], id: \.self) { mark in
                    let count = store.assets.filter { !$0.isVideo && store.culling.mark(for: $0) == mark }.count
                    Text(mark.title + " " + count.formatted()).font(.headline)
                }
            }
            Text(L10n.text("下面只列出你标记为淘汰的照片，移动包含所有同名格式及 XMP，可通过移动记录撤销。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(store.directory?.appendingPathComponent("_del").path ?? "").font(.caption).textSelection(.enabled)
            List(chosen) { asset in
                HStack {
                    Text(asset.name); Spacer()
                    Text(asset.formatLabel).foregroundStyle(.secondary)
                    Text(L10n.text("\(asset.files.count) 个文件")).foregroundStyle(.secondary)
                }.font(.caption)
            }.frame(height: 240)
            if plan == nil, !chosen.isEmpty {
                Text(L10n.text("清单、标记或文件已变化，或有未恢复的移动记录。请关闭后重新核对。"))
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text(L10n.text("\(chosen.count) 张照片 · \(plan?.fileCount ?? chosen.flatMap(\.files).count) 个文件"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("确认移到 _del")) {
                    do { let current = try store.cullingDeletionPlan(chosen); dismiss(); store.culling.pause(); store.archive(current) }
                    catch { store.report(error) }
                }.buttonStyle(.borderedProminent).disabled(plan == nil)
            }
        }.padding(24).frame(width: 680)
    }
}
