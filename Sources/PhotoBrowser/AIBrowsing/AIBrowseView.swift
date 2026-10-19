import SwiftUI
import AppKit
import BrowserCore

struct BrowsingWorkspaceView: View {
    @EnvironmentObject private var directory: BrowserStore
    @EnvironmentObject private var ai: AIBrowseStore
    var body: some View {
        VStack(spacing: 0) {
            if ai.active { AIBrowseView(onDirectory: showDirectory) }
            else if directory.isFullscreenPreview { FullscreenPreview() }
            else { BrowserView() }
        }
        .toolbar {
            if !directory.isFullscreenPreview && !ai.fullscreen {
                ToolbarItem(placement: .principal) {
                    Picker(L10n.text("浏览模式"), selection: $ai.active) {
                        Text(L10n.text("AI 分类")).tag(true)
                        Text(L10n.text("目录浏览")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    .disabled(directory.isMoving || directory.isOperatingDiskImage)
                    .help(L10n.text("浏览模式"))
                }
            }
        }
        .onChange(of: ai.active) { _, active in
            if active {
                directory.video.stop(); directory.cancelPreviewGeneration(); directory.cancelAdjacentPreviews()
                directory.stopDirectoryObservation(); ai.activate(directory: directory.directory)
            } else {
                ai.fullscreen = false; ai.persist()
                if directory.directory != nil && !directory.isLoading {
                    directory.startPreviewGeneration()
                    if directory.monitoringEnabled && !directory.isReadOnlyDirectory { directory.startDirectoryObservation() }
                }
            }
        }
        .onChange(of: directory.isLoading) { _, loading in
            if ai.active && !loading {
                directory.cancelPreviewGeneration(); directory.cancelAdjacentPreviews(); directory.stopDirectoryObservation()
            }
        }
    }
    private func showDirectory(_ item: AICatalogItem) {
        ai.persist()
        Task { @MainActor in
            do {
                let hints = try await ai.repository?.knownAssets(in: item.directory) ?? []
                ai.active = false
                directory.load(item.directory, knownAssets: hints + [item.asset])
            } catch { ai.error = error.localizedDescription; return }
            while directory.isLoading && directory.directory?.path == item.directory.path {
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            }
            guard directory.directory?.path == item.directory.path, let asset = directory.assets.first(where: { $0.id == item.asset.id }) else { return }
            directory.select(asset, modifiers: []); directory.navigationScrollTarget = asset.id
        }
    }
}

struct AIBrowseView: View {
    @EnvironmentObject private var store: AIBrowseStore
    let onDirectory: (AICatalogItem) -> Void
    @AppStorage("aiFacetPanelWidth") private var facetWidth = 250.0
    @AppStorage("aiInformationPanelWidth") private var informationWidth = 300.0
    @AppStorage("aiShowFacetPanel") private var showFacetPanel = true
    @AppStorage("aiShowInformationPanel") private var showInformationPanel = true
    @State private var panelDragStart: Double?
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            if !store.fullscreen { navigation; Divider() }
            if store.fullscreen { AICatalogPreview(fullscreen: true) }
            else {
                GeometryReader { geometry in
                    let inspectorVisible = showInformationPanel && store.selected != nil
                    let layout = BrowserPanelLayout(available: geometry.size.width, directoryWidth: facetWidth,
                                                    inspectorWidth: informationWidth, showDirectory: showFacetPanel, showInspector: inspectorVisible)
                    HStack(spacing: 0) {
                    if showFacetPanel {
                        AIFacetSidebar().frame(width: layout.directory)
                        panelDivider(width: $facetWidth, actual: layout.directory, range: BrowserPanelLayout.directoryRange,
                                     direction: 1, maximum: geometry.size.width - 550 - layout.inspector - (inspectorVisible ? 12 : 6))
                    }
                    VStack(spacing: 0) {
                        if !store.filter.tags.values.allSatisfy(\.isEmpty), store.filter.state == "processing.succeeded" { chips; Divider() }
                        if store.large { AICatalogPreview(fullscreen: false) }
                        else { wall }
                    }.frame(minWidth: 550, maxWidth: .infinity, maxHeight: .infinity)
                    if showInformationPanel, let selected = store.selected {
                        panelDivider(width: $informationWidth, actual: layout.inspector, range: BrowserPanelLayout.inspectorRange,
                                     direction: -1, maximum: geometry.size.width - 550 - layout.directory - (showFacetPanel ? 12 : 6))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(selected.asset.name).font(.headline).textSelection(.enabled)
                                Text(selected.directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Text(selected.asset.formatLabel).font(.caption).foregroundStyle(.secondary)
                                if let facts = selected.asset.metadata {
                                    if let captured = facts.captured { Text(captured, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                                    if let camera = facts.camera { Text(camera).font(.caption).foregroundStyle(.secondary) }
                                    if let width = facts.width, let height = facts.height { Text("\(width) × \(height)").font(.caption).foregroundStyle(.secondary) }
                                }
                                HStack {
                                    Button(L10n.text("在目录中查看")) { onDirectory(selected) }
                                    Button { store.reveal() } label: { Image(systemName: "folder") }.help(L10n.text("在 Finder 显示"))
                                }
                                Divider()
                                AIPhotoInformation(asset: selected.asset, cachedMetadata: selected.metadata, usesCatalog: true).id(selected.id)
                                if let issue = selected.issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                            }.padding(16)
                        }.frame(width: layout.inspector)
                    }
                    }
                }
                Divider()
                HStack {
                    if store.syncing || store.loading { ProgressView().controlSize(.mini) }
                    Text(L10n.text("匹配 \(store.total) 张 · 已载入 \(store.items.count) 张")).monospacedDigit()
                    if !store.complete { Text(L10n.text("总量统计中")).foregroundStyle(.secondary) }
                    Spacer()
                    Text(store.status).foregroundStyle(.secondary).lineLimit(1)
                }.font(.caption).padding(10)
            }
            if let error = store.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled).lineLimit(3)
                    Spacer()
                    Button(L10n.text("关闭")) { store.error = nil }
                }.padding(10).background(.orange.opacity(0.08))
            }
        }.background(GlassBackdrop().ignoresSafeArea()).controlSize(.small)
            .toolbar {
                if !store.fullscreen {
                    ToolbarItem(placement: .navigation) {
                        Button { showFacetPanel.toggle() } label: { Label(L10n.text("筛选面板"), systemImage: "sidebar.left") }
                            .help(L10n.text(showFacetPanel ? "收起筛选面板" : "展开筛选面板"))
                            .accessibilityValue(L10n.text(showFacetPanel ? "展开" : "收起"))
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showInformationPanel.toggle() } label: { Label(L10n.text("照片信息面板"), systemImage: "sidebar.right") }
                            .help(L10n.text(showInformationPanel ? "收起照片信息面板" : "展开照片信息面板"))
                            .accessibilityValue(L10n.text(showInformationPanel ? "展开" : "收起"))
                    }
                }
            }
    }
    private func panelDivider(width: Binding<Double>, actual: Double, range: ClosedRange<Double>, direction: Double, maximum: Double) -> some View {
        Capsule().fill(Color.white.opacity(0.08)).frame(width: 0.5).padding(.vertical, 8)
            .frame(width: 6).contentShape(Rectangle())
            .onHover { if $0 { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
                if panelDragStart == nil { panelDragStart = actual }
                width.wrappedValue = BrowserPanelLayout.clamp((panelDragStart ?? actual) + value.translation.width * direction,
                    to: range.lowerBound...max(range.lowerBound, min(range.upperBound, maximum)), fallback: actual)
            }.onEnded { _ in panelDragStart = nil; NSCursor.arrow.set() })
            .onDisappear { panelDragStart = nil; NSCursor.arrow.set() }
            .help(L10n.text("左右拖动调整面板宽度，重开后保留"))
    }
    private var navigation: some View {
        HStack(spacing: 12) {
            Button(action: store.chooseRoot) { Label(L10n.text("浏览范围"), systemImage: "folder") }
            Text(store.root?.path ?? L10n.text("请选择目录")).font(.caption).lineLimit(1).truncationMode(.middle).help(store.root?.path ?? "")
            Button(action: store.synchronize) { Image(systemName: "arrow.clockwise") }.disabled(store.syncing || store.root == nil).help(L10n.text("刷新分类索引"))
            Spacer(minLength: 10)
            TextField(L10n.text("搜索描述、标签、文件名或目录"), text: $store.filter.text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .frame(minWidth: 180, idealWidth: 280, maxWidth: 340)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(searchFocused ? Color.blue.opacity(0.55) : Color.white.opacity(0.12), lineWidth: 0.75))
                .focusEffectDisabled()
                .focused($searchFocused)
            PhotoSortMenu(field: .constant(.captured), descending: $store.filter.descending, fields: [.captured])
                .disabled(store.loading || store.items.count < 2)
                .help(L10n.text("排序：\(PreviewSortField.captured.title) · \(store.filter.descending ? L10n.text("降序") : L10n.text("升序"))"))
        }.padding(12)
    }
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(store.fields) { field in
                    ForEach(Array(store.filter.tags[field.id] ?? []).sorted(), id: \.self) { code in
                        Button { store.toggle(field.id, code: code) } label: {
                            HStack(spacing: 4) { Text(store.label(field: field.id, code: code)); Image(systemName: "xmark").font(.system(size: 8)) }
                        }.buttonStyle(.bordered).tint(.blue)
                    }
                }
                Button(L10n.text("清除标签")) { store.filter.tags = [:] }.buttonStyle(.plain)
            }.padding(10)
        }
    }
    private var wall: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 185, maximum: 260), spacing: 12)], spacing: 14) {
                    ForEach(store.items) { item in
                        AICatalogCard(item: item, root: store.root, selected: store.selection.contains(item.id))
                            .id(item.id)
                            .onTapGesture(count: 2) { store.select(item, modifiers: []); store.large = true }
                            .onTapGesture { store.select(item) }
                            .contextMenu {
                                Button(L10n.text("在目录中查看")) { onDirectory(item) }
                                Button(L10n.text("在 Finder 显示")) { NSWorkspace.shared.activateFileViewerSelecting([item.asset.preferred.url]) }
                                Button(L10n.text("复制文件")) { store.select(item, modifiers: []); store.copyFiles() }
                                Button(L10n.text("全屏高清预览")) { store.select(item, modifiers: []); store.fullscreen = true }
                            }
                            .onAppear { if item.id == store.items.last?.id { store.loadMore() } }
                    }
                }.scrollTargetLayout().padding(16)
                if store.items.isEmpty && !store.loading {
                    ContentUnavailableView {
                        Label(L10n.text("没有匹配的照片"), systemImage: "photo.on.rectangle")
                    } description: { Text(L10n.text("调整筛选条件，或选择其他浏览范围。首次导入期间照片会陆续出现。")) }
                }
            }
            .scrollPosition(id: $store.scrollID, anchor: .top)
            .onDisappear { store.persist() }
        }
    }
}

private struct AICatalogCard: View {
    let item: AICatalogItem
    let root: URL?
    let selected: Bool
    @State private var image: NSImage?
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.3))
                if let image { Image(nsImage: image).resizable().scaledToFit() }
                else if let failure { Image(systemName: "photo.badge.exclamationmark").help(failure).foregroundStyle(.secondary) }
                else { ProgressView().controlSize(.mini) }
            }.frame(height: 145).clipShape(RoundedRectangle(cornerRadius: 6))
            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1).help(item.title)
            Text(relativeDirectory).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(item.directory.path)
            Text(item.asset.formatLabel).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1)
        }.padding(8).background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.blue.opacity(0.2) : Color.white.opacity(0.025)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.blue : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .task(id: item.asset.fingerprint) {
                do {
                    var loaded: NSImage?
                    if let preview = item.preview {
                        loaded = await Task.detached(priority: .utility) { NSImage(contentsOf: preview) }.value
                    }
                    if loaded == nil { loaded = try await ThumbnailCache.shared.image(item.asset.preferred, maximum: 520).image }
                    try Task.checkCancellation(); image = loaded
                } catch is CancellationError {} catch { failure = error.localizedDescription }
            }
    }
    private var relativeDirectory: String {
        guard let root, AICatalogPaths.contains(item.directory, in: root) else { return item.directory.path }
        return item.directory.path == root.path ? root.lastPathComponent : String(item.directory.path.dropFirst(root.path.count + 1))
    }
}
