import SwiftUI
import BrowserCore

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
