import AppKit
import SwiftUI
import BrowserCore

struct PhotoGridView: View {
    @EnvironmentObject private var store: BrowserStore
    var body: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); PreviewSortMenu() }.padding(.horizontal, 15).padding(.top, 8)
        ScrollViewReader { proxy in
            ScrollView {
                if store.visibleAssets.isEmpty {
                    ContentUnavailableView(L10n.text("没有匹配的照片"), systemImage: "magnifyingglass")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: store.thumbnailSize, maximum: store.thumbnailSize + 70), spacing: 12)], spacing: 14) {
                    if store.scope == "all" {
                        ForEach(store.navigationEntries, id: \.path) { url in
                            DirectoryEntryCard(url: url, thumbnailHeight: store.thumbnailSize) { store.load(url) }
                                .id("folder:" + url.path)
                        }
                    }
                    ForEach(store.visibleAssets) { asset in
                        PhotoThumbnail(asset: asset, selected: store.selection.contains(asset.id), focused: store.focusedID == asset.id && store.selectedFolderID == nil, height: store.thumbnailSize)
                            .id(asset.id)
                            .background(ImmediateCardClick { count, modifiers in
                                store.select(asset, modifiers: count == 2 ? [] : modifiers)
                                if count == 2 {
                                    store.showGroupOverview = false
                                    if asset.isVideo { store.video.playWhenReady(asset.preferred) }
                                }
                            })
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { store.select(asset, modifiers: []) }
                            .contextMenu {
                                PhotoClipboardMenu(asset: asset)
                                MediaDeleteMenu(asset: asset)
                                Divider()
                                Button(L10n.text(asset.isVideo ? "全屏播放" : "全屏高清预览")) { store.select(asset, modifiers: []); store.toggleFullscreenPreview() }
                                CameraRawMenu(asset: asset)
                                Divider()
                                Button(L10n.text("在 Finder 显示所有格式")) { NSWorkspace.shared.activateFileViewerSelecting(asset.mediaFiles.map(\.url)) }
                            }
                    }
                }.scrollTargetLayout().padding(15)
            }.scrollPosition(id: $store.gridScrollID, anchor: .top)
                .onChange(of: store.navigationScrollTarget, initial: true) { _, id in
                    if let id { store.gridScrollID = id; proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: store.sortingRevision) { _, _ in
                    if let id = store.selectedItemID { store.gridScrollID = id; proxy.scrollTo(id, anchor: .center) }
                }
        }
        }
    }
}
