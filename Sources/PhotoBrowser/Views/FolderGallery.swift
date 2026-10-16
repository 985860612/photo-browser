import SwiftUI
import AppKit
import BrowserCore

struct FolderGallery: View {
    @EnvironmentObject private var store: BrowserStore
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(store.directory?.lastPathComponent ?? L10n.text("文件夹")).font(.system(size: 24, weight: .semibold))
                            Text(L10n.text("\(store.subdirectories.count) 个子文件夹 · 双击进入浏览照片")).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.text("上一级")) { if let url = store.directory { store.load(url.deletingLastPathComponent()) } }.disabled(store.directory?.path == "/")
                    }
                    if store.subdirectories.isEmpty {
                        Label(L10n.text("此文件夹没有照片或子文件夹"), systemImage: "folder").foregroundStyle(.secondary).padding(.vertical, 30)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 18)], alignment: .leading, spacing: 20) {
                            ForEach(store.subdirectories, id: \.path) { url in
                                FolderCard(url: url) { store.load(url) }.id("folder:" + url.path)
                            }
                        }
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }.onChange(of: store.navigationScrollTarget) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

struct FolderCard: View {
    @EnvironmentObject private var store: BrowserStore
    let url: URL
    var thumbnailHeight: Double? = nil
    var open: () -> Void
    @State private var cover: NSImage?
    @State private var count: Int?
    @State private var videoCount = 0
    @State private var loading = true
    @State private var failure: String?
    @State private var folderBytes: Int64?
    @State private var sizeFailure: String?
    @State private var coverFailure: String?
    @State private var coverFile: PhotoFile?
    @State private var summaryComputedAt: Date?
    @State private var sizeComputedAt: Date?
    @State private var confirmDelete = false
    var body: some View {
        card
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(store.selectedFolderID == url.path ? Color.blue.opacity(0.65) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background(ImmediateCardClick { count, _ in
                if count == 2 { open() } else { store.selectFolder(url) }
            })
            .accessibilityAddTraits(store.selectedFolderID == url.path ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { open() }
            .help(L10n.text("单击选择，双击打开：") + url.path)
            .contextMenu {
                Button(L10n.text("打开目录")) { open() }
                Button(L10n.text("在 Finder 显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(L10n.text("删除文件夹…"), systemImage: "trash")
                }.disabled(!store.canDeleteFolder(url))
            }
            .alert(L10n.text("删除文件夹“\(url.lastPathComponent)”？"), isPresented: $confirmDelete) {
                Button(L10n.text("取消"), role: .cancel) {}
                Button(L10n.text("删除"), role: .destructive) { store.deleteFolder(url, confirmed: true) }
                    .disabled(!store.canDeleteFolder(url))
            } message: {
                Text(L10n.text("将永久删除此文件夹及全部内容，无法撤销。\n路径：\(url.path)"))
            }
            .task(id: "\(url.path)|\(store.isLoading)|\(store.folderCacheRevision)") {
                if !store.isLoading { await loadCover() }
            }
            .task(id: "\(url.path)|\(store.isLoading)|\(store.folderCacheRevision)") {
                if !store.isLoading { await loadSize() }
            }
    }

    private var card: some View {
        VStack(alignment: .center, spacing: 7) {
            // The grid owns the cover size; a wide image must not widen the card.
            Color.clear.frame(height: thumbnailHeight ?? 160).overlay {
                if let cover {
                    if thumbnailHeight != nil { Image(nsImage: cover).resizable().scaledToFit().padding(5) }
                    else { Image(nsImage: cover).resizable().scaledToFill() }
                }
                else if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "folder").font(.system(size: 42, weight: .light)).foregroundStyle(.blue.opacity(0.7)) }
            }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
                Text(url.lastPathComponent).lineLimit(1)
            }.font(.system(size: thumbnailHeight != nil ? 11 : 14, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)
            HStack(spacing: 4) {
                Text(summary)
                if failure != nil || coverFailure != nil || sizeFailure != nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
                .font(.system(size: thumbnailHeight != nil ? 9 : 12)).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .help(cacheHelp)
        }.padding(7).multilineTextAlignment(.center).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var summary: String {
        let photos = count.map { L10n.text("\($0) 张照片") } ?? L10n.text(failure == nil ? "读取中…" : "读取失败")
        let size = folderBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? L10n.text(sizeFailure == nil ? "计算大小…" : "大小读取失败")
        return photos + (videoCount > 0 ? " · " + L10n.text("\(videoCount) 个视频") : "") + " · " + size
    }

    private var cacheHelp: String {
        var lines = [L10n.text("同名格式合并计数；大小包含子目录中的全部文件，不跟随符号链接")]
        if let summaryComputedAt { lines.append(L10n.text("数量与封面缓存：\(summaryComputedAt.formatted(date: .abbreviated, time: .shortened))")) }
        if let sizeComputedAt { lines.append(L10n.text("大小缓存：\(sizeComputedAt.formatted(date: .abbreviated, time: .shortened))")) }
        lines.append(L10n.text("先显示本机缓存，后台检查变化；⌘R 强制刷新"))
        for error in [failure, coverFailure, sizeFailure].compactMap({ $0 }) { lines.append(L10n.text("缓存更新失败：\(error)")) }
        return lines.joined(separator: "\n")
    }

    private func loadSize() async {
        do {
            if let cached = try await store.folderSizes.cached(of: url) {
                try Task.checkCancellation(); folderBytes = cached.value; sizeComputedAt = cached.computedAt
            }
        } catch is CancellationError { return }
        catch { sizeFailure = error.localizedDescription }
        do {
            let bytes = try await store.folderSizes.size(of: url)
            try Task.checkCancellation()
            folderBytes = bytes; sizeFailure = nil
            sizeComputedAt = try await store.folderSizes.cached(of: url)?.computedAt
        } catch is CancellationError {}
        catch { sizeFailure = error.localizedDescription }
    }

    private func loadCover() async {
        var saved: CachedFolderValue<FolderSummary>?
        do { saved = try await store.folderSummaries.cached(of: url); try Task.checkCancellation() }
        catch is CancellationError { return }
        catch { failure = error.localizedDescription }
        let validation = Task { try await store.folderSummaries.summary(of: url) }
        defer { validation.cancel() }
        if let saved { summaryComputedAt = saved.computedAt; await applySummary(saved.value) }
        do {
            let fresh = try await validation.value
            try Task.checkCancellation(); failure = nil
            await applySummary(fresh)
            summaryComputedAt = try await store.folderSummaries.cached(of: url)?.computedAt
        } catch is CancellationError {}
        catch { loading = false; failure = error.localizedDescription }
    }

    private func applySummary(_ summary: FolderSummary) async {
        guard !Task.isCancelled else { return }
        count = summary.count
        videoCount = summary.videoCount ?? 0
        guard let file = summary.cover else { cover = nil; coverFile = nil; loading = false; coverFailure = nil; return }
        if coverFile == file && cover != nil { loading = false; return }
        do {
            let image = try await ThumbnailCache.shared.image(file, maximum: 720).image
            try Task.checkCancellation(); cover = image; coverFile = file; loading = false; coverFailure = nil
        } catch is CancellationError {}
        catch { loading = false; coverFailure = error.localizedDescription }
    }
}

/// One native single-click recognizer responds immediately and also reports the second click.
/// The transparent background preserves SwiftUI hover, scrolling and context menus.
struct ImmediateCardClick: NSViewRepresentable {
    var action: (Int, NSEvent.ModifierFlags) -> Void
    func makeNSView(context: Context) -> CardClickProbeView {
        let view = CardClickProbeView(); view.action = action; return view
    }
    func updateNSView(_ view: CardClickProbeView, context: Context) { view.action = action }
    static func dismantleNSView(_ view: CardClickProbeView, coordinator: ()) { view.detach() }
}

@MainActor final class CardClickProbeView: NSView, NSGestureRecognizerDelegate {
    var action: ((Int, NSEvent.ModifierFlags) -> Void)?
    private lazy var click: CardClickRecognizer = {
        let recognizer = CardClickRecognizer(target: self, action: #selector(clicked))
        recognizer.numberOfClicksRequired = 1
        recognizer.delaysPrimaryMouseButtonEvents = false
        recognizer.delegate = self
        return recognizer
    }()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
    private func attach() {
        // SwiftUI may hit its hosting view rather than the transparent representable's parent.
        guard let host = window?.contentView else { detach(); return }
        if click.view !== host { detach(); host.addGestureRecognizer(click) }
    }
    func detach() { click.view?.removeGestureRecognizer(click) }
    @objc private func clicked() { action?(click.count, click.modifiers) }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return event.window === window && !isHiddenOrHasHiddenAncestor &&
            bounds.contains(point) && visibleRect.contains(point) && !event.modifierFlags.contains(.control)
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }
}

@MainActor final class CardClickRecognizer: NSClickGestureRecognizer {
    private(set) var count = 1
    private(set) var modifiers: NSEvent.ModifierFlags = []
    override func mouseUp(with event: NSEvent) {
        count = event.clickCount; modifiers = event.modifierFlags
        super.mouseUp(with: event)
    }
}
