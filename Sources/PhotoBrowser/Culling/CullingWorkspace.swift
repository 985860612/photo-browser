import AppKit
import SwiftUI
import BrowserCore
import CullingCore

struct CullingWorkspace: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject var culling: CullingStore
    @State private var sync = true
    @State private var zoom = 1.0
    @State private var pan = CGPoint.zero
    @State private var pixelRequest = 0
    @State private var subjectRequest = 0
    @State private var fitRequest = 0
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if culling.restoring {
                ProgressView(L10n.text("恢复选片记录…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if culling.grid {
                PhotoGridView()
            } else if let asset = store.focusedAsset {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        if culling.compare, geometry.size.width >= 620, let reference = referenceAsset {
                            CullingPhotoPane(asset: reference, file: referenceFile(reference), title: L10n.text("参考照片"),
                                             analysis: culling.analysis(for: reference), sharedZoom: $zoom, sharedPan: $pan,
                                             sync: sync, pixelRequest: pixelRequest, subjectRequest: subjectRequest, fitRequest: fitRequest)
                        }
                        CullingPhotoPane(asset: asset, file: store.focusedFile ?? asset.preferred, title: L10n.text("当前照片"),
                                         analysis: culling.analysis(for: asset), sharedZoom: $zoom, sharedPan: $pan,
                                         sync: sync, pixelRequest: pixelRequest, subjectRequest: subjectRequest, fitRequest: fitRequest)
                    }
                }
                compareControls
                Divider()
                filmstrip
            } else {
                ContentUnavailableView {
                    Label(L10n.text("当前筛选没有照片"), systemImage: "checkmark.rectangle.stack")
                } description: {
                    Text(L10n.text("可以切换筛选，或开始分析当前目录。"))
                } actions: {
                    Button(L10n.text("查看全部照片")) { store.setCullingFilter(.all) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 8) {
                if culling.running || culling.grouping { ProgressView().controlSize(.mini) }
                if culling.running || culling.total > 0 {
                    Text(L10n.text("分析 \(culling.completed) / \(culling.total)"))
                }
                if culling.running { Button(L10n.text("暂停")) { culling.pause() } }
                if !culling.failures.isEmpty {
                    Text(L10n.text("\(culling.failures.count) 张分析失败，可重试")).foregroundStyle(.orange)
                }
                Spacer()
                CullingMarkControls()
                Text(L10n.text("已处理 \(culling.reviewedCount) / \(store.assets.filter { !$0.isVideo }.count) 张"))
            }.font(.caption).padding(10)
        }
        .onChange(of: culling.similarityGroups) { _, _ in
            if store.focusedAsset == nil || !store.visibleAssets.contains(where: { $0.id == store.focusedID }) { store.repairCullingSelection() }
        }
        .onChange(of: sync) { _, value in if value { zoom = 1; pan = .zero } }
    }
    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(culling.selectedLabel ?? culling.filter.title).font(.headline)
                if let group = culling.group(for: store.focusedID ?? ""), let index = culling.similarityGroups.firstIndex(of: group) {
                    Text(L10n.text("相似组 \(index + 1) / \(culling.similarityGroups.count) · \(group.assetIDs.count) 张"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { store.stepCullingGroup(-1) } label: { Image(systemName: "chevron.left.2") }.help(L10n.text("上一组"))
            Button { store.stepCullingGroup(1) } label: { Image(systemName: "chevron.right.2") }.help(L10n.text("下一组"))
            Toggle(isOn: $culling.compare) { Image(systemName: "rectangle.split.2x1") }
                .toggleStyle(.button).help(L10n.text("双图对比"))
            Button { culling.grid.toggle() } label: { Image(systemName: culling.grid ? "rectangle" : "square.grid.2x2") }
                .help(L10n.text("切换网格 / 大图"))
            Menu {
                Button(L10n.text("将所选照片合为相似组")) { culling.merge(store.selection) }
                    .disabled(store.selection.count < 2)
                Button(L10n.text("将所选照片移出相似组")) { culling.removeFromSimilarity(store.selection) }
                    .disabled(store.selection.isEmpty)
            } label: { Image(systemName: "ellipsis.circle") }
        }.padding(12).buttonStyle(.borderless)
    }
    private var referenceAsset: PhotoAsset? {
        let id = culling.referenceID ?? culling.group(for: store.focusedID ?? "")?.assetIDs.first
        return store.assets.first { $0.id == id } ?? store.focusedAsset
    }
    private func referenceFile(_ asset: PhotoAsset) -> PhotoFile {
        asset.imageFiles.first { $0.kind == (store.preferRawPreview ? .raw : .rendered) } ?? asset.preferred
    }
    private var compareControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { navigation; inspection; Spacer(); formatControls }.font(.caption)
            VStack(spacing: 8) {
                HStack { navigation; Spacer(); formatControls }
                HStack { inspection; Spacer() }
            }.font(.caption)
        }.buttonStyle(.borderless).controlSize(.mini).padding(10)
    }
    private var navigation: some View {
        Group {
            Button { store.step(-1) } label: { Image(systemName: "chevron.left") }
            Button { store.step(1) } label: { Image(systemName: "chevron.right") }
            Button(L10n.text("设为参考")) { culling.referenceID = store.focusedID }
        }
    }
    private var inspection: some View {
        Group {
            Button(L10n.text("适应")) { fitRequest += 1 }
            Button(L10n.text("100% 像素")) { sync = false; pixelRequest += 1 }
            Button(L10n.text("查看主体")) { sync = false; subjectRequest += 1 }
                .disabled(store.focusedAsset.flatMap { culling.analysis(for: $0) }.map { $0.faces.isEmpty && $0.subjects.isEmpty } ?? true)
            Toggle(L10n.text("同步缩放"), isOn: $sync).toggleStyle(.checkbox)
        }
    }
    private var formatControls: some View {
        Group {
            Toggle("HDR", isOn: $store.hdrPreview).toggleStyle(.checkbox)
            Toggle(L10n.text("RAW 优先"), isOn: $store.preferRawPreview).toggleStyle(.checkbox)
        }
    }
    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(store.visibleAssets) { asset in
                        PhotoThumbnail(asset: asset, selected: store.selection.contains(asset.id), focused: store.focusedID == asset.id, height: 100)
                            .frame(width: 132).id(asset.id)
                            .background(ImmediateCardClick { count, modifiers in
                                store.select(asset, modifiers: count == 2 ? [] : modifiers)
                                if count == 2 { culling.grid = false }
                            })
                            .accessibilityAddTraits(.isButton).accessibilityAction { store.select(asset, modifiers: []) }
                    }
                }.padding(8)
            }.frame(height: 162)
                .onChange(of: store.focusedID, initial: true) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}
