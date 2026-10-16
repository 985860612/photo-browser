import BrowserCore
import SwiftUI
import AppKit

struct NavigationBar: View {
    @EnvironmentObject private var store: BrowserStore
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 9) {
            Button { store.navigateHistory(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(!store.canGoBack).help(L10n.text("后退 ⌘["))
            Button { store.navigateHistory(1) } label: { Image(systemName: "chevron.right") }
                .disabled(!store.canGoForward).help(L10n.text("前进 ⌘]"))
            Button { store.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(store.directory == nil || store.directory?.path == "/" || store.isLoading).help(L10n.text("上一级 ⌘↑"))
            Image(systemName: store.activeDiskImage == nil ? "folder" : "opticaldisc").foregroundStyle(.blue)
            if store.editingPath {
                TextField(L10n.text("输入文件夹路径"), text: $store.pathText).textFieldStyle(.plain)
                    .font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(minHeight: 32)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.blue.opacity(0.5), lineWidth: 0.75))
                    .focusEffectDisabled()
                    .focused($focused).onSubmit { store.openTypedPath() }
                    .onExitCommand { store.editingPath = false }
                Button(L10n.text("前往")) { store.openTypedPath() }
            } else {
                ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 0) {
                                HStack(spacing: 5) {
                                    ForEach(store.breadcrumbs, id: \.path) { url in
                                        Button(url.path == "/" ? L10n.text("计算机") : url.lastPathComponent) { store.load(url) }
                                            .buttonStyle(.plain).id(url.path).help(url.path)
                                        if url != store.breadcrumbs.last { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary) }
                                    }
                                }.font(.system(size: 12)).fixedSize(horizontal: true, vertical: false)
                                Color.clear.frame(minWidth: 36, maxWidth: .infinity)
                                    .id("path-entry")
                                    .contentShape(Rectangle()).onTapGesture { store.editPath() }
                                    .help(L10n.text("点击输入或粘贴路径 ⌘L"))
                                    .accessibilityLabel(L10n.text("输入文件夹路径"))
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { store.editPath() }
                            }.frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                        }.onChange(of: store.directory, initial: true) { _, _ in proxy.scrollTo("path-entry", anchor: .trailing) }
                    }
                }.frame(height: 32)
            }
            Menu {
                ForEach(store.navigationEntries, id: \.path) { url in Button(url.lastPathComponent) { store.load(url) } }
            } label: { Image(systemName: "folder") }.disabled(store.navigationEntries.isEmpty).help(L10n.text("进入子文件夹"))
            if let image = store.activeDiskImage {
                Label(L10n.text("只读镜像"), systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                Button { store.load(image.source.deletingLastPathComponent()) } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(store.isLoading || store.isOperatingDiskImage).help(L10n.text("返回镜像所在目录"))
            }
            if !store.mountedDiskImages.isEmpty {
                Menu {
                    ForEach(store.mountedDiskImages, id: \.root) { image in
                        Button(image.source.lastPathComponent) { store.ejectDiskImage(image) }
                    }
                } label: { Label(L10n.text("推出镜像"), systemImage: "eject") }
                    .disabled(store.isOperatingDiskImage || store.isLoading || store.isMoving || store.isExportingLivePhotoVideo || store.isCopyingImage)
            }
        }.buttonStyle(.borderless).padding(.horizontal, 15).padding(.vertical, 10)
            .onChange(of: store.editingPath) { _, value in
                focused = value
                if value {
                    DispatchQueue.main.async {
                        guard store.editingPath, focused, let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                              editor.isFieldEditor else { return }
                        editor.selectAll(nil)
                    }
                }
            }
            .onChange(of: focused) { _, value in
                if !value { store.editingPath = false }
            }
    }
}
