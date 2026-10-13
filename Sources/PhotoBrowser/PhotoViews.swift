import AppKit
import SwiftUI
import BrowserCore

struct PhotoThumbnail: View {
    @EnvironmentObject private var store: BrowserStore
    let asset: PhotoAsset
    let selected: Bool
    let focused: Bool
    let height: Double
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                if let image { Image(nsImage: image).resizable().scaledToFit().padding(5) }
                else if let failure {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(failure)
                } else { ProgressView().controlSize(.small) }
            }.frame(maxWidth: .infinity).frame(height: height)
            Text(asset.name).font(.system(size: 11, weight: focused ? .semibold : .regular)).lineLimit(1)
            Text(asset.formatLabel).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(selected ? 0.09 : (hovered ? 0.045 : 0))))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(focused ? Color.cyan.opacity(0.65) : (selected ? Color.white.opacity(0.16) : .clear), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onAppear { store.previewAppeared(asset) }
        .task(id: asset.preferred.id + "\(asset.preferred.modified.timeIntervalSince1970)") {
            do { image = try await ThumbnailCache.shared.image(asset.preferred, maximum: 520).image; failure = nil }
            catch is CancellationError {}
            catch { failure = error.localizedDescription }
        }
    }
}

struct PhotoGridView: View {
    @EnvironmentObject private var store: BrowserStore
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if store.visibleAssets.isEmpty {
                    ContentUnavailableView(L10n.text("没有匹配的照片"), systemImage: "magnifyingglass")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: store.thumbnailSize, maximum: store.thumbnailSize + 70), spacing: 12)], spacing: 14) {
                    if store.scope == "all" {
                        ForEach(store.subdirectories, id: \.path) { url in
                            FolderCard(url: url, thumbnailHeight: store.thumbnailSize) { store.load(url) }
                                .id("folder:" + url.path)
                        }
                    }
                    ForEach(store.visibleAssets) { asset in
                        PhotoThumbnail(asset: asset, selected: store.selection.contains(asset.id), focused: store.focusedID == asset.id && store.selectedFolderID == nil, height: store.thumbnailSize)
                            .id(asset.id)
                            .background(ImmediateCardClick { count, modifiers in
                                store.select(asset, modifiers: count == 2 ? [] : modifiers)
                                if count == 2 { store.showGroupOverview = false }
                            })
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { store.select(asset, modifiers: []) }
                            .contextMenu {
                                Button(L10n.text("全屏高清预览")) { store.select(asset, modifiers: []); store.toggleFullscreenPreview() }
                                Button(L10n.text("在 Camera Raw 中打开")) { store.openInCameraRaw(asset) }
                                Menu(L10n.text("指定格式在 Camera Raw 中打开")) {
                                    ForEach(asset.imageFiles) { file in Button(file.format) { store.openInCameraRaw(asset, file: file) } }
                                }
                                Divider()
                                Button(L10n.text("在 Finder 显示所有格式")) { NSWorkspace.shared.activateFileViewerSelecting(asset.imageFiles.map(\.url)) }
                            }
                    }
                }.padding(15)
            }.onChange(of: store.navigationScrollTarget) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

struct FilmstripView: View {
    @EnvironmentObject private var store: BrowserStore
    var thumbnailSize: Double? = nil
    private var size: Double { thumbnailSize ?? store.thumbnailSize }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    if store.scope == "all" {
                        ForEach(store.subdirectories, id: \.path) { url in
                            FolderCard(url: url, thumbnailHeight: size - 15) { store.load(url) }
                                .frame(width: size).id("folder:" + url.path)
                        }
                    }
                    ForEach(store.visibleAssets) { asset in
                        PhotoThumbnail(asset: asset, selected: store.selection.contains(asset.id), focused: store.focusedID == asset.id && store.selectedFolderID == nil, height: size - 15)
                            .frame(width: size).id(asset.id)
                            .background(ImmediateCardClick { count, modifiers in
                                if count == 1 { store.select(asset, modifiers: modifiers) }
                            })
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { store.select(asset, modifiers: []) }
                            .contextMenu {
                                Button(L10n.text("全屏高清预览")) { store.select(asset, modifiers: []); store.toggleFullscreenPreview() }
                                Button(L10n.text("在 Camera Raw 中打开")) { store.openInCameraRaw(asset) }
                                Menu(L10n.text("指定格式在 Camera Raw 中打开")) {
                                    ForEach(asset.imageFiles) { file in Button(file.format) { store.openInCameraRaw(asset, file: file) } }
                                }
                                Button(L10n.text("在 Finder 显示所有格式")) { NSWorkspace.shared.activateFileViewerSelecting(asset.imageFiles.map(\.url)) }
                            }
                    }
                }.padding(10)
            }
            .onChange(of: store.navigationScrollTarget) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            .onAppear {
                if store.scope == "all", let folder = store.subdirectories.first, store.focusedID == store.visibleAssets.first?.id {
                    proxy.scrollTo("folder:" + folder.path, anchor: .leading)
                } else if let id = store.focusedID { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

struct LargePreviewView: View {
    @EnvironmentObject private var store: BrowserStore
    @StateObject private var preview = PreviewPresentation()
    private var photo: DisplayPhoto? { preview.photo }
    private var thumbnail: NSImage? { preview.thumbnail }
    private var loading: Bool { preview.loading }
    private var failure: String? { preview.failure }
    @State private var zoom: Double = 1
    @State private var fitScale: Double = 1

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    PhotoCanvas(photo: preview.fileID == store.focusedFile?.id ? photo : nil,
                                identity: store.focusedFile?.id ?? "", hdr: store.hdrPreview, zoom: $zoom, fitScale: $fitScale) { preview.failure = $0 }
                        .opacity(photo != nil && preview.fileID == store.focusedFile?.id ? 1 : 0)
                    if photo == nil, let thumbnail, preview.fileID == store.focusedFile?.id {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                    } else if photo == nil, let failure {
                        ContentUnavailableView(L10n.text("预览加载失败"), systemImage: "photo.badge.exclamationmark", description: Text(failure))
                    } else if photo == nil, store.focusedFile != nil { ProgressView(L10n.text("加载照片…")) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 8) {
                Button { store.step(-1) } label: { Image(systemName: "chevron.left") }
                Text(store.focusedFile?.url.lastPathComponent ?? L10n.text("请选择照片")).lineLimit(1)
                    .help(store.focusedFile?.url.lastPathComponent ?? L10n.text("请选择照片"))
                Button { store.step(1) } label: { Image(systemName: "chevron.right") }
                Spacer()
                if loading { ProgressView().controlSize(.small).help(L10n.text("正在加载高清图")) }
                if let failure, thumbnail != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(failure) }
                Toggle("HDR", isOn: $store.hdrPreview).toggleStyle(.switch)
                    .help(photo.map { L10n.text("原图 \($0.isHDR ? "HDR" : "SDR") · \($0.bitsPerComponent) 位") } ?? L10n.text("HDR / EDR 预览"))
                Toggle(L10n.text("RAW 优先"), isOn: $store.preferRawPreview).toggleStyle(.switch)
                    .help(L10n.text("开启时优先预览 RAW，关闭时优先预览 HIF/JPG；缺少对应格式时自动使用已有格式"))
                Button(L10n.text("适应")) { zoom = 1 }
                Slider(value: $zoom, in: 0.1...10).frame(width: 70).help(L10n.text("缩放"))
                Text("\(Int(zoom * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40)
                Button { store.showGroupOverview = true } label: { Image(systemName: "square.grid.2x2") }.help(L10n.text("网格预览"))
                Button { store.toggleFullscreenPreview() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .disabled(store.focusedFile == nil).help(L10n.text("全屏高清预览（空格）"))
            }.font(.system(size: 12)).controlSize(.mini)
                .padding(.horizontal, 14).padding(.vertical, 8).buttonStyle(.borderless)
        }
        .contextMenu {
            if let asset = store.focusedAsset {
                Button(L10n.text("全屏高清预览")) { store.toggleFullscreenPreview() }
                Button(L10n.text("在 Camera Raw 中打开")) { store.openInCameraRaw(asset) }
                Menu(L10n.text("指定格式在 Camera Raw 中打开")) {
                    ForEach(asset.imageFiles) { file in Button(file.format) { store.openInCameraRaw(asset, file: file) } }
                }
                Button(L10n.text("在 Finder 显示")) { store.revealFocused() }
            }
        }
        .onDisappear { store.cancelAdjacentPreviews() }
        .task(id: store.previewRequestID) {
            if preview.fileID != store.focusedFile?.id { zoom = 1 }
            await store.preparePreviewCache()
            let assetID = store.focusedID
            await preview.load(store.selectedFolderID == nil ? store.focusedFile : nil, hdr: store.hdrPreview, maximum: 2800) { metadata in
                if let assetID { store.updateMetadata(assetID, value: metadata) }
            }
        }
    }
}
