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
                    if asset.isVideo { videoFields(asset.metadata) } else { metadataFields(asset.metadata) }
                    if let metadataFailure { Text(metadataFailure).font(.caption2).foregroundStyle(.orange) }
                    GlassDivider(inset: 0)
                    VStack(alignment: .leading, spacing: 13) {
                        sectionTitle(L10n.text("文件信息"), icon: "doc.text")
                        Text(asset.name).font(.title3).textSelection(.enabled)
                        if let file = store.focusedFile {
                            information(L10n.text("文件名"), file.url.lastPathComponent, icon: "photo")
                            information(L10n.text("文件大小"), ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file), icon: "internaldrive")
                            information(L10n.text("修改时间"), file.modified.formatted(date: .numeric, time: .standard), icon: "clock")
                            Button { store.revealFocused() } label: { Label(L10n.text("在 Finder 显示"), systemImage: "folder") }.font(.caption)
                        }
                    }
                    if let group = store.currentGroup {
                        GlassDivider(inset: 0)
                        sectionTitle(L10n.text("当前分组"), icon: "rectangle.stack")
                        Text(L10n.lookup(group.reason)).font(.caption).foregroundStyle(.secondary)
                        information(L10n.text("照片数量"), L10n.text("\(group.assetIDs.count) 张"), icon: "photo.on.rectangle")
                        groupActions(group)
                    }
                    GlassDivider(inset: 0)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            sectionTitle(L10n.text("预览格式"), icon: "square.on.square")
                            Spacer(minLength: 0)
                            Text(asset.formatLabel).font(.caption2).foregroundStyle(.secondary)
                        }
                        formatPicker(asset)
                    }
                } else { Text(L10n.text("选择照片查看信息")).foregroundStyle(.secondary) }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: store.focusedFile?.id) {
            metadataFailure = nil
            guard let file = store.focusedFile, let id = store.focusedID else { return }
            let metadataFile = store.focusedAsset?.metadataFile ?? file
            do {
                let result = try await store.thumbnails.image(file, maximum: 520)
                try Task.checkCancellation(); store.updateMetadata(id, value: result.metadata)
                if file.kind != .video, store.focusedAsset?.metadata?.lensModel == nil {
                    let metadata = try await store.thumbnails.sourceMetadata(metadataFile)
                    try Task.checkCancellation()
                    guard store.focusedID == id, store.focusedFile?.id == file.id else { return }
                    store.updateMetadata(id, value: metadata)
                }
            } catch is CancellationError {}
            catch { metadataFailure = error.localizedDescription }
        }
    }

    private func formatPicker(_ asset: PhotoAsset) -> some View {
        HStack(spacing: 4) {
            ForEach(asset.mediaFiles) { file in
                let selected = file.id == store.focusedFile?.id
                Button { store.preferredFileID = file.id } label: {
                    Text(file.format).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(selected ? 0.13 : 0)))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(L10n.text("预览 \(file.format)"))
            }
        }.padding(3).background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func metadataFields(_ value: PhotoMetadata?) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle(L10n.text("拍摄参数"), icon: "camera")
            information(L10n.text("相机"), value?.camera ?? "—", icon: "camera")
            information(L10n.text("镜头型号"), value?.lensModel ?? "—", icon: "camera.aperture")
            information(L10n.text("拍摄时间"), value?.captured?.formatted(date: .numeric, time: .standard) ?? "—", icon: "calendar")
            information(L10n.text("光圈"), value?.aperture.map { String(format: "f/%.1f", $0) } ?? "—", icon: "camera.aperture")
            information(L10n.text("快门"), value?.shutter.map { $0 + " s" } ?? "—", icon: "timer")
            information("ISO", value?.iso.map(String.init) ?? "—", icon: "sun.max")
            information(L10n.text("焦距"), value?.focalLength.map { String(format: "%.0f mm", $0) } ?? "—", icon: "viewfinder")
            information(L10n.text("连拍序号"), value?.sequence.map(String.init) ?? "—", icon: "square.stack.3d.up")
        }
    }

    private func videoFields(_ value: PhotoMetadata?) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle(L10n.text("视频参数"), icon: "film")
            information(L10n.text("时长"), VideoMedia.durationLabel(value?.duration), icon: "timer")
            information(L10n.text("分辨率"), value?.width.flatMap { width in value?.height.map { "\(width) × \($0)" } } ?? "—", icon: "viewfinder")
            information(L10n.text("帧率"), value?.frameRate.map { String(format: "%.2f fps", $0) } ?? "—", icon: "speedometer")
        }
    }

    private func groupActions(_ group: PhotoGroup) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(L10n.text("从当前照片处分组")) { store.splitGroup() }
                .disabled(group.assetIDs.first == store.focusedID || store.isReadingMetadata)
            Button(L10n.text("与其他组合并…")) { store.showMerge = true }.disabled(store.groups.count < 2 || store.isReadingMetadata)
            Button(L10n.text("将所选照片移出分组")) { store.removeFromGroup() }.disabled(store.selection.isEmpty || store.isReadingMetadata)
        }.font(.caption)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
    }

    private func information(_ title: String, _ value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color(white: 0.58))
                .frame(width: 16, height: 16).accessibilityHidden(true)
            Text(title).font(.system(size: 12)).foregroundStyle(Color(white: 0.72)).frame(width: 82, alignment: .leading)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 12)).foregroundStyle(Color(white: 0.94)).multilineTextAlignment(.trailing).lineLimit(2).textSelection(.enabled).help(value)
        }.padding(.vertical, 2)
    }
}
