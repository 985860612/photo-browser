import AppKit
import SwiftUI
import BrowserCore

struct PhotoClipboardMenu: View {
    @EnvironmentObject private var store: BrowserStore
    let asset: PhotoAsset
    var body: some View {
        Button { store.copyFilesToClipboard(asset) } label: {
            Label(L10n.text("复制文件到剪贴板"), systemImage: "doc.on.doc")
        }.labelStyle(.titleAndIcon).disabled(store.isMoving || store.isLoading).help("⌘C")
        if !asset.isVideo { Button { store.copyImageToClipboard(asset) } label: {
            Label(L10n.text("复制图片到剪贴板"), systemImage: "photo.on.rectangle")
        }.labelStyle(.titleAndIcon).disabled(store.isMoving || store.isLoading || store.isCopyingImage).help("⌘⇧C") }
    }
}

struct CameraRawMenu: View {
    @EnvironmentObject private var store: BrowserStore
    let asset: PhotoAsset
    var body: some View {
        if asset.isLivePhoto {
            Button(L10n.text(store.livePhotoMotionID == asset.id ? "返回照片" : "播放实况"), systemImage: store.livePhotoMotionID == asset.id ? "photo" : "livephoto.play") {
                store.toggleLivePhotoPlayback(asset)
            }.labelStyle(.titleAndIcon).disabled(store.isMoving || store.isLoading)
        } else if !asset.isVideo {
            Button(L10n.text("在 Camera Raw 中打开"), systemImage: "camera.aperture") {
                store.openInCameraRaw(asset)
            }.labelStyle(.titleAndIcon).disabled(store.isReadOnlyDirectory)
            Menu {
                ForEach(asset.imageFiles) { file in
                    Button(file.format, systemImage: "photo") { store.openInCameraRaw(asset, file: file) }
                        .labelStyle(.titleAndIcon)
                }
            } label: {
                Label(L10n.text("指定格式在 Camera Raw 中打开"), systemImage: "photo.stack")
            }.labelStyle(.titleAndIcon).disabled(store.isReadOnlyDirectory)
        } else {
            Button(L10n.text("播放视频"), systemImage: "play.rectangle") { store.playVideo(asset) }
                .labelStyle(.titleAndIcon).disabled(store.isMoving || store.isLoading)
        }
        let exports = store.livePhotoExportTargets(asset)
        if !exports.isEmpty {
            Button { store.exportLivePhotoVideo(asset) } label: {
                Label(exports.count > 1 ? L10n.text("导出 \(exports.count) 个视频…") : L10n.text("导出视频…"), systemImage: "square.and.arrow.up")
            }.labelStyle(.titleAndIcon).disabled(store.isMoving || store.isLoading || store.isExportingLivePhotoVideo)
        }
    }
}

struct MediaDeleteMenu: View {
    @EnvironmentObject private var store: BrowserStore
    let asset: PhotoAsset
    var body: some View {
        Button(L10n.text("移到 _del 待删除目录"), systemImage: "folder.badge.minus") {
            if !store.selection.contains(asset.id) { store.select(asset, modifiers: []) }
            store.deleteSelection()
        }.labelStyle(.titleAndIcon).disabled(!store.canArchive || store.isLoading)
        Button(role: .destructive) { store.confirmMediaDeletion(asset) } label: {
            Label(L10n.text("删除…"), systemImage: "trash")
        }.labelStyle(.titleAndIcon).disabled(!store.canArchive || store.isLoading || store.editingPath)
    }
}
