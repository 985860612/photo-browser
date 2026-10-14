import AppKit
import ImageIO
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func previewSortingChecks() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("PreviewSorting-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "PreviewSorting-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"), thumbnails: ThumbnailCache(directory: root.appendingPathComponent("cache")), defaults: defaults, monitoringEnabled: false)
        defer { store.cancelPreviewGeneration() }
        func file(_ name: String, _ kind: PhotoKind, _ size: Int64, _ modified: Double) -> PhotoFile {
            PhotoFile(url: root.appendingPathComponent(name), kind: kind, size: size, modified: Date(timeIntervalSince1970: modified))
        }
        let a = PhotoAsset(id: "shot2", name: "shot2", files: [file("shot2.jpg", .rendered, 10, 300), file("shot2.arw", .raw, 50, 400), file("shot2.xmp", .sidecar, 5, 999)], metadata: PhotoMetadata(captured: Date(timeIntervalSince1970: 20)))
        let b = PhotoAsset(id: "shot10", name: "shot10", files: [file("shot10.jpg", .rendered, 100, 100)], metadata: PhotoMetadata(captured: Date(timeIntervalSince1970: 10)))
        let c = PhotoAsset(id: "shot1", name: "shot1", files: [file("shot1.jpg", .rendered, 20, 200), file("shot1.xmp", .sidecar, 10, 999)])
        store.assets = [a, b, c]; store.focusedID = a.id; store.selection = [a.id, b.id]
        var lensMetadata = PhotoMetadata(captured: Date(timeIntervalSince1970: 999), sequence: 99)
        lensMetadata.lensModel = "EF-S55-250mm f/4-5.6 IS STM"
        store.updateMetadata(a.id, value: lensMetadata)
        try expect(store.assets[0].metadata?.lensModel == lensMetadata.lensModel && store.assets[0].metadata?.captured == a.metadata?.captured && store.assets[0].metadata?.sequence == nil,
                   "lens enrichment preserves the original capture date and burst information")
        lensMetadata.lensModel = "Other lens"
        store.updateMetadata(a.id, value: lensMetadata)
        try expect(store.assets[0].metadata?.lensModel == "EF-S55-250mm f/4-5.6 IS STM", "later preview metadata does not overwrite an existing original lens model")
        try expect(store.visibleAssets.map(\.id) == [a.id, b.id, c.id], "default sorting preserves existing preview order")
        store.previewSortField = .name
        try expect(store.visibleAssets.map(\.id) == [c.id, a.id, b.id], "name sorting uses natural numeric filename order")
        let request = store.previewRequestID
        store.previewSortDescending = true
        try expect(store.visibleAssets.map(\.id) == [b.id, a.id, c.id] && store.focusedID == a.id && store.selection == [a.id, b.id], "descending sort preserves focus and multi-selection")
        try expect(store.previewRequestID != request && store.adjacentPreviewFiles.map(\.id) == [c.preferred.id, b.preferred.id], "preloading follows the newly sorted neighbors")
        store.step(-1)
        try expect(store.focusedID == b.id, "arrow navigation follows descending order")
        store.step(1, extendingSelection: true)
        try expect(store.selection == [a.id, b.id], "shift-arrow selection extends along the sorted sequence")
        let reopened = BrowserStore(supportDirectory: root.appendingPathComponent("reopened"), defaults: defaults, monitoringEnabled: false)
        try expect(reopened.previewSortField == .name && reopened.previewSortDescending, "sort field and direction survive reopening")
        store.previewSortDescending = false; store.previewSortField = .captured
        try expect(store.visibleAssets.map(\.id) == [b.id, a.id, c.id], "capture sorting uses metadata with modification time as the missing-date fallback")
        store.previewSortField = .modified
        try expect(store.visibleAssets.map(\.id) == [b.id, c.id, a.id], "modification sort takes the newest paired media file and ignores sidecar timestamps")
        store.previewSortField = .size
        try expect(store.visibleAssets.map(\.id) == [c.id, a.id, b.id], "size sorting totals companion RAW, JPEG and XMP files")
        let group = PhotoGroup(name: "manual order", assetIDs: [b.id, a.id])
        store.groups = [group]; store.scope = group.id; store.previewSortField = .original
        try expect(store.visibleAssets.map(\.id) == group.assetIDs, "default group sorting preserves manual member order")
        store.previewSortField = .name
        try expect(store.visibleAssets.map(\.id) == [a.id, b.id] && store.groups[0].assetIDs == group.assetIDs, "preview sorting leaves saved group membership and order intact")
        store.search = "10"
        try expect(store.visibleAssets.map(\.id) == [b.id], "sort cache invalidates when search changes")
        store.search = ""; store.scope = "all"; store.assets = [a, b]
        try expect(store.visibleAssets.map(\.id) == [a.id, b.id], "sort cache invalidates when external assets change")

        let photos = root.appendingPathComponent("exif")
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        let cg = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        for (name, date) in [("a", "2023:01:02 12:00:00"), ("z", "2023:01:01 12:00:00")] {
            let output = CGImageDestinationCreateWithURL(photos.appendingPathComponent(name + ".jpg") as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(output, cg, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date]] as CFDictionary)
            try expect(CGImageDestinationFinalize(output), "capture sort EXIF fixture created")
        }
        store.groups = []; store.assets = try DirectoryScanner.scan(photos); store.directory = photos
        store.previewSortField = .captured
        try await until { !store.isReadingSortDates }
        try expect(store.visibleAssets.map(\.id) == ["z", "a"] && store.assets.allSatisfy { $0.metadata?.captured != nil },
                   "capture sort reads actual cached/native EXIF dates in the background")
        store.assets[0].metadata?.captured = Date(timeIntervalSince1970: 1)
        try expect(store.visibleAssets.first?.id == store.assets[0].id, "capture sort cache invalidates when metadata is refreshed")
        store.previewSortField = .name
        let rawURL = photos.appendingPathComponent("raw.dng")
        try fm.copyItem(at: photos.appendingPathComponent("z.jpg"), to: rawURL)
        let values = try rawURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let raw = PhotoFile(url: rawURL, kind: .raw, size: Int64(values.fileSize!), modified: values.contentModificationDate!)
        let key = ThumbnailCache.digest("v1|\(raw.url.path)|\(raw.size)|\(raw.modified.timeIntervalSince1970)|520")
        // Simulate a camera's embedded-preview disk cache without capture metadata.
        try Data(contentsOf: photos.appendingPathComponent("z.jpg")).write(to: root.appendingPathComponent("cache/" + key + ".jpg"))
        store.assets = [PhotoAsset(id: "raw", name: "raw", files: [raw])]
        store.previewSortField = .captured; try await until { !store.isReadingSortDates }
        try expect(store.assets[0].metadata?.captured != nil, "cached RAW previews without date metadata use the original source-header capture date")
    }

}
