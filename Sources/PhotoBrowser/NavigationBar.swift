import SwiftUI

struct NavigationBar: View {
    @EnvironmentObject private var store: BrowserStore
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 9) {
            Button { store.navigateHistory(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(!store.canGoBack).help("后退 ⌘[")
            Button { store.navigateHistory(1) } label: { Image(systemName: "chevron.right") }
                .disabled(!store.canGoForward).help("前进 ⌘]")
            Button { if let url = store.directory { store.load(url.deletingLastPathComponent()) } } label: { Image(systemName: "arrow.up") }
                .disabled(store.directory == nil || store.directory?.path == "/" || store.isLoading).help("上一级 ⌘↑")
            Image(systemName: "folder").foregroundStyle(.cyan)
            if store.editingPath {
                TextField("输入文件夹路径", text: $store.pathText).textFieldStyle(.roundedBorder)
                    .focused($focused).onSubmit { store.openTypedPath() }
                    .onExitCommand { store.editingPath = false }
                Button("前往") { store.openTypedPath() }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(store.breadcrumbs, id: \.path) { url in
                                Button(url.path == "/" ? "计算机" : url.lastPathComponent) { store.load(url) }
                                    .buttonStyle(.plain).id(url.path).help(url.path)
                                if url != store.directory { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary) }
                            }
                        }.font(.system(size: 12))
                    }.onChange(of: store.directory, initial: true) { _, url in if let url { proxy.scrollTo(url.path, anchor: .trailing) } }
                }
                Button { store.editPath() } label: { Image(systemName: "pencil") }.help("编辑路径 ⌘L")
            }
            Menu {
                ForEach(store.subdirectories, id: \.path) { url in Button(url.lastPathComponent) { store.load(url) } }
            } label: { Image(systemName: "folder") }.disabled(store.subdirectories.isEmpty).help("进入子文件夹")
        }.buttonStyle(.borderless).padding(.horizontal, 15).padding(.vertical, 10)
            .onChange(of: store.editingPath) { _, value in focused = value }
    }
}
