import AppKit
import UniformTypeIdentifiers
import BrowserCore

enum LivePhotoVideoExporter {
    static let workers = PreviewWorkQueue()

    /// Copy the original movie bytes; commit the destination only after the copy succeeds.
    static func export(_ file: PhotoFile, to destination: URL, replacing: Bool = false,
                       cache: LivePhotoCache = .shared, check: () throws -> Void = {}) throws {
        guard file.isLivePhoto else { throw BrowserFailure.message(L10n.text("请选择 LIVP 实况照片。")) }
        try check()
        let movie = try cache.movie(file, check: check)
        try withExtendedLifetime(movie) {
            let path = destination.resolvingSymlinksInPath().standardizedFileURL.path
            guard path != file.url.resolvingSymlinksInPath().standardizedFileURL.path,
                  path != movie.url.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw BrowserFailure.message(L10n.text("无法覆盖原始 LIVP 或缓存视频。"))
            }
            let fm = FileManager.default
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".PhotoBrowser-export-" + UUID().uuidString + ".mov")
            try Data().write(to: temporary, options: .withoutOverwriting)
            defer { try? fm.removeItem(at: temporary) }
            let input = try FileHandle(forReadingFrom: movie.url)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try check(); try output.write(contentsOf: chunk)
            }
            try output.synchronize(); try output.close(); try check()
            if replacing, fm.fileExists(atPath: destination.path) {
                guard try destination.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CocoaError(.fileWriteFileExists) }
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else { try fm.moveItem(at: temporary, to: destination) }
        }
    }

    static func exportUnique(_ file: PhotoFile, to directory: URL, cache: LivePhotoCache = .shared,
                             check: () throws -> Void = {}) throws -> URL {
        let name = file.url.deletingPathExtension().lastPathComponent
        var suffix = 0
        while true {
            try check()
            let destination = directory.appendingPathComponent(name + (suffix == 0 ? "" : " (\(suffix))") + ".mov")
            suffix += 1
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            do {
                try export(file, to: destination, cache: cache, check: check)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // Another exporter may have claimed the name after the existence check.
                continue
            }
        }
    }

}

extension BrowserStore {
    func livePhotoExportTargets(_ asset: PhotoAsset) -> [PhotoFile] {
        let chosen = selection.contains(asset.id) ? visibleAssets.filter { selection.contains($0.id) } : [asset]
        return chosen.compactMap { $0.mediaFiles.first(where: \.isLivePhoto) }
    }

    func exportLivePhotoVideo(_ asset: PhotoAsset) {
        guard !isMoving, !isLoading, !isExportingLivePhotoVideo else { return }
        let files = livePhotoExportTargets(asset)
        guard let file = files.first else { return }
        isExportingLivePhotoVideo = true
        if files.count > 1 {
            let panel = NSOpenPanel()
            panel.title = L10n.text("导出 \(files.count) 个实况视频")
            panel.prompt = L10n.text("导出")
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
            let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }
                guard response == .OK, let directory = panel.url else { self.isExportingLivePhotoVideo = false; return }
                self.exportLivePhotoVideos(files, to: directory)
            }
            if let window = NSApp.keyWindow, window.attachedSheet == nil { panel.beginSheetModal(for: window, completionHandler: finish) }
            else { finish(panel.runModal()) }
            return
        }
        let panel = NSSavePanel()
        panel.title = L10n.text("导出实况视频")
        panel.allowedContentTypes = [.quickTimeMovie]; panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true; panel.isExtensionHidden = false
        panel.nameFieldStringValue = file.url.deletingPathExtension().lastPathComponent + ".mov"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else { self.isExportingLivePhotoVideo = false; return }
            self.status = L10n.text("正在导出实况视频…")
            Task { [weak self] in
                defer { self?.isExportingLivePhotoVideo = false }
                do {
                    try await LivePhotoVideoExporter.workers.run(background: true) { check in
                        try LivePhotoVideoExporter.export(file, to: destination, replacing: true, check: check)
                    }
                    self?.status = L10n.text("已导出视频：\(destination.lastPathComponent)")
                } catch is CancellationError {}
                catch { self?.report(error) }
            }
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    func exportLivePhotoVideos(_ files: [PhotoFile], to directory: URL, cache: LivePhotoCache = .shared) {
        Task { [weak self] in
            defer { self?.isExportingLivePhotoVideo = false }
            var exported = 0, failures: [String] = []
            var lastProgress = Date.distantPast
            for (index, file) in files.enumerated() {
                if Date().timeIntervalSince(lastProgress) >= 0.5 {
                    self?.status = L10n.text("正在导出视频：\(index + 1)/\(files.count)")
                    lastProgress = Date()
                }
                do {
                    _ = try await LivePhotoVideoExporter.workers.run(background: true) { check in
                        try LivePhotoVideoExporter.exportUnique(file, to: directory, cache: cache, check: check)
                    }
                    exported += 1
                } catch is CancellationError { return }
                catch { failures.append(file.url.lastPathComponent + ": " + error.localizedDescription) }
            }
            let summary = L10n.text("已导出 \(exported) 个视频，\(failures.count) 个失败")
            self?.status = summary
            if !failures.isEmpty {
                self?.report(BrowserFailure.message(summary + "\n\n" + failures.prefix(5).joined(separator: "\n")))
            }
        }
    }
}
