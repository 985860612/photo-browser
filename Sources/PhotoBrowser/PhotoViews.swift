import AppKit
import SwiftUI
import BrowserCore

struct PhotoThumbnail: View {
    let asset: PhotoAsset
    let selected: Bool
    let focused: Bool
    let height: Double
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if let image { Image(nsImage: image).resizable().scaledToFit().padding(5) }
                    else if let failure {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(failure)
                    } else { ProgressView().controlSize(.small) }
                }.frame(height: height)
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .cyan).font(.system(size: 12)).padding(8)
                }
            }
            Text(asset.name).font(.system(size: 11, weight: focused ? .semibold : .regular)).lineLimit(1)
            Text(asset.formatLabel).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(selected ? 0.09 : (hovered ? 0.045 : 0))))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Color.cyan.opacity(0.65) : (selected ? Color.white.opacity(0.16) : .clear), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
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
                    ContentUnavailableView("没有匹配的照片", systemImage: "magnifyingglass")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: store.thumbnailSize, maximum: store.thumbnailSize + 70), spacing: 12)], spacing: 14) {
                    ForEach(store.visibleAssets) { asset in
                        PhotoThumbnail(asset: asset, selected: store.selection.contains(asset.id), focused: store.focusedID == asset.id, height: store.thumbnailSize)
                            .id(asset.id)
                            .onTapGesture(count: 2) { store.select(asset, modifiers: []); store.showGroupOverview = false }
                            .onTapGesture { store.select(asset) }
                            .contextMenu {
                                Button("全屏高清预览") { store.select(asset, modifiers: []); store.toggleFullscreenPreview() }
                                Button("在 Camera Raw 中打开") { store.openInCameraRaw(asset) }
                                Menu("指定格式在 Camera Raw 中打开") {
                                    ForEach(asset.imageFiles) { file in Button(file.format) { store.openInCameraRaw(asset, file: file) } }
                                }
                                Divider()
                                Button("在 Finder 显示所有格式") { NSWorkspace.shared.activateFileViewerSelecting(asset.imageFiles.map(\.url)) }
                            }
                    }
                }.padding(15)
            }.onChange(of: store.focusedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

struct FilmstripView: View {
    @EnvironmentObject private var store: BrowserStore
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(store.visibleAssets) { asset in
                        PhotoThumbnail(asset: asset, selected: store.selection.contains(asset.id), focused: store.focusedID == asset.id, height: store.thumbnailSize - 15)
                            .frame(width: store.thumbnailSize).id(asset.id)
                            .onTapGesture { store.select(asset) }
                            .contextMenu {
                                Button("全屏高清预览") { store.select(asset, modifiers: []); store.toggleFullscreenPreview() }
                                Button("在 Camera Raw 中打开") { store.openInCameraRaw(asset) }
                                Menu("指定格式在 Camera Raw 中打开") {
                                    ForEach(asset.imageFiles) { file in Button(file.format) { store.openInCameraRaw(asset, file: file) } }
                                }
                                Button("在 Finder 显示所有格式") { NSWorkspace.shared.activateFileViewerSelecting(asset.imageFiles.map(\.url)) }
                            }
                    }
                }.padding(10)
            }
            .onChange(of: store.focusedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            .onAppear { if let id = store.focusedID { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

struct LargePreviewView: View {
    @EnvironmentObject private var store: BrowserStore
    @State private var photo: DisplayPhoto?
    @State private var thumbnail: NSImage?
    @State private var displayedFileID: String?
    @State private var loading = false
    @State private var failure: String?
    @State private var zoom: Double = 1
    @State private var fitScale: Double = 1

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    if let photo, displayedFileID == store.focusedFile?.id {
                        PhotoCanvas(photo: photo, identity: store.focusedFile?.id ?? "", hdr: store.hdrPreview, zoom: $zoom, fitScale: $fitScale) { failure = $0 }
                    } else if let thumbnail, displayedFileID == store.focusedFile?.id {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                    } else if let failure {
                        ContentUnavailableView("预览加载失败", systemImage: "photo.badge.exclamationmark", description: Text(failure))
                    } else if store.focusedFile != nil { ProgressView("加载照片…") }
                }
            }
            HStack(spacing: 10) {
                Button { store.step(-1) } label: { Image(systemName: "chevron.left") }
                Text(store.focusedFile?.url.lastPathComponent ?? "请选择照片").font(.caption).lineLimit(1)
                Button { store.step(1) } label: { Image(systemName: "chevron.right") }
                Spacer()
                if loading { ProgressView().controlSize(.small); Text("加载大图…").font(.caption2).foregroundStyle(.secondary) }
                else if let photo { Text("\(photo.isHDR ? "HDR" : "SDR") · \(photo.bitsPerComponent) 位").font(.caption2).foregroundStyle(photo.isHDR ? .cyan : .secondary) }
                if let failure, thumbnail != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(failure) }
                Toggle("HDR", isOn: $store.hdrPreview).toggleStyle(.switch).controlSize(.small)
                Button("适应") { zoom = 1 }
                Slider(value: $zoom, in: 0.1...10).frame(width: 110)
                Text("\(Int(zoom * 100))% 放大").font(.caption2).foregroundStyle(.secondary).frame(width: 85)
            }.padding(.horizontal, 14).padding(.vertical, 10).buttonStyle(.borderless)
        }
        .contextMenu {
            if let asset = store.focusedAsset {
                Button("全屏高清预览") { store.toggleFullscreenPreview() }
                Button("在 Camera Raw 中打开") { store.openInCameraRaw(asset) }
                Menu("指定格式在 Camera Raw 中打开") {
                    ForEach(asset.imageFiles) { file in Button(file.format) { store.openInCameraRaw(asset, file: file) } }
                }
                Button("在 Finder 显示") { store.revealFocused() }
            }
        }
        .task(id: (store.focusedFile?.id ?? "") + "\(store.hdrPreview)") {
            photo = nil; thumbnail = nil; displayedFileID = nil; failure = nil; zoom = 1; loading = true
            guard let file = store.focusedFile, let assetID = store.focusedID else { loading = false; return }
            do {
                let quick = try await ThumbnailCache.shared.image(file, maximum: 520)
                try Task.checkCancellation()
                thumbnail = quick.image; displayedFileID = file.id
                await Task.yield()
            } catch is CancellationError { return }
            catch { /* Continue with the original when the cached preview is unavailable. */ }
            do {
                let result = try await ThumbnailCache.shared.displayPhoto(file, hdr: store.hdrPreview, maximum: 2800)
                try Task.checkCancellation()
                photo = result; displayedFileID = file.id; loading = false; store.updateMetadata(assetID, value: result.metadata)
            } catch is CancellationError {}
            catch { failure = error.localizedDescription; loading = false }
        }
    }
}
