import AppKit
import SwiftUI
import BrowserCore

struct PhotoClipboardMenu: View {
    @EnvironmentObject private var store: BrowserStore
    let asset: PhotoAsset
    var body: some View {
        Button { store.copyFilesToClipboard(asset) } label: {
            Label(L10n.text("复制文件到剪贴板"), systemImage: "doc.on.doc")
        }.disabled(store.isMoving || store.isLoading).help("⌘C")
        if !asset.isVideo { Button { store.copyImageToClipboard(asset) } label: {
            Label(L10n.text("复制图片到剪贴板"), systemImage: "photo.on.rectangle")
        }.disabled(store.isMoving || store.isLoading || store.isCopyingImage).help("⌘⇧C") }
    }
}

struct CameraRawMenu: View {
    @EnvironmentObject private var store: BrowserStore
    let asset: PhotoAsset
    var body: some View {
        if !asset.isVideo {
            Button(L10n.text("在 Camera Raw 中打开")) { store.openInCameraRaw(asset) }
            Menu(L10n.text("指定格式在 Camera Raw 中打开")) {
                ForEach(asset.imageFiles) { file in Button(file.format) { store.openInCameraRaw(asset, file: file) } }
            }
        } else {
            Button(L10n.text("播放视频")) { store.playVideo(asset) }.disabled(store.isMoving || store.isLoading)
        }
    }
}

struct MediaDeleteMenu: View {
    @EnvironmentObject private var store: BrowserStore
    let asset: PhotoAsset
    var body: some View {
        Button(L10n.text("移到 _del 待删除目录")) {
            if !store.selection.contains(asset.id) { store.select(asset, modifiers: []) }
            store.deleteSelection()
        }.disabled(!store.canArchive || store.isLoading)
        Button(role: .destructive) { store.confirmMediaDeletion(asset) } label: {
            Label(L10n.text("删除…"), systemImage: "trash")
        }.disabled(!store.canArchive || store.isLoading || store.editingPath)
    }
}
