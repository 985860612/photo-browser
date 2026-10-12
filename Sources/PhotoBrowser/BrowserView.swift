import SwiftUI
import BrowserCore

struct BrowserView: View {
    @EnvironmentObject private var store: BrowserStore
    @State private var confirmRegroup = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar()
            if hasRecovery {
                HStack {
                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.orange)
                    Text("有未完成的移动记录，请先检查并恢复文件。").font(.callout)
                    Spacer()
                    Button("查看移动记录") { store.refreshHistory(); store.showHistory = true }
                }.padding(10).background(.orange.opacity(0.1))
            }
            HSplitView {
                SidebarView().frame(minWidth: 200, idealWidth: 220, maxWidth: 290)
                center.frame(minWidth: 550, maxWidth: .infinity)
                if !store.assets.isEmpty { InspectorView().frame(minWidth: 215, idealWidth: 240, maxWidth: 290) }
            }
            Divider()
            HStack(spacing: 10) {
                if store.isLoading || store.isReadingMetadata || store.isMoving { ProgressView().controlSize(.small) }
                Text(store.status).font(.caption).lineLimit(1)
                if store.isReadingMetadata { Button("取消检测") { store.cancelMetadata() }.font(.caption) }
                Spacer()
                Text("\(store.selection.count) 张已选").font(.caption).foregroundStyle(.secondary)
                Slider(value: $store.thumbnailSize, in: 110...230).frame(width: 100).help("缩略图大小")
            }.padding(.horizontal, 15).padding(.vertical, 9)
        }
        .background(Color(red: 0.105, green: 0.115, blue: 0.13))
        .toolbar { toolbar }
        .disabled(store.isMoving)
        .onChange(of: store.scope) { _, _ in store.changeScope() }
        .sheet(item: $store.archiveGroup) { group in ArchiveSheet(group: group).environmentObject(store) }
        .sheet(item: $store.renameGroup) { group in RenameGroupSheet(group: group).environmentObject(store) }
        .sheet(isPresented: $store.showHistory) { HistorySheet().environmentObject(store) }
        .sheet(isPresented: $store.showMerge) { MergeSheet().environmentObject(store) }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .confirmationDialog("重新分组将替换当前保存的分组", isPresented: $confirmRegroup) {
            Button("读取拍摄信息并重新分组") { store.autoGroup() }
            Button("取消", role: .cancel) {}
        } message: { Text("已有的手动拆分、合并和确认状态会被新的候选组替换。原照片不会移动。") }
    }

    private var hasRecovery: Bool {
        store.history.contains { ["prepared", "moving", "undoing", "recoveryNeeded"].contains($0.state) }
    }

    @ViewBuilder private var center: some View {
        if store.directory == nil {
            ContentUnavailableView {
                Label("照片与全景，一起整理", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("打开照片目录，同名 RAW、HIF 和 JPG 会自动合并显示。")
            } actions: { Button("打开照片目录…") { store.chooseDirectory() }.buttonStyle(.borderedProminent) }
        } else if store.isLoading {
            VStack(spacing: 14) { ProgressView(); Text("正在扫描照片目录…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.assets.isEmpty {
            FolderGallery()
        } else {
            VStack(spacing: 0) {
                groupHeader
                if store.showGroupOverview { PhotoGridView() }
                else { LargePreviewView(); Divider(); FilmstripView().frame(height: store.thumbnailSize + 48) }
            }
        }
    }

    private var groupHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.currentGroup?.name ?? (store.scope == "ungrouped" ? "未分组照片" : "全部照片")).font(.headline)
                Text("\(store.visibleAssets.count) 张照片" + (store.currentGroup.map { " · \($0.confidence.rawValue)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.currentGroup != nil {
                Button("重命名…") { store.renameGroup = store.currentGroup }
                Button("确认全景") { store.confirmGroup() }
                    .disabled(store.isReadingMetadata)
                Button("归档整组…") { store.archiveGroup = store.currentGroup }
                    .buttonStyle(.borderedProminent).tint(.blue)
                    .disabled(hasRecovery || store.isReadingMetadata)
            }
            Button { store.showGroupOverview.toggle() } label: {
                Image(systemName: store.showGroupOverview ? "rectangle" : "square.grid.2x2")
            }.help(store.showGroupOverview ? "大图浏览" : "网格预览")
            Button { store.toggleFullscreenPreview() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .disabled(store.focusedFile == nil).help("全屏高清预览（空格）")
        }.padding(14)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { store.chooseDirectory() } label: { Label("打开目录", systemImage: "folder.badge.plus") }.help("打开目录 ⌘O")
            Button { if let dir = store.directory { store.load(dir) } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(store.directory == nil || store.isLoading || store.isMoving).help("刷新目录 ⌘R")
        }
        ToolbarItemGroup {
            Button { if store.groups.isEmpty { store.autoGroup() } else { confirmRegroup = true } } label: {
                Label("自动分组", systemImage: "rectangle.stack.badge.sparkles")
            }.disabled(store.assets.isEmpty || store.isReadingMetadata || store.isLoading)
            Button { store.createGroup() } label: { Label("选中成组", systemImage: "rectangle.stack.badge.plus") }
                .disabled(store.selection.count < 2 || store.isReadingMetadata).help("⌘ / ⇧ 点击多选，再按 ⌘G 成组")
            Button { store.refreshHistory(); store.showHistory = true } label: { Label("移动记录", systemImage: "clock.arrow.circlepath") }
            TextField("搜索文件名或格式", text: $store.search).textFieldStyle(.roundedBorder).frame(width: 180)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: BrowserStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $store.scope) {
                Section("照片目录") {
                    Label("全部照片  \(store.assets.count)", systemImage: "photo.on.rectangle").tag("all")
                    Label("未分组  \(store.ungroupedCount)", systemImage: "square.dashed").tag("ungrouped")
                }
                if !store.subdirectories.isEmpty {
                    Section("子文件夹") {
                        ForEach(store.subdirectories, id: \.path) { url in
                            Button { store.load(url) } label: { Label(url.lastPathComponent, systemImage: "folder").lineLimit(1) }.buttonStyle(.plain)
                        }
                    }
                }
                Section("全景与手动分组 · \(store.groups.count)") {
                    ForEach(store.groups) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: group.confidence == .candidate ? "checkmark.circle" : "rectangle.stack")
                                    .foregroundStyle(group.confidence == .candidate ? .cyan : .secondary)
                                Text(group.name).lineLimit(1)
                                Spacer()
                                Text("\(group.assetIDs.count)").foregroundStyle(.secondary)
                            }
                            Text(group.confidence.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).tag(group.id)
                            .contextMenu {
                                Button("查看整组") { store.scope = group.id; store.showGroupOverview = true }
                                Button("重命名…") { store.renameGroup = group }
                                Button("归档整组…") { store.archiveGroup = group }.disabled(store.isReadingMetadata)
                                Button("取消分组") { store.dissolveGroup(group) }.disabled(store.isReadingMetadata)
                            }
                    }
                }
            }.listStyle(.sidebar).disabled(store.isReadingMetadata && store.isMoving)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Button("导入分组 CSV…") { store.importCSV() }.disabled(store.assets.isEmpty || store.isReadingMetadata)
                Text("⌘ 点击多选 · ⇧ 点击连选\n← → 切换照片 · 空格高清全屏\n⌘L 输入路径 · 右键打开 Camera Raw")
                    .font(.caption2).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(14)
        }
    }
}
