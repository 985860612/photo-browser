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
        if let window, window.frameAutosaveName.isEmpty {
            window.setFrameUsingName("PhotoBrowser.MainWindow")
            window.setFrameAutosaveName("PhotoBrowser.MainWindow")
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct GlassDivider: View {
    var inset: CGFloat = 15
    var body: some View {
        Capsule().fill(Color.white.opacity(0.07)).frame(height: 0.5)
            .padding(.horizontal, inset)
    }
}

struct BrowserView: View {
    @EnvironmentObject private var store: BrowserStore
    @State private var confirmRegroup = false
    @State private var filmstripDragStart: Double?
    @State private var panelDragStart: Double?
    @FocusState private var searchFocused: Bool
    @AppStorage("showDirectoryPanel") private var showDirectoryPanel = true
    @AppStorage("showInspectorPanel") private var showInspectorPanel = true
    @AppStorage("directoryPanelWidth") private var directoryPanelWidth = 250.0
    @AppStorage("inspectorPanelWidth") private var inspectorPanelWidth = 240.0

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar()
            GlassDivider()
            if hasRecovery {
                HStack {
                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.orange)
                    Text(L10n.text("有未完成的移动记录，请先检查并恢复文件。")).font(.callout)
                    Spacer()
                    Button(L10n.text("查看移动记录")) { store.refreshHistory(); store.showHistory = true }
                }.padding(10).background(.orange.opacity(0.1))
            }
            GeometryReader { geometry in
                let inspectorVisible = showInspectorPanel && !store.assets.isEmpty
                let layout = BrowserPanelLayout(available: geometry.size.width, directoryWidth: directoryPanelWidth,
                                                inspectorWidth: inspectorPanelWidth, showDirectory: showDirectoryPanel,
                                                showInspector: inspectorVisible)
                HStack(spacing: 0) {
                    if showDirectoryPanel {
                        SidebarView().frame(width: layout.directory)
                        panelDivider(width: $directoryPanelWidth, actualWidth: layout.directory,
                                     range: BrowserPanelLayout.directoryRange, direction: 1,
                                     maximum: geometry.size.width - 550 - layout.inspector - (inspectorVisible ? 12 : 6))
                    }
                    center.frame(minWidth: 550, maxWidth: .infinity, maxHeight: .infinity)
                    if inspectorVisible {
                        panelDivider(width: $inspectorPanelWidth, actualWidth: layout.inspector,
                                     range: BrowserPanelLayout.inspectorRange, direction: -1,
                                     maximum: geometry.size.width - 550 - layout.directory - (showDirectoryPanel ? 12 : 6))
                        InspectorView().frame(width: layout.inspector)
                    }
                }
            }
            GlassDivider()
            HStack(spacing: 10) {
                if store.isLoading || store.isReadingMetadata || store.isMoving { ProgressView().controlSize(.small) }
                if store.directory != nil && !store.isLoading {
                    Text(store.directorySummary).font(.caption).monospacedDigit().lineLimit(1).layoutPriority(1)
                }
                if !store.status.isEmpty {
                    if store.directory != nil && !store.isLoading { Text("·").foregroundStyle(.secondary) }
                    Text(store.status).font(.caption).lineLimit(1).help(store.status)
                }
                if store.isReadingMetadata { Button(L10n.text("取消检测")) { store.cancelMetadata() }.font(.caption) }
                Spacer()
                if store.adjacentTotal > 0 && !store.showGroupOverview {
                    Text(L10n.text("相邻就绪 \(store.adjacentReady)/\(store.adjacentTotal)"))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .help(L10n.text("实际保留在内存中的相邻大图；内存不足时可能小于预加载数量"))
                }
                if store.adjacentVideoTotal > 0 && !store.showGroupOverview {
                    Text(L10n.text("视频准备 \(store.adjacentVideoReady)/\(store.adjacentVideoTotal)"))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if store.isGeneratingPreviews {
                    ProgressView(value: Double(store.previewCompleted), total: Double(max(1, store.previewTotal)))
                        .frame(width: 50)
                    Text(L10n.text("预览 \(store.previewCompleted)/\(store.previewTotal)")).font(.caption).foregroundStyle(.secondary)
                }
                if store.previewFailures > 0 || !store.previewFailureDetails.isEmpty {
                    Label(store.previewFailures > 0 ? L10n.text("\(store.previewFailures) 张预览失败") : L10n.text("缓存提示"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).help(store.previewFailureDetails)
                }
                Text(store.selectedFolderID == nil ? L10n.text("\(store.selection.count) 张已选") : L10n.text("1 个目录已选")).font(.caption).foregroundStyle(.secondary)
                Slider(value: $store.thumbnailSize, in: 110...360).frame(width: 100).help(L10n.text("缩略图大小"))
            }.padding(.horizontal, 15).padding(.vertical, 9)
        }
        .background(GlassBackdrop().ignoresSafeArea())
        .tint(.blue)
        .controlSize(.small)
        .task {
            while !Task.isCancelled {
                await store.updateAdjacentReadiness()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .toolbar { toolbar }
        .disabled(store.isMoving)
        .onChange(of: store.scope) { _, _ in store.changeScope() }
        .sheet(item: $store.archiveGroup) { group in ArchiveSheet(group: group).environmentObject(store) }
        .sheet(item: $store.renameGroup) { group in RenameGroupSheet(group: group).environmentObject(store) }
        .sheet(isPresented: $store.showHistory) { HistorySheet().environmentObject(store) }
        .sheet(isPresented: $store.showMerge) { MergeSheet().environmentObject(store) }
        .alert(L10n.text("操作未完成"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(L10n.text("知道了")) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .confirmationDialog(L10n.text("重新分组将替换当前保存的分组"), isPresented: $confirmRegroup) {
            Button(L10n.text("读取拍摄信息并重新分组")) { store.autoGroup() }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: { Text(L10n.text("已有的手动拆分、合并和确认状态会被新的候选组替换。原照片不会移动。")) }
    }

    private var hasRecovery: Bool {
        store.history.contains { ["prepared", "moving", "undoing", "recoveryNeeded"].contains($0.state) }
    }

    private func panelDivider(width: Binding<Double>, actualWidth: Double, range: ClosedRange<Double>,
                              direction: Double, maximum: Double) -> some View {
        Capsule().fill(Color.white.opacity(0.07)).frame(width: 0.5).padding(.vertical, 8)
            .frame(width: 6).contentShape(Rectangle())
            .onHover { hovering in if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if panelDragStart == nil { panelDragStart = actualWidth }
                    width.wrappedValue = BrowserPanelLayout.clamp((panelDragStart ?? actualWidth) + value.translation.width * direction,
                                                                  to: range.lowerBound...max(range.lowerBound, min(range.upperBound, maximum)),
                                                                  fallback: actualWidth)
                }
                .onEnded { _ in panelDragStart = nil; NSCursor.arrow.set() })
            .onDisappear { panelDragStart = nil; NSCursor.arrow.set() }
            .help(L10n.text("左右拖动调整面板宽度，重开后保留"))
    }

    @ViewBuilder private var center: some View {
        if store.directory == nil {
            ContentUnavailableView {
                Label(L10n.text("照片与全景，一起整理"), systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(L10n.text("打开照片目录，同名 RAW、HIF 和 JPG 会自动合并显示。"))
            } actions: { Button(L10n.text("打开照片目录…")) { store.chooseDirectory() }.buttonStyle(.borderedProminent) }
        } else if store.isLoading {
            VStack(spacing: 14) { ProgressView(); Text(L10n.text("正在扫描照片目录…")).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.assets.isEmpty {
            FolderGallery()
        } else {
            VStack(spacing: 0) {
                if store.showGroupOverview { PhotoGridView(); GlassDivider(); overviewControls }
                else {
                    GeometryReader { geometry in
                        let maximum = max(110, min(360, geometry.size.height - 234))
                        let size = min(store.thumbnailSize, maximum)
                        VStack(spacing: 0) {
                            LargePreviewView().frame(minHeight: 180)
                            filmstripDivider(maximum: maximum)
                            FilmstripView(thumbnailSize: size).frame(height: size + 48)
                        }
                    }
                }
            }
        }
    }

    private func filmstripDivider(maximum: Double) -> some View {
        ZStack {
            Color.clear
            GlassDivider()
            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.25)).frame(width: 28, height: 2)
        }.frame(height: 6).contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if filmstripDragStart == nil { filmstripDragStart = min(store.thumbnailSize, maximum) }
                    store.thumbnailSize = min(maximum, max(110, (filmstripDragStart ?? store.thumbnailSize) - value.translation.height))
                }
                .onEnded { _ in filmstripDragStart = nil; NSCursor.arrow.set() })
            .onDisappear { filmstripDragStart = nil; NSCursor.arrow.set() }
            .help(L10n.text("上下拖动调整缩略图区域高度"))
    }

    private var overviewControls: some View {
        HStack(spacing: 10) {
            Spacer()
            Button { store.showGroupOverview.toggle() } label: {
                Image(systemName: store.showGroupOverview ? "rectangle" : "square.grid.2x2")
            }.help(store.showGroupOverview ? L10n.text("大图浏览") : L10n.text("网格预览"))
            Button { store.toggleFullscreenPreview() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .disabled(store.focusedFile == nil).help(L10n.text(store.focusedFile?.kind == .video ? "全屏播放" : "全屏高清预览（空格）"))
        }.padding(.horizontal, 14).padding(.vertical, 10).buttonStyle(.borderless)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { showDirectoryPanel.toggle() } label: { Label(L10n.text("目录面板"), systemImage: "sidebar.left") }
                .help(showDirectoryPanel ? L10n.text("收起目录面板") : L10n.text("展开目录面板"))
                .accessibilityValue(showDirectoryPanel ? L10n.text("展开") : L10n.text("收起"))
            Button { store.chooseDirectory() } label: { Label(L10n.text("打开目录"), systemImage: "folder") }.help(L10n.text("打开目录 ⌘O"))
            Button { store.refreshDirectory() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(store.directory == nil || store.isLoading || store.isMoving).help(L10n.text("刷新目录 ⌘R"))
        }
        ToolbarItemGroup {
            Button { if store.groups.isEmpty { store.autoGroup() } else { confirmRegroup = true } } label: {
                Label(L10n.text("自动分组"), systemImage: "wand.and.stars")
            }.disabled(store.assets.isEmpty || store.isReadingMetadata || store.isLoading)
            Button { store.createGroup() } label: { Label(L10n.text("选中成组"), systemImage: "rectangle.stack.badge.plus") }
                .disabled(store.selection.count < 2 || store.isReadingMetadata).help(L10n.text("⌘ / ⇧ 点击多选，再按 ⌘G 成组"))
            Button { store.refreshHistory(); store.showHistory = true } label: { Label(L10n.text("移动记录"), systemImage: "clock.arrow.circlepath") }
            Button { showInspectorPanel.toggle() } label: { Label(L10n.text("照片信息面板"), systemImage: "sidebar.right") }
                .help(showInspectorPanel ? L10n.text("收起照片信息面板") : L10n.text("展开照片信息面板"))
                .accessibilityValue(showInspectorPanel ? L10n.text("展开") : L10n.text("收起"))
            TextField(L10n.text("搜索文件名或格式"), text: $store.search)
                .textFieldStyle(.plain)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .frame(width: 180)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(searchFocused ? Color.blue.opacity(0.55) : Color.white.opacity(0.12), lineWidth: 0.75))
                .focusEffectDisabled()
                .focused($searchFocused)
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
                    directoryRow(L10n.text(store.assets.contains(where: \.isVideo) ? "全部照片与视频" : "全部照片"), count: store.assets.count, icon: "photo.on.rectangle").tag("all")
                    directoryRow(L10n.text("未分组"), count: store.ungroupedCount, icon: "square.dashed").tag("ungrouped")
                } header: {
                    sectionHeader(L10n.text("照片目录"))
                }
                .listSectionSeparator(.hidden)
                Section {
                    ForEach(store.groups) { group in
                        groupRow(group, totalSize: Set(group.assetIDs).reduce(Int64(0)) { $0 + (assetSizes[$1] ?? 0) })
                            .tag(group.id)
                            .contextMenu {
                                Button(L10n.text("查看整组")) { store.scope = group.id; store.showGroupOverview = true }
                                Button(L10n.text("重命名…")) { store.renameGroup = group }
                                Button(L10n.text("移动整组到新文件夹…")) { store.archiveGroup = group }.disabled(!store.canArchive)
                                Button(L10n.text("取消分组")) { store.dissolveGroup(group) }.disabled(store.isReadingMetadata)
                            }
                    }
                } header: {
                    sectionHeader(L10n.text("全景与手动分组 · \(store.groups.count)"))
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
                    .foregroundStyle(group.confidence == .candidate ? .blue : .secondary)
                Text(group.name).lineLimit(1)
                Spacer()
                Text(L10n.text("\(group.assetIDs.count) 张")).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Text(L10n.lookup(group.confidence.rawValue))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)).monospacedDigit()
                    .help(L10n.text("组内所有格式和配套文件的总大小"))
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
            .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
            .listRowSeparator(.hidden)
    }
}
