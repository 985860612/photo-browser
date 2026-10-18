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
                    if let location = asset.metadata?.location {
                        GlassDivider(inset: 0)
                        locationFields(location, metadata: asset.metadata)
                    }
                    GlassDivider(inset: 0)
                    VStack(alignment: .leading, spacing: 13) {
                        sectionTitle(L10n.text("文件信息"), icon: "doc.text")
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
                    if !asset.isVideo {
                        GlassDivider(inset: 0)
                        AIPhotoInformation(asset: asset)
                    }
                } else { Text(L10n.text("选择照片查看信息")).foregroundStyle(.secondary) }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: metadataRequest) {
            metadataFailure = nil
            guard let file = store.focusedFile, let id = store.focusedID, let asset = store.focusedAsset else { return }
            let request = metadataRequest
            do {
                let result = try await store.thumbnails.image(file, maximum: 520)
                try Task.checkCancellation()
                guard request == metadataRequest else { return }
                store.updateMetadata(id, value: result.metadata)
                if file.kind != .video {
                    var seen: Set<String> = [], readHeader = false
                    var headerFailure: Error?
                    for source in [asset.metadataFile, file, asset.preferred] + asset.imageFiles.filter(\.isLivePhoto) where seen.insert(source.id).inserted {
                        if store.focusedAsset?.metadata?.lensModel != nil, store.focusedAsset?.metadata?.location != nil,
                           store.focusedAsset?.metadata?.gpsMapDatumRead == true { break }
                        do {
                            let metadata = try await store.thumbnails.sourceMetadata(source)
                            try Task.checkCancellation()
                            guard request == metadataRequest else { return }
                            store.updateMetadata(id, value: metadata); readHeader = true
                        } catch is CancellationError { throw CancellationError() }
                        catch { headerFailure = error }
                    }
                    if !readHeader, let headerFailure { throw headerFailure }
                }
            } catch is CancellationError {}
            catch { if request == metadataRequest { metadataFailure = error.localizedDescription } }
        }
    }

    private var metadataRequest: String {
        "\(store.focusedID ?? "")|\(store.focusedFile?.id ?? "")|\(store.focusedAsset?.fingerprint ?? "")"
    }

    private func locationFields(_ location: PhotoLocation, metadata: PhotoMetadata?) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle(L10n.text("拍摄位置"), icon: "mappin.and.ellipse")
            information(L10n.text("纬度"), location.latitudeLabel, icon: "globe")
            information(L10n.text("经度"), location.longitudeLabel, icon: "globe")
            information(L10n.text("坐标系"), (metadata?.coordinateSystem(preferred: store.preferredCoordinateSystem) ?? store.preferredCoordinateSystem).label, icon: "globe")
            information(L10n.text("判断来源"), metadata?.detectedCoordinateSystem != nil ? L10n.text("照片标记") : L10n.text("使用默认设置"), icon: "info.circle")
            if let datum = metadata?.gpsMapDatum, metadata?.detectedCoordinateSystem == nil {
                Text(L10n.text("未识别的照片标记：\(datum)"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let altitude = location.altitude {
                information(L10n.text("海拔"), String(format: "%.1f m", altitude), icon: "mountain.2")
            }
            Button { store.openFocusedLocation() } label: {
                Label(L10n.text("在地图中打开"), systemImage: "map")
            }.font(.caption)
        }
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
            information(L10n.text("码率"), VideoMedia.bitRateLabel(value?.bitRate), icon: "waveform.path")
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
