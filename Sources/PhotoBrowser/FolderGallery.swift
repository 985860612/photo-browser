import SwiftUI
import AppKit
import BrowserCore

struct FolderGallery: View {
    @EnvironmentObject private var store: BrowserStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(store.directory?.lastPathComponent ?? "文件夹").font(.system(size: 24, weight: .semibold))
                        Text("\(store.subdirectories.count) 个子文件夹 · 双击进入浏览照片").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("上一级") { if let url = store.directory { store.load(url.deletingLastPathComponent()) } }.disabled(store.directory?.path == "/")
                }
                if store.subdirectories.isEmpty {
                    Label("此文件夹没有照片或子文件夹", systemImage: "folder").foregroundStyle(.secondary).padding(.vertical, 30)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 18)], alignment: .leading, spacing: 20) {
                        ForEach(store.subdirectories, id: \.path) { url in FolderCard(url: url) { store.load(url) } }
                    }
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FolderCard: View {
    let url: URL
    var thumbnailHeight: Double? = nil
    var open: () -> Void
    @State private var cover: NSImage?
    @State private var count: Int?
    @State private var loading = true
    @State private var failure: String?
    @State private var hovered = false
    var body: some View {
        card
            .contentShape(RoundedRectangle(cornerRadius: 13))
            .onTapGesture(count: 2) { open() }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
            .onHover { hovered = $0 }
            .help("双击打开：" + url.path)
            .contextMenu {
                Button("打开目录") { open() }
                Button("在 Finder 显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .task(id: url.path) { await loadCover() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.white.opacity(0.035)
                if let cover {
                    if thumbnailHeight != nil { Image(nsImage: cover).resizable().scaledToFit().padding(5) }
                    else { Image(nsImage: cover).resizable().scaledToFill() }
                }
                else if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "folder").font(.system(size: 42, weight: .light)).foregroundStyle(.cyan.opacity(0.7)) }
            }.frame(height: thumbnailHeight ?? 160).clipped()
            if thumbnailHeight != nil {
                VStack(spacing: 7) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill").foregroundStyle(.cyan)
                        Text(url.lastPathComponent).lineLimit(1)
                    }.font(.system(size: 11, weight: .semibold))
                    Text(failure == nil ? count.map { "\($0) 张照片" } ?? "读取中…" : "读取失败")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.top, 7).padding(.bottom, 7).frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(url.lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(failure ?? count.map { "\($0) 张照片 · 同名格式合并" } ?? "正在读取…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.padding(15)
            }
        }.background(Color.white.opacity(hovered ? 0.09 : 0.04)).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(hovered ? Color.cyan.opacity(0.6) : Color.white.opacity(0.08)))
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
