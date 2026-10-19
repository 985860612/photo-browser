import SwiftUI
import BrowserCore
import AppKit

@MainActor final class BackgroundResultStore: ObservableObject {
    @Published var rows: [BackgroundPhotoResult] = []
    @Published var loading = false
    @Published var error: String?
    @Published var hasMore = false
    @Published var coverage: BackgroundTaskEstimate?
    private var job: Task<Void, Never>?
    func load(coordinator: BackgroundTaskCoordinator, root: URL, taskID: String?, ai: BackgroundState?, vector: BackgroundState?, failures: Bool, exclusions: [URL], more: Bool = false, preserving: Bool = false) {
        if more && loading { return }
        job?.cancel(); loading = true; error = nil
        let after = more ? rows.last?.row ?? 0 : 0, target = preserving ? max(60, rows.count) : 60
        job = Task {
            do {
                var combined: [BackgroundPhotoResult] = [], cursor = after, canLoad = false
                repeat {
                    let page = try await coordinator.results(root: root, taskID: taskID, after: cursor, ai: ai, vector: vector, failuresOnly: failures, exclusions: exclusions)
                    try Task.checkCancellation()
                    combined += page.items; cursor = page.after ?? cursor; canLoad = page.hasMore
                } while combined.count < target && canLoad
                if taskID == nil {
                    var options = BackgroundTaskOptions(root: root); options.exclusions = exclusions
                    coverage = try await coordinator.estimate(options)
                }
                try Task.checkCancellation()
                if more { rows += combined } else { rows = combined }
                hasMore = canLoad; loading = false
            } catch is CancellationError {} catch { self.error = error.localizedDescription; loading = false }
        }
    }
}

struct BackgroundResultBrowser: View {
    let root: URL
    let taskID: String?
    @ObservedObject var store: BackgroundTaskStore
    @StateObject private var model = BackgroundResultStore()
    @State private var selected: String?
    @State private var ai: BackgroundState?
    @State private var vector: BackgroundState?
    @State private var failures = false
    @State private var wasActive = false
    private var request: String { root.path + (taskID ?? "") + (ai?.rawValue ?? "") + (vector?.rawValue ?? "") + String(failures) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                statusPicker(L10n.text("AI 状态"), value: $ai)
                statusPicker(L10n.text("向量状态"), value: $vector)
                Toggle(L10n.text("仅失败"), isOn: $failures)
                Spacer()
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.help(L10n.text("刷新结果"))
            }.padding(10)
            if let coverage = model.coverage {
                Text(L10n.text("照片 \(coverage.photos) 张 · AI 已完成 \(coverage.photos - coverage.ai) 张 · 向量已完成 \(coverage.photos - coverage.vectors) 张"))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(model.rows) { row in
                        HStack(spacing: 10) {
                            TaskResultThumbnail(item: row.item).frame(width: 64, height: 45)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.item.title).lineLimit(1)
                                Text(row.item.directory.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                if let issue = row.issue { Text(issue).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text("AI：\(row.ai.title)"))
                                Text(L10n.text("向量：\(row.vector.title)"))
                            }.font(.caption).foregroundStyle(row.issue == nil ? Color.secondary : Color.orange)
                        }.padding(.vertical, 4).tag(row.id)
                    }
                }.listStyle(.inset)
                if let row = model.rows.first(where: { $0.id == selected }) {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(row.item.asset.name).font(.headline).textSelection(.enabled)
                            TaskResultThumbnail(item: row.item).frame(height: 135)
                            Text(row.item.directory.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            AIPhotoInformation(asset: row.item.asset, cachedMetadata: row.item.metadata, usesCatalog: true).id(row.id)
                            Divider()
                            Label(L10n.text("图片向量"), systemImage: "photo.stack").font(.headline)
                            Text(row.vector.title)
                            if [.succeeded, .reused].contains(row.vector) {
                                Text("Apple Vision revision 2 · 768 Float32").font(.caption).foregroundStyle(.secondary)
                                if let updated = row.vectorUpdated { Text(updated, format: .dateTime.year().month().day().hour().minute()).font(.caption) }
                                Button(L10n.text("查看相似图片"), systemImage: "photo.stack") { store.showSimilar(row.item, root: root) }.disabled(store.browse == nil)
                            }
                            if let issue = row.issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                        }.padding(14)
                    }.frame(width: 280)
                }
            }
            Divider()
            HStack {
                if model.loading { ProgressView().controlSize(.mini) }
                Text(L10n.text("已载入 \(model.rows.count) 张")).monospacedDigit()
                if let error = model.error { Text(error).foregroundStyle(.orange).lineLimit(1).help(error) }
                Spacer()
                if model.hasMore { Button(L10n.text("显示更多")) { load(more: true) }.disabled(model.loading) }
            }.font(.caption).padding(10)
        }
        .task(id: request) { load() }
        .onChange(of: store.revision) { _, _ in
            let active = store.activeCount > 0
            if !model.loading && (active || wasActive) { load(preserving: true) }
            wasActive = active
        }
    }
    private func load(more: Bool = false, preserving: Bool = false) {
        model.load(coordinator: store.coordinator, root: root, taskID: taskID, ai: ai, vector: vector, failures: failures, exclusions: store.exclusions, more: more, preserving: preserving)
    }
    private func statusPicker(_ title: String, value: Binding<BackgroundState?>) -> some View {
        Picker(title, selection: value) {
            Text(L10n.text("全部")).tag(nil as BackgroundState?)
            ForEach([BackgroundState.pending, .blocked, .running, .succeeded, .reused, .failed, .cancelled, .disabled], id: \.self) { state in Text(state.title).tag(Optional(state)) }
        }.frame(maxWidth: 190)
    }
}

private struct TaskResultThumbnail: View {
    let item: AICatalogItem
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.25))
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.tertiary) }
        }.clipShape(RoundedRectangle(cornerRadius: 5))
            .task(id: item.preview) {
                guard let url = item.preview, url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Library/") else { image = nil; return }
                let loaded = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
                guard !Task.isCancelled else { return }; image = loaded
            }
    }
}
