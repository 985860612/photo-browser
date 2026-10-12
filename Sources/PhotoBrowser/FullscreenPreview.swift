import SwiftUI
import AppKit
import BrowserCore

struct FullscreenPreview: View {
    @EnvironmentObject private var store: BrowserStore
    @State private var photo: DisplayPhoto?
    @State private var thumbnail: NSImage?
    @State private var displayedFileID: String?
    @State private var failure: String?
    @State private var loading = false
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
            .onDisappear { hideControlsTask?.cancel() }
            .onChange(of: store.focusedFile?.id) { _, _ in revealControls() }
            .onExitCommand { store.closeFullscreenPreview() }
            .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("知道了") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in store.fullscreenWindowExited() }
            .contextMenu {
                if let asset = store.focusedAsset {
                    Button("在 Camera Raw 中打开") { store.openInCameraRaw(asset) }
                    Button("在 Finder 显示") { store.revealFocused() }
                }
            }
            .task(id: (store.focusedFile?.id ?? "") + "\(store.hdrPreview)") {
                photo = nil; thumbnail = nil; displayedFileID = nil; failure = nil; zoom = 1; loading = true
                guard let file = store.focusedFile else { loading = false; return }
                let assetID = store.focusedID
                do {
                    let quick = try await ThumbnailCache.shared.image(file, maximum: 520)
                    try Task.checkCancellation()
                    thumbnail = quick.image; displayedFileID = file.id
                    await Task.yield()
                } catch is CancellationError { return }
                catch { /* A failed thumbnail must not prevent the original from being decoded. */ }
                do {
                    let result = try await ThumbnailCache.shared.displayPhoto(file, hdr: store.hdrPreview)
                    try Task.checkCancellation()
                    photo = result; displayedFileID = file.id; loading = false
                    if let assetID { store.updateMetadata(assetID, value: result.metadata) }
                } catch is CancellationError {}
                catch { failure = error.localizedDescription; loading = false }
            }
    }

    private var canvas: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let photo, displayedFileID == store.focusedFile?.id {
                PhotoCanvas(photo: photo, identity: store.focusedFile?.id ?? "", hdr: store.hdrPreview, zoom: $zoom, fitScale: $fitScale) { failure = $0 }
                    .ignoresSafeArea()
            } else if let thumbnail, displayedFileID == store.focusedFile?.id {
                Image(nsImage: thumbnail).resizable().scaledToFit().ignoresSafeArea()
            }
            if let failure {
                VStack {
                    Spacer()
                    Label("高清加载失败：" + failure, systemImage: "exclamationmark.triangle")
                        .font(.callout).padding(12).background(.black.opacity(0.75))
                        .padding(.bottom, controlsVisible ? 60 : 20)
                }
            } else if photo == nil && thumbnail == nil { ProgressView("加载照片预览…") }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            topControls
            Spacer(minLength: 0)
            bottomControls
        }
        .buttonStyle(.plain).foregroundStyle(.white).tint(.white)
        .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    private var topControls: some View {
        HStack {
            Button { store.closeFullscreenPreview() } label: { Label("退出全屏", systemImage: "arrow.down.right.and.arrow.up.left") }
            Text(store.focusedFile?.url.lastPathComponent ?? "").font(.headline).lineLimit(1)
            Spacer()
            Toggle("HDR", isOn: $store.hdrPreview).toggleStyle(.switch).controlSize(.small).help("启用原图 HDR / EDR 显示；普通照片保持 SDR")
            Toggle("RAW 优先", isOn: $store.preferRawPreview).toggleStyle(.switch).controlSize(.small)
                .help("开启时优先预览 RAW，关闭时优先预览 HIF/JPG")
            if let asset = store.focusedAsset {
                ForEach(asset.imageFiles) { file in
                    Button(file.format) { store.preferredFileID = file.id }
                        .foregroundStyle(file.id == store.focusedFile?.id ? Color.white : Color.white.opacity(0.5))
                }
            }
            if loading { ProgressView().controlSize(.small); Text("加载高清原图…").font(.caption) }
            else if let photo {
                Text("\(Int(photo.size.width)) × \(Int(photo.size.height)) · \(photo.isHDR ? "HDR" : "SDR") · \(photo.bitsPerComponent) 位").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).onHover { hoveringControls = $0; revealControls() }
    }

    private var bottomControls: some View {
        HStack(spacing: 16) {
            Button { store.step(-1) } label: { Image(systemName: "chevron.left") }
                .help("上一张（←）")
            Text("\((store.visibleAssets.firstIndex { $0.id == store.focusedID } ?? 0) + 1) / \(store.visibleAssets.count)").font(.caption)
            Button { store.step(1) } label: { Image(systemName: "chevron.right") }
                .help("下一张（→）")
            Spacer()
            Button("适应屏幕") { zoom = 1 }
            Button("100% 像素") { setPixelZoom(scale: fitScale, toggle: false) }.disabled(loading || photo == nil)
            Slider(value: $zoom, in: 0.1...10).frame(width: 100)
                .help("捏合缩放 · 滚动 / 拖拽平移 · ⌘滚轮缩放 · Esc 退出")
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
