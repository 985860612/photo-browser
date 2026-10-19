import SwiftUI
import AppKit
import BrowserCore

struct AISimilarPhotosView: View {
    @StateObject private var model: AIVisualSearchStore
    @Environment(\.dismiss) private var dismiss
    let onDirectory: (AICatalogItem) -> Void
    init(seed: AICatalogItem, root: URL, repository: AICatalogRepository, exclusions: [URL], onDirectory: @escaping (AICatalogItem) -> Void) {
        _model = StateObject(wrappedValue: AIVisualSearchStore(seed: seed, root: root, repository: repository, exclusions: exclusions))
        self.onDirectory = onDirectory
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if model.large, let selected = model.selected { AISimilarPhotoPreview(item: selected).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { results }
                if let selected = model.selected {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(selected.asset.name).font(.headline).textSelection(.enabled)
                            Text(selected.directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            HStack {
                                Button(L10n.text("在目录中查看"), systemImage: "folder") { onDirectory(selected) }
                                Button { NSWorkspace.shared.activateFileViewerSelecting([selected.asset.preferred.url]) } label: { Image(systemName: "arrow.up.forward.app") }.help(L10n.text("在 Finder 显示"))
                            }
                            Divider()
                            AIPhotoInformation(asset: selected.asset, cachedMetadata: selected.metadata, usesCatalog: true).id(selected.id)
                        }.padding(16)
                    }.frame(width: 290)
                }
            }
            Divider()
            HStack {
                if model.searching { ProgressView().controlSize(.mini) }
                Text(L10n.text("显示 \(model.matches.count) 张相似图片")).monospacedDigit()
                Spacer()
                Text(L10n.text("向量距离越小，画面越相似")).foregroundStyle(.secondary)
                if model.canLoadMore { Button(L10n.text("显示更多"), action: model.loadMore).disabled(model.searching) }
            }.font(.caption).padding(12)
        }
        .frame(minWidth: 1000, idealWidth: 1200, minHeight: 650, idealHeight: 850)
        .background(GlassBackdrop().ignoresSafeArea()).preferredColorScheme(.dark).controlSize(.small)
        .task { model.start() }
        .onDisappear { model.stop() }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.text("相似图片"), systemImage: "photo.stack").font(.headline)
                Text(model.seed.title).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.large { Button(L10n.text("返回照片墙")) { model.large = false } }
                Menu {
                    Button(L10n.text("重试失败")) { model.start(retryFailures: true) }
                    Button(L10n.text("重新建立向量索引")) { model.start(rebuild: true) }
                } label: { Image(systemName: "arrow.clockwise") }.menuStyle(.borderlessButton).fixedSize().help(L10n.text("向量索引"))
                Button(L10n.text("返回 AI 分类")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(L10n.text("图片向量搜索范围：\(model.root.path)")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let progress = model.progress {
                HStack {
                    if model.indexing { ProgressView(value: Double(progress.indexed + progress.failed), total: Double(max(1, progress.total))).frame(width: 140) }
                    Text(L10n.text("已建立 \(progress.indexed)/\(progress.total) 张 · 失败 \(progress.failed) 张")).font(.caption).monospacedDigit()
                    Spacer()
                    if model.indexing { Button(L10n.text("暂停建立索引")) { model.stop() } }
                    else if !progress.complete { Button(L10n.text("继续建立索引")) { model.start() } }
                }
                if !progress.complete { Text(L10n.text("首次建立可中断，当前结果仅覆盖已完成向量的照片。")).font(.caption2).foregroundStyle(.secondary) }
                if let issue = progress.issue { Text(issue).font(.caption2).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled) }
            }
            if let error = model.error {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    Button(L10n.text("重试")) { model.start(retryFailures: true) }
                }
            }
        }.padding(14)
    }
    private var results: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 185, maximum: 260), spacing: 12)], spacing: 14) {
                ForEach(model.matches) { hit in
                    VStack(alignment: .leading, spacing: 4) {
                        AICatalogCard(item: hit.item, root: model.root, selected: model.selectedID == hit.id)
                        Text(L10n.text("向量距离 \(String(format: "%.3f", hit.distance))")).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.selectedID = hit.id; model.large = true }
                    .onTapGesture { model.selectedID = hit.id }
                    .contextMenu {
                        Button(L10n.text("在目录中查看"), systemImage: "folder") { onDirectory(hit.item) }.labelStyle(.titleAndIcon)
                        Button(L10n.text("在 Finder 显示"), systemImage: "arrow.up.forward.app") { NSWorkspace.shared.activateFileViewerSelecting([hit.item.asset.preferred.url]) }.labelStyle(.titleAndIcon)
                        Button(L10n.text("复制文件"), systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(hit.item.asset.files.map { $0.url as NSURL })
                        }.labelStyle(.titleAndIcon)
                        Button(L10n.text("大图浏览"), systemImage: "arrow.up.left.and.arrow.down.right") { model.selectedID = hit.id; model.large = true }.labelStyle(.titleAndIcon)
                    }
                }
            }.padding(16)
            if model.matches.isEmpty {
                ContentUnavailableView {
                    Label(L10n.text("暂无相似图片"), systemImage: "photo.stack")
                } description: { Text(L10n.text("建立更多图片向量后会出现结果；当前照片不会出现在结果中。")) }
            }
        }.frame(minWidth: 500, maxWidth: .infinity)
    }
}

private struct AISimilarPhotoPreview: View {
    let item: AICatalogItem
    @StateObject private var presentation = PreviewPresentation()
    @State private var zoom = 1.0
    @State private var fitScale = 1.0
    var body: some View {
        ZStack {
            Color.black
            PhotoCanvas(photo: presentation.photo, identity: item.id, hdr: true, zoom: $zoom, fitScale: $fitScale) { presentation.failure = $0 }
            if presentation.photo == nil {
                if let thumbnail = presentation.thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                else if let failure = presentation.failure { Text(failure).foregroundStyle(.orange).padding() }
                else { ProgressView() }
            }
        }.task(id: item.asset.fingerprint) {
            zoom = 1
            await presentation.load(item.asset.preferred, hdr: true, maximum: 2800) { _ in }
        }
    }
}
