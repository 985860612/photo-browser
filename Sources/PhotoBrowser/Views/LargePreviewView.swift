import AppKit
import SwiftUI
import BrowserCore

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
                    if let file = store.playbackFile, !store.isMoving, !store.isLoading {
                        VideoPreviewView(file: file, playback: store.video)
                    } else {
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
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 8) {
                Button { store.step(-1) } label: { Image(systemName: "chevron.left") }
                Text(store.focusedFile?.url.lastPathComponent ?? L10n.text("请选择照片")).lineLimit(1)
                    .help(store.focusedFile?.url.lastPathComponent ?? L10n.text("请选择照片"))
                Button { store.step(1) } label: { Image(systemName: "chevron.right") }
                Spacer()
                if store.playbackFile == nil {
                if loading { ProgressView().controlSize(.small).help(L10n.text("正在加载高清图")) }
                if let failure, thumbnail != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(failure) }
                Toggle("HDR", isOn: $store.hdrPreview).toggleStyle(.switch)
                    .help(photo.map { L10n.text("原图 \($0.isHDR ? "HDR" : "SDR") · \($0.bitsPerComponent) 位") } ?? L10n.text("HDR / EDR 预览"))
                Toggle(L10n.text("RAW 优先"), isOn: $store.preferRawPreview).toggleStyle(.switch)
                    .help(L10n.text("开启时优先预览 RAW，关闭时优先预览 HIF/JPG；缺少对应格式时自动使用已有格式"))
                Button(L10n.text("适应")) { zoom = 1 }
                Slider(value: $zoom, in: 0.1...10).frame(width: 70).help(L10n.text("缩放"))
                Text("\(Int(zoom * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40)
                }
                PreviewSortMenu()
                if store.focusedAsset?.isLivePhoto == true {
                    Button(L10n.text(store.livePhotoMotionID == store.focusedID ? "返回照片" : "播放实况")) { store.toggleLivePhotoPlayback() }
                }
                Button { store.showGroupOverview = true } label: { Image(systemName: "square.grid.2x2") }.help(L10n.text("网格预览"))
                Button { store.toggleFullscreenPreview() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .disabled(store.focusedFile == nil).help(L10n.text(store.focusedFile?.kind == .video ? "全屏播放" : "全屏高清预览（空格）"))
            }.font(.system(size: 12)).controlSize(.mini)
                .padding(.horizontal, 14).padding(.vertical, 8).buttonStyle(.borderless)
        }
        .contextMenu {
            if let asset = store.focusedAsset {
                PhotoClipboardMenu(asset: asset)
                MediaDeleteMenu(asset: asset)
                Divider()
                Button(L10n.text(asset.isVideo ? "全屏播放" : "全屏高清预览")) { store.toggleFullscreenPreview() }
                CameraRawMenu(asset: asset)
                Button(L10n.text("在 Finder 显示")) { store.revealFocused() }
            }
        }
        .onDisappear { store.cancelAdjacentPreviews() }
        .task(id: store.previewRequestID) {
            if preview.fileID != store.focusedFile?.id { zoom = 1 }
            await store.preparePreviewCache()
            let assetID = store.focusedID
            await preview.load(store.selectedFolderID == nil && store.playbackFile == nil ? store.focusedFile : nil, hdr: store.hdrPreview, maximum: 2800) { metadata in
                if let assetID { store.updateMetadata(assetID, value: metadata) }
            }
        }
    }
}
