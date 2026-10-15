import AppKit
import BrowserCore
import CoreImage

extension BrowserStore {
    func openInCameraRaw(_ asset: PhotoAsset, file: PhotoFile? = nil) {
        guard !isMoving, !asset.isVideo, !asset.isLivePhoto else { return }
        let source = file ?? asset.imageFiles.first(where: { $0.kind == .raw }) ?? asset.preferred
        do { try CameraRawLauncher.open(source) { [weak self] error in
            if let error { self?.report(error) }
        } } catch { report(error) }
    }

    var canCopyFiles: Bool {
        !isMoving && !isLoading && (selectedFolderID != nil || visibleAssets.contains { selection.contains($0.id) })
    }

    func copyFilesToClipboard(_ asset: PhotoAsset? = nil, pasteboard: NSPasteboard = .general) {
        guard !isMoving, !isLoading else { return }
        let targets = asset.map { selection.contains($0.id) ? visibleAssets.filter { selection.contains($0.id) } : [$0] }
            ?? visibleAssets.filter { selection.contains($0.id) }
        let urls: [URL]
        if asset == nil, let folder = selectedFolderID { urls = [URL(fileURLWithPath: folder)] }
        else { urls = targets.flatMap { $0.files.map(\.url) } }
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0.standardizedFileURL).inserted }
        guard !unique.isEmpty else { return }
        clipboardTask?.cancel(); clipboardTicket = UUID(); isCopyingImage = false
        pasteboard.clearContents()
        if pasteboard.writeObjects(unique.map { $0 as NSURL }) {
            status = L10n.text("已复制 \(unique.count) 个文件到剪贴板")
        } else { report(BrowserFailure.message(L10n.text("无法写入剪贴板，请重试。"))) }
    }

    func copyImageToClipboard(_ asset: PhotoAsset? = nil, pasteboard: NSPasteboard = .general) {
        guard !isMoving, !isLoading, !isCopyingImage else { return }
        let source: PhotoFile?
        if let asset, asset.id != focusedID {
            source = asset.imageFiles.first { $0.kind == (preferRawPreview ? .raw : .rendered) } ?? asset.preferred
        } else { source = focusedFile }
        guard let source, source.kind != .video, asset != nil || selectedFolderID == nil else { return }
        clipboardTask?.cancel()
        let ticket = UUID(), count = pasteboard.changeCount, cache = displayCache, workers = clipboardWorkers
        clipboardTicket = ticket; isCopyingImage = true
        status = L10n.text("正在复制图片…")
        clipboardTask = Task { [weak self] in
            defer { if self?.clipboardTicket == ticket { self?.isCopyingImage = false } }
            do {
                let photo = try await cache.image(source, hdr: false, maximum: nil)
                try Task.checkCancellation()
                let data = try await workers.run(background: true) { check in
                    try check()
                    let context = CIContext(), colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                    guard let png = context.pngRepresentation(of: photo.image, format: .RGBA8, colorSpace: colorSpace) else {
                        throw BrowserFailure.message(L10n.text("无法生成剪贴板图片，请切换照片格式后重试。"))
                    }
                    try check()
                    guard let tiff = context.tiffRepresentation(of: photo.image, format: .RGBA8, colorSpace: colorSpace) else {
                        throw BrowserFailure.message(L10n.text("无法生成剪贴板图片，请切换照片格式后重试。"))
                    }
                    return (png, tiff)
                }
                try Task.checkCancellation()
                guard let self, self.clipboardTicket == ticket else { return }
                guard pasteboard.changeCount == count else {
                    self.status = L10n.text("剪贴板已有新内容，已取消复制图片")
                    return
                }
                let item = NSPasteboardItem()
                item.setData(data.0, forType: .png); item.setData(data.1, forType: .tiff)
                pasteboard.clearContents()
                guard pasteboard.writeObjects([item]) else { throw BrowserFailure.message(L10n.text("无法写入剪贴板，请重试。")) }
                self.status = L10n.text("已复制图片到剪贴板")
            } catch is CancellationError {}
            catch { if self?.clipboardTicket == ticket { self?.report(error) } }
        }
    }

}
