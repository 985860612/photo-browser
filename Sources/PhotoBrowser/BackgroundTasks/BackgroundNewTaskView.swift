import SwiftUI
import AppKit
import BrowserCore

struct BackgroundNewTaskView: View {
    @ObservedObject var store: BackgroundTaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var root: URL?
    @State private var ai = true
    @State private var vector = true
    @State private var force = false
    @State private var selectionOnly = false
    @State private var estimate: BackgroundTaskEstimate?
    @State private var busy = false
    @State private var error: String?
    private var options: BackgroundTaskOptions {
        var options = BackgroundTaskOptions(root: root ?? store.root)
        options.ai = ai; options.vector = vector; options.force = force; options.exclusions = store.exclusions
        if selectionOnly { options.photoIDs = store.selectedAssets.map(AICatalogItem.identity) }
        return options
    }
    private var request: String { (root ?? store.root).path + "\(ai)\(vector)\(force)\(selectionOnly)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.text("新建后台任务"), systemImage: "plus.circle").font(.headline)
            HStack {
                Text((root ?? store.root).path).font(.caption).textSelection(.enabled).lineLimit(2)
                Spacer(); Button(L10n.text("选择目录…")) { chooseRoot() }.disabled(selectionOnly)
            }
            if !store.selectedAssets.isEmpty { Toggle(L10n.text("仅处理所选 \(store.selectedAssets.count) 张照片"), isOn: $selectionOnly) }
            HStack { Toggle(L10n.text("AI 识别"), isOn: $ai); Toggle(L10n.text("图片向量"), isOn: $vector) }
            Picker(L10n.text("处理方式"), selection: $force) {
                Text(L10n.text("仅补缺失结果")).tag(false)
                Text(L10n.text("重新生成所选类型")).tag(true)
            }.pickerStyle(.segmented)
            Text(L10n.text("优先复用本地缩略图；缺少时从原片准备 720 像素预览。视频、PSD、PSB 和已排除目录不处理。")).font(.caption).foregroundStyle(.secondary)
            if let estimate {
                Text(L10n.text("照片 \(estimate.photos) 张 · 待 AI 识别 \(estimate.ai) 张 · 待生成向量 \(estimate.vectors) 张")).font(.callout).monospacedDigit()
                if ai && estimate.ai > 0 { Text(L10n.text("将使用设置中的 AI 服务；已有有效结果默认复用。")).font(.caption).foregroundStyle(.secondary) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button(L10n.text("扫描目录并统计")) { scan() }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(L10n.text("开始任务")) { create() }.keyboardShortcut(.defaultAction)
                    .disabled(busy || (!ai && !vector) || (estimate?.photos ?? 0) == 0)
            }
        }.padding(24).frame(width: 640).controlSize(.small)
            .task(id: request) {
                estimate = nil; error = nil
                do { estimate = try await store.coordinator.estimate(options) }
                catch { self.error = error.localizedDescription }
            }
    }
    private func chooseRoot() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.directoryURL = root ?? store.root
        if panel.runModal() == .OK, let url = panel.url { root = url }
    }
    private func scan() {
        busy = true; error = nil
        let options = options, assets = selectionOnly ? store.selectedAssets : []
        Task {
            do {
                try await store.coordinator.prepareScope(options.root, assets: assets, refresh: !selectionOnly)
                estimate = try await store.coordinator.estimate(options)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    private func create() {
        busy = true; error = nil
        let options = options
        Task {
            do {
                store.selectedTask = try await store.coordinator.create(options)
                try await store.refresh(); dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
