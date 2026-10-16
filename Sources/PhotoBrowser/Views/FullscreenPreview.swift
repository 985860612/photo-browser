import SwiftUI
import AppKit
import BrowserCore

struct FullscreenPreview: View {
    @EnvironmentObject private var store: BrowserStore
    @StateObject private var preview = PreviewPresentation()
    private var photo: DisplayPhoto? { preview.photo }
    private var thumbnail: NSImage? { preview.thumbnail }
    private var failure: String? { preview.failure }
    private var loading: Bool { preview.loading }
    @State private var zoom: Double = 1
    @State private var fitScale: Double = 1
    @State private var controlsVisible = true
    @State private var hoveringControls = false
    @State private var hideControlsTask: Task<Void, Never>?
    var body: some View {
        canvas.overlay { controls }
            .onContinuousHover { phase in
                if case .active = phase { revealControls() }
            }
            .onAppear { revealControls() }
            .onDisappear { hideControlsTask?.cancel(); store.cancelAdjacentPreviews() }
            .onChange(of: store.focusedFile?.id) { _, _ in revealControls() }
            .onExitCommand { store.closeFullscreenPreview() }
            .alert(L10n.text("操作未完成"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button(L10n.text("知道了")) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in store.fullscreenWindowExited() }
            .contextMenu {
                if let asset = store.focusedAsset {
                    PhotoClipboardMenu(asset: asset)
                    MediaDeleteMenu(asset: asset)
                    Divider()
                    CameraRawMenu(asset: asset)
                    Button(L10n.text("在 Finder 显示"), systemImage: "folder") { store.revealFocused() }.labelStyle(.titleAndIcon)
                }
            }
            .task(id: store.previewRequestID) {
                if preview.fileID != store.focusedFile?.id { zoom = 1 }
                await store.preparePreviewCache()
                let assetID = store.focusedID
                await preview.load(store.playbackFile != nil ? nil : store.focusedFile, hdr: store.hdrPreview, maximum: nil) { metadata in
                    if let assetID { store.updateMetadata(assetID, value: metadata) }
                }
            }
    }

    private var canvas: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let file = store.playbackFile, !store.isMoving, !store.isLoading {
                VideoPreviewView(file: file, playback: store.video).ignoresSafeArea()
            } else {
            PhotoCanvas(photo: preview.fileID == store.focusedFile?.id ? photo : nil,
                        identity: store.focusedFile?.id ?? "", hdr: store.hdrPreview, zoom: $zoom, fitScale: $fitScale) { preview.failure = $0 }
                .ignoresSafeArea().opacity(photo != nil && preview.fileID == store.focusedFile?.id ? 1 : 0)
            if photo == nil, let thumbnail, preview.fileID == store.focusedFile?.id {
                Image(nsImage: thumbnail).resizable().scaledToFit().ignoresSafeArea()
            }
            if let failure {
                VStack {
                    Spacer()
                    Label(L10n.text("高清加载失败：") + failure, systemImage: "exclamationmark.triangle")
                        .font(.callout).padding(12).background(.black.opacity(0.75))
                        .padding(.bottom, controlsVisible ? 60 : 20)
                }
            } else if photo == nil && thumbnail == nil { ProgressView(L10n.text("加载照片预览…")) }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            topControls
            Spacer(minLength: 0)
            bottomControls
        }
        .font(.system(size: 12)).controlSize(.mini)
        .buttonStyle(.plain).foregroundStyle(.white).tint(.white)
        .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    private var topControls: some View {
        HStack {
            Button { store.closeFullscreenPreview() } label: { Label(L10n.text("退出全屏"), systemImage: "arrow.down.right.and.arrow.up.left") }
            Text(store.focusedFile?.url.lastPathComponent ?? "").lineLimit(1)
            Spacer()
            if store.playbackFile == nil {
            Toggle("HDR", isOn: $store.hdrPreview).toggleStyle(.switch).help(L10n.text("启用原图 HDR / EDR 显示；普通照片保持 SDR"))
            Toggle(L10n.text("RAW 优先"), isOn: $store.preferRawPreview).toggleStyle(.switch)
                .help(L10n.text("开启时优先预览 RAW，关闭时优先预览 HIF/JPG"))
            if let asset = store.focusedAsset {
                ForEach(asset.imageFiles) { file in
                    Button(file.format) { store.preferredFileID = file.id }
                        .foregroundStyle(file.id == store.focusedFile?.id ? Color.white : Color.white.opacity(0.5))
                }
            }
            if loading { ProgressView().controlSize(.small); Text(L10n.text("加载高清原图…")) }
            else if let photo {
                Text(L10n.text("\(Int(photo.size.width)) × \(Int(photo.size.height)) · \(photo.isHDR ? "HDR" : "SDR") · \(photo.bitsPerComponent) 位")).foregroundStyle(.secondary)
            }
            }
        }.padding(20).onHover { hoveringControls = $0; revealControls() }
    }

    private var bottomControls: some View {
        HStack(spacing: 16) {
            Button { store.step(-1) } label: { Image(systemName: "chevron.left") }
                .help(L10n.text("上一张（←）"))
            Text("\((store.visibleAssets.firstIndex { $0.id == store.focusedID } ?? 0) + 1) / \(store.visibleAssets.count)").monospacedDigit()
            Button { store.step(1) } label: { Image(systemName: "chevron.right") }
                .help(L10n.text("下一张（→）"))
            Spacer()
            if store.focusedAsset?.isLivePhoto == true {
                Button(L10n.text(store.livePhotoMotionID == store.focusedID ? "返回照片" : "播放实况")) { store.toggleLivePhotoPlayback() }
            }
            Button(L10n.text("适应屏幕")) { zoom = 1 }
            Button(L10n.text("100% 像素")) { setPixelZoom(scale: fitScale, toggle: false) }.disabled(loading || photo == nil)
            Slider(value: $zoom, in: 0.1...10).frame(width: 100)
                .help(L10n.text("捏合缩放 · 滚动 / 拖拽平移 · ⌘滚轮缩放 · Esc 退出"))
        }.padding(20).onHover { hoveringControls = $0; revealControls() }
    }
    private func revealControls() {
        hideControlsTask?.cancel()
        controlsVisible = true
        guard !hoveringControls else { return }
        hideControlsTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard !Task.isCancelled, !hoveringControls else { return }
            controlsVisible = false
        }
    }
    private func setPixelZoom(scale: Double, toggle: Bool = true) {
        let backingScale = NSApp.keyWindow?.backingScaleFactor ?? 2
        zoom = toggle && zoom != 1 ? 1 : min(10, max(0.1, 1 / (scale * backingScale)))
    }
}
