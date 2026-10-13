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
    @State private var loading = true
    @State private var failure: String?
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
            }
            .task(id: url.path) { await loadCover() }
    }

    private var card: some View {
        VStack(alignment: .center, spacing: 7) {
            ZStack {
                if let cover {
                    if thumbnailHeight != nil { Image(nsImage: cover).resizable().scaledToFit().padding(5) }
                    else { Image(nsImage: cover).resizable().scaledToFill() }
                }
                else if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "folder").font(.system(size: 42, weight: .light)).foregroundStyle(.blue.opacity(0.7)) }
            }.frame(maxWidth: .infinity, alignment: .center).frame(height: thumbnailHeight ?? 160).clipped()
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
                Text(url.lastPathComponent).lineLimit(1)
            }.font(.system(size: thumbnailHeight != nil ? 11 : 14, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)
            Text(failure == nil ? count.map { L10n.text("\($0) 张照片") } ?? L10n.text("读取中…") : L10n.text("读取失败"))
                .font(.system(size: thumbnailHeight != nil ? 9 : 12)).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .help(failure ?? L10n.text("同名 RAW / HIF / JPG 合并计数"))
        }.padding(7).multilineTextAlignment(.center).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func loadCover() async {
        do {
            let summary = try await Task.detached(priority: .utility) { () -> (Int, PhotoFile?) in
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                let candidates = children.filter { DirectoryScanner.rawExtensions.union(DirectoryScanner.renderedExtensions).contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                let count = Set(candidates.map { $0.deletingPathExtension().lastPathComponent.lowercased() }).count
                guard let file = candidates.first(where: { DirectoryScanner.renderedExtensions.contains($0.pathExtension.lowercased()) }) ?? candidates.first else { return (count, nil) }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true else { return (count, nil) }
                return (count, PhotoFile(url: file, kind: DirectoryScanner.rawExtensions.contains(file.pathExtension.lowercased()) ? .raw : .rendered,
                                         size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
            }.value
            try Task.checkCancellation(); count = summary.0
            if let file = summary.1 { cover = try await ThumbnailCache.shared.image(file, maximum: 720).image }
            loading = false
        } catch is CancellationError {}
        catch { loading = false; failure = error.localizedDescription }
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
