import AppKit
import SwiftUI
import BrowserCore

struct FilmstripView: View {
    @EnvironmentObject private var store: BrowserStore
    var thumbnailSize: Double? = nil
    private var size: Double { thumbnailSize ?? store.thumbnailSize }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    if store.scope == "all" {
                        ForEach(store.navigationEntries, id: \.path) { url in
                            DirectoryEntryCard(url: url, thumbnailHeight: size - 15) { store.load(url) }
                                .frame(width: size).id("folder:" + url.path)
                        }
                    }
                    ForEach(store.visibleAssets) { asset in
                        PhotoThumbnail(asset: asset, selected: store.selection.contains(asset.id), focused: store.focusedID == asset.id && store.selectedFolderID == nil, height: size - 15)
                            .frame(width: size).id(asset.id)
                            .background(ImmediateCardClick { count, modifiers in
                                store.select(asset, modifiers: count == 2 ? [] : modifiers)
                                if count == 2, asset.isVideo { store.video.playWhenReady(asset.preferred) }
                            })
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { store.select(asset, modifiers: []) }
                            .contextMenu {
                                PhotoClipboardMenu(asset: asset)
                                MediaDeleteMenu(asset: asset)
                                Divider()
                                Button(L10n.text(asset.isVideo ? "全屏播放" : "全屏高清预览"), systemImage: "arrow.up.left.and.arrow.down.right") {
                                    store.select(asset, modifiers: []); store.toggleFullscreenPreview()
                                }.labelStyle(.titleAndIcon)
                                CameraRawMenu(asset: asset)
                                Button(L10n.text("在 Finder 显示所有格式"), systemImage: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting(asset.mediaFiles.map(\.url))
                                }.labelStyle(.titleAndIcon)
                            }
                    }
                }.padding(10)
            }
            .onChange(of: store.navigationScrollTarget) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: store.sortingRevision) { _, _ in if let id = store.selectedItemID { proxy.scrollTo(id, anchor: .center) } }
            .onAppear {
                if store.scope == "all", let folder = store.navigationEntries.first, store.focusedID == store.visibleAssets.first?.id {
                    proxy.scrollTo("folder:" + folder.path, anchor: .leading)
                } else if let id = store.focusedID { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}
