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
                    metadataFields(asset.metadata)
                    if let metadataFailure { Text(metadataFailure).font(.caption2).foregroundStyle(.orange) }
                    GlassDivider()
                    VStack(alignment: .leading, spacing: 13) {
                        sectionTitle("文件信息", icon: "doc.text")
                        Text(asset.name).font(.title3).textSelection(.enabled)
                        if let file = store.focusedFile {
                            information("文件名", file.url.lastPathComponent, icon: "photo")
                            information("文件大小", ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file), icon: "internaldrive")
                            information("修改时间", file.modified.formatted(date: .numeric, time: .standard), icon: "clock")
                            Button { store.revealFocused() } label: { Label("在 Finder 显示", systemImage: "folder") }.font(.caption)
                        }
                    }
                    if let group = store.currentGroup {
                        GlassDivider()
                        sectionTitle("当前分组", icon: "rectangle.stack")
                        Text(group.reason).font(.caption).foregroundStyle(.secondary)
                        information("照片数量", "\(group.assetIDs.count) 张", icon: "photo.on.rectangle")
                        groupActions(group)
                    }
                    GlassDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            sectionTitle("预览格式", icon: "square.on.square")
                            Spacer(minLength: 0)
                            Text(asset.formatLabel).font(.caption2).foregroundStyle(.secondary)
                        }
                        formatPicker(asset)
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
            sectionTitle("拍摄参数", icon: "camera")
            information("相机", value?.camera ?? "—", icon: "camera")
            information("拍摄时间", value?.captured?.formatted(date: .numeric, time: .standard) ?? "—", icon: "calendar")
            information("光圈", value?.aperture.map { String(format: "f/%.1f", $0) } ?? "—", icon: "camera.aperture")
            information("快门", value?.shutter.map { $0 + " s" } ?? "—", icon: "timer")
            information("ISO", value?.iso.map(String.init) ?? "—", icon: "sun.max")
            information("焦距", value?.focalLength.map { String(format: "%.0f mm", $0) } ?? "—", icon: "viewfinder")
            information("连拍序号", value?.sequence.map(String.init) ?? "—", icon: "square.stack.3d.up")
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

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
    }

    private func information(_ title: String, _ value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color(white: 0.58))
                .frame(width: 16, height: 16).accessibilityHidden(true)
            Text(title).font(.system(size: 12)).foregroundStyle(Color(white: 0.72)).frame(width: 58, alignment: .leading)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 13)).foregroundStyle(Color(white: 0.94)).multilineTextAlignment(.trailing).lineLimit(2).textSelection(.enabled)
        }.padding(.vertical, 2)
    }
}
