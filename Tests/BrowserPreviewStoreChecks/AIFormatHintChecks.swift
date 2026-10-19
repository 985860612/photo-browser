import AppKit
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func aiFormatHintChecks() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AIFormatHint-" + UUID().uuidString)
        let source = root.appendingPathComponent("source"), elsewhere = root.appendingPathComponent("other")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = source.appendingPathComponent("Camera f_1.78_191", isDirectory: false)
        try bitmap.representation(using: .jpeg, properties: [:])!.write(to: url)
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let asset = PhotoAsset(id: "camera f_1.78_191", name: url.lastPathComponent, files: [PhotoFile(url: url, kind: .rendered,
            size: (attributes[.size] as! NSNumber).int64Value, modified: attributes[.modificationDate] as! Date, formatHint: "jpeg")])
        let suite = "AIFormatHint-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"), thumbnails: ThumbnailCache(directory: root.appendingPathComponent("thumbs")), defaults: defaults)
        defer { store.cancelPreviewGeneration(); store.stopDirectoryObservation() }
        store.load(source, knownAssets: [asset])
        try await until { !store.isLoading }
        try expect(store.assets.first?.id == asset.id && store.assets.first?.preferred.format == "JPEG", "AI folder jump retains extensionless filename, asset ID and type")
        store.refreshDirectory()
        try await until { !store.isLoading }
        try expect(store.assets.first?.id == asset.id, "Refreshing the directory preserves supplied photo type hints")
        let observed = try DirectorySnapshot.read(source, knownAssets: store.directoryKnownAssets)
        try expect(observed.assets.first?.id == asset.id, "Directory observation retains the AI-selected extensionless photo")
        store.load(elsewhere)
        try await until { !store.isLoading }
        try expect(store.directoryKnownAssets.isEmpty && store.assets.isEmpty, "Photo hints never leak into another directory")
    }
}
