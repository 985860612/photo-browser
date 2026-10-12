import AppKit
import SwiftUI
import BrowserCore

struct InspectorView: View {
    @EnvironmentObject private var store: BrowserStore
    @State private var metadataFailure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let asset = store.focusedAsset {
                    Text("照片信息").font(.headline)
                    Text(asset.name).font(.title3).textSelection(.enabled)
                    Text(asset.formatLabel).font(.caption).foregroundStyle(.cyan)
                    formatPicker(asset)
                    GlassDivider()
                    if let file = store.focusedFile {
                        information("文件名", file.url.lastPathComponent)
                        information("文件大小", ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        information("修改时间", file.modified.formatted(date: .numeric, time: .standard))
                        Button("在 Finder 显示") { store.revealFocused() }.font(.caption)
                    }
                    GlassDivider()
                    metadataFields(asset.metadata)
                    if let metadataFailure { Text(metadataFailure).font(.caption2).foregroundStyle(.orange) }
                    if let group = store.currentGroup {
                        GlassDivider()
                        Text("当前分组").font(.headline)
                        Text(group.reason).font(.caption).foregroundStyle(.secondary)
                        information("照片数量", "\(group.assetIDs.count) 张")
                        groupActions(group)
                    }
                } else { Text("选择照片查看信息").foregroundStyle(.secondary) }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: store.focusedFile?.id) {
            metadataFailure = nil
            guard let file = store.focusedFile, let id = store.focusedID else { return }
            do {
                let result = try await ThumbnailCache.shared.image(file, maximum: 520)
                try Task.checkCancellation(); store.updateMetadata(id, value: result.metadata)
            } catch is CancellationError {}
            catch { metadataFailure = error.localizedDescription }
        }
    }

    private func formatPicker(_ asset: PhotoAsset) -> some View {
        HStack(spacing: 4) {
            ForEach(asset.imageFiles) { file in
                let selected = file.id == store.focusedFile?.id
                Button { store.preferredFileID = file.id } label: {
                    Text(file.format).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(selected ? 0.13 : 0)))
                }.buttonStyle(.plain).accessibilityLabel("预览 \(file.format)")
            }
        }.padding(3).background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func metadataFields(_ value: PhotoMetadata?) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("拍摄参数").font(.headline)
            information("相机", value?.camera ?? "—")
            information("拍摄时间", value?.captured?.formatted(date: .numeric, time: .standard) ?? "—")
            information("光圈", value?.aperture.map { String(format: "f/%.1f", $0) } ?? "—")
            information("快门", value?.shutter.map { $0 + " s" } ?? "—")
            information("ISO", value?.iso.map(String.init) ?? "—")
            information("焦距", value?.focalLength.map { String(format: "%.0f mm", $0) } ?? "—")
            information("连拍序号", value?.sequence.map(String.init) ?? "—")
        }
    }

    private func groupActions(_ group: PhotoGroup) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button("从当前照片处分组") { store.splitGroup() }
                .disabled(group.assetIDs.first == store.focusedID || store.isReadingMetadata)
            Button("与其他组合并…") { store.showMerge = true }.disabled(store.groups.count < 2 || store.isReadingMetadata)
            Button("将所选照片移出分组") { store.removeFromGroup() }.disabled(store.selection.isEmpty || store.isReadingMetadata)
        }.font(.caption)
    }

    private func information(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(.system(size: 12)).foregroundStyle(Color(white: 0.72)).frame(width: 58, alignment: .leading)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 13)).foregroundStyle(Color(white: 0.94)).multilineTextAlignment(.trailing).lineLimit(2).textSelection(.enabled)
        }.padding(.vertical, 2)
    }
}
