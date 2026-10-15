import SwiftUI
import BrowserCore
import CullingCore

struct CullingSidebar: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject var culling: CullingStore
    var body: some View {
        let counts = culling.counts
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("选片进度")).font(.headline)
                ProgressView(value: Double(culling.reviewedCount), total: Double(max(1, store.assets.filter { !$0.isVideo }.count)))
                Text(L10n.text("已处理 \(culling.reviewedCount) / \(store.assets.filter { !$0.isVideo }.count) 张"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(CullingStore.Filter.allCases, id: \.self) { filter in
                    let count = counts[filter, default: 0]
                    Button { store.setCullingFilter(filter) } label: {
                        HStack {
                            Text(filter.title); Spacer(); Text(count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                        }.padding(8).contentShape(Rectangle())
                            .background(culling.filter == filter && culling.selectedGroupID == nil && culling.selectedLabel == nil ? Color.blue.opacity(0.2) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                }
                Divider().padding(.vertical, 6)
                Text(L10n.text("相似组 · \(culling.similarityGroups.count)")).font(.headline)
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(culling.similarityGroups.enumerated()), id: \.element.id) { index, group in
                        Button { store.setCullingFilter(.similar, groupID: group.id) } label: {
                            HStack {
                                Label(L10n.text("相似组 \(index + 1)"), systemImage: "square.stack")
                                Spacer(); Text(L10n.text("\(group.assetIDs.count) 张")).foregroundStyle(.secondary)
                            }.padding(8).contentShape(Rectangle())
                                .background(culling.selectedGroupID == group.id ? Color.blue.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain)
                    }
                }
                if culling.similarityGroups.isEmpty {
                    Text(culling.grouping ? L10n.text("正在整理相似组…") : L10n.text("分析后在这里查看相似照片。"))
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                }
                DisclosureGroup(L10n.text("内容标签")) {
                    ForEach(culling.labels, id: \.self) { label in
                        Button { store.setCullingFilter(.all, label: label) } label: {
                            HStack {
                                Text(label).lineLimit(2); Spacer()
                                if culling.selectedLabel == label { Image(systemName: "checkmark") }
                            }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    if culling.labels.isEmpty { Text(L10n.text("暂无识别标签")).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 8)
                DisclosureGroup(L10n.text("已有全景与手动分组")) {
                    Text(L10n.text("这些分组默认不参与相似归组，可逐张标记。"))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(store.groups) { group in
                        Button(group.name) {
                            store.setCullingFilter(.all); store.scope = group.id; store.changeScope()
                            culling.grid = true
                        }.buttonStyle(.plain).padding(.vertical, 5)
                    }
                }
            }.font(.system(size: 12)).padding(14)
        }
    }
}

struct CullingMarkBadge: View {
    let mark: CullingMark
    var body: some View {
        Label(mark.title, systemImage: mark.symbol).font(.system(size: 10, weight: .medium))
            .foregroundStyle(color).padding(4).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
    }
    private var color: Color {
        switch mark {
        case .keep: return .green
        case .maybe: return .orange
        case .reject: return Color(white: 0.75)
        case .unreviewed: return .secondary
        }
    }
}

struct CullingMarkControls: View {
    @EnvironmentObject private var store: BrowserStore
    var body: some View {
        HStack(spacing: 6) {
            ForEach([CullingMark.keep, .maybe, .reject, .unreviewed], id: \.self) { mark in
                Button { store.markCullingSelection(mark) } label: {
                    Image(systemName: mark.symbol).accessibilityLabel(mark.title)
                }.help(mark == .unreviewed ? L10n.text("清除标记（U）") : mark.title)
            }
        }.disabled(store.selection.isEmpty || !store.culling.available || store.isMoving || store.isLoading)
    }
}
