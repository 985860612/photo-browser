import SwiftUI
import AppKit
import BrowserCore

/// A restrained glass background keeps contrast stable against bright desktops.
struct GlassBackdrop: View {
    var body: some View {
        ZStack {
            GlassMaterial()
            Color(red: 0.08, green: 0.09, blue: 0.105).opacity(0.78)
        }
    }
}

struct GlassMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowGlassView {
        let view = WindowGlassView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: WindowGlassView, context: Context) {}
}

final class WindowGlassView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false
        window?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.92)
        window?.appearance = NSAppearance(named: .darkAqua)
        window?.titlebarAppearsTransparent = true
        window?.toolbarStyle = .unified
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct GlassDivider: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) }
}

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
                SidebarView().frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
                center.frame(minWidth: 550, maxWidth: .infinity)
                if !store.assets.isEmpty { InspectorView().frame(minWidth: 215, idealWidth: 240, maxWidth: 290) }
            }
            GlassDivider()
            HStack(spacing: 10) {
                if store.isLoading || store.isReadingMetadata || store.isMoving { ProgressView().controlSize(.small) }
                Text(store.status).font(.caption).lineLimit(1)
                if store.isReadingMetadata { Button("取消检测") { store.cancelMetadata() }.font(.caption) }
                Spacer()
                if store.isGeneratingPreviews {
                    ProgressView(value: Double(store.previewCompleted), total: Double(max(1, store.previewTotal)))
                        .frame(width: 50)
                    Text("预览 \(store.previewCompleted)/\(store.previewTotal)").font(.caption).foregroundStyle(.secondary)
                }
                if store.previewFailures > 0 || !store.previewFailureDetails.isEmpty {
                    Label(store.previewFailures > 0 ? "\(store.previewFailures) 张预览失败" : "缓存提示", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).help(store.previewFailureDetails)
                }
                Text("\(store.selection.count) 张已选").font(.caption).foregroundStyle(.secondary)
                Slider(value: $store.thumbnailSize, in: 110...230).frame(width: 100).help("缩略图大小")
            }.padding(.horizontal, 15).padding(.vertical, 9)
        }
        .background(GlassBackdrop().ignoresSafeArea())
        .tint(.cyan)
        .controlSize(.small)
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
                if store.showGroupOverview { PhotoGridView(); GlassDivider(); overviewControls }
                else { LargePreviewView(); GlassDivider(); FilmstripView().frame(height: store.thumbnailSize + 48) }
            }
        }
    }

    private var overviewControls: some View {
        HStack(spacing: 10) {
            Spacer()
            Button { store.showGroupOverview.toggle() } label: {
                Image(systemName: store.showGroupOverview ? "rectangle" : "square.grid.2x2")
            }.help(store.showGroupOverview ? "大图浏览" : "网格预览")
            Button { store.toggleFullscreenPreview() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .disabled(store.focusedFile == nil).help("全屏高清预览（空格）")
        }.padding(.horizontal, 14).padding(.vertical, 10).buttonStyle(.borderless)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { store.chooseDirectory() } label: { Label("打开目录", systemImage: "folder.badge.plus") }.help("打开目录 ⌘O")
            Button { if let dir = store.directory { store.load(dir) } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(store.directory == nil || store.isLoading || store.isMoving).help("刷新目录 ⌘R")
        }
        ToolbarItemGroup {
            Button { if store.groups.isEmpty { store.autoGroup() } else { confirmRegroup = true } } label: {
                Label("自动分组", systemImage: "wand.and.stars")
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
        let assetSizes = Dictionary(uniqueKeysWithValues: store.assets.map { asset in
            (asset.id, asset.files.reduce(Int64(0)) { $0 + $1.size })
        })
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $store.scope) {
                Section {
                    directoryRow("全部照片", count: store.assets.count, icon: "photo.on.rectangle").tag("all")
                    directoryRow("未分组", count: store.ungroupedCount, icon: "square.dashed").tag("ungrouped")
                } header: {
                    sectionHeader("照片目录")
                }
                .listSectionSeparator(.hidden)
                Section {
                    ForEach(store.groups) { group in
                        groupRow(group, totalSize: Set(group.assetIDs).reduce(Int64(0)) { $0 + (assetSizes[$1] ?? 0) })
                            .tag(group.id)
                            .contextMenu {
                                Button("查看整组") { store.scope = group.id; store.showGroupOverview = true }
                                Button("重命名…") { store.renameGroup = group }
                                Button("移动整组到新文件夹…") { store.archiveGroup = group }.disabled(!store.canArchive)
                                Button("取消分组") { store.dissolveGroup(group) }.disabled(store.isReadingMetadata)
                            }
                    }
                } header: {
                    sectionHeader("全景与手动分组 · \(store.groups.count)")
                }
                .listSectionSeparator(.hidden)
            }.listStyle(.plain).scrollContentBackground(.hidden).tint(.gray)
                .font(.system(size: 13))
                .environment(\.defaultMinListRowHeight, 44)
                .padding(.horizontal, 8)
                .disabled(store.isReadingMetadata && store.isMoving)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.top, 16).padding(.bottom, 8).padding(.leading, 6)
    }

    private func directoryRow(_ title: String, count: Int, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
        }.frame(minHeight: 32)
            .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
            .listRowSeparator(.hidden)
    }

    private func groupRow(_ group: PhotoGroup, totalSize: Int64) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: group.confidence == .candidate ? "checkmark.circle" : "rectangle.stack")
                    .foregroundStyle(group.confidence == .candidate ? .cyan : .secondary)
                Text(group.name).lineLimit(1)
                Spacer()
                Text("\(group.assetIDs.count) 张").foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Text(group.confidence.rawValue)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)).monospacedDigit()
                    .help("组内所有格式和配套文件的总大小")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
            .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
            .listRowSeparator(.hidden)
    }
}
