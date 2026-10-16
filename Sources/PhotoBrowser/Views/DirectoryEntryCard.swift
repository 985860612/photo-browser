import AppKit
import SwiftUI
import BrowserCore

struct DirectoryEntryCard: View {
    let url: URL
    var thumbnailHeight: Double? = nil
    let open: () -> Void

    var body: some View {
        if DiskImageService.supports(url) && !url.hasDirectoryPath {
            DiskImageCard(url: url, thumbnailHeight: thumbnailHeight, open: open)
        } else { FolderCard(url: url, thumbnailHeight: thumbnailHeight, open: open) }
    }
}

private struct DiskImageCard: View {
    @EnvironmentObject private var store: BrowserStore
    let url: URL
    let thumbnailHeight: Double?
    let open: () -> Void
    @State private var bytes: Int64?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 7) {
            Color.clear.frame(height: thumbnailHeight ?? 160).overlay {
                Image(systemName: "opticaldisc").font(.system(size: thumbnailHeight == nil ? 58 : 40, weight: .light))
                    .foregroundStyle(.blue.opacity(0.8))
            }
            Label(url.lastPathComponent, systemImage: "opticaldisc").lineLimit(1)
                .font(.system(size: thumbnailHeight == nil ? 14 : 11, weight: .semibold))
            Text(bytes.map { "ISO · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                 ?? L10n.text(failure == nil ? "读取中…" : "读取失败"))
                .font(.system(size: thumbnailHeight == nil ? 12 : 9)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity).padding(7)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(store.selectedFolderID == url.path ? Color.blue.opacity(0.65) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .background(ImmediateCardClick { count, _ in if count == 2 { open() } else { store.selectFolder(url) } })
            .accessibilityAddTraits(store.selectedFolderID == url.path ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { open() }
            .help(failure ?? (L10n.text("双击只读加载镜像：") + url.path))
            .contextMenu {
                Button(L10n.text("只读打开镜像")) { open() }.disabled(store.isOperatingDiskImage)
                Button(L10n.text("在 Finder 显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if let image = store.mountedDiskImages.first(where: { $0.source == url.resolvingSymlinksInPath() }) {
                    Button(L10n.text("推出镜像")) { store.ejectDiskImage(image) }
                        .disabled(store.isOperatingDiskImage || store.isLoading || store.isMoving || store.isExportingLivePhotoVideo || store.isCopyingImage)
                }
            }
            .task(id: "\(url.path)|\(store.folderCacheRevision)") {
                do {
                    bytes = try await Task.detached(priority: .utility) {
                        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                    }.value
                    failure = nil
                } catch { failure = error.localizedDescription }
            }
    }
}
