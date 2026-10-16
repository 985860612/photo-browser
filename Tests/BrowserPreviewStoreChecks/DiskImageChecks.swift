import AppKit
import AVFoundation
import ImageIO
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func diskImageChecks() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("DiskImageChecks-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = temporary.resolvingSymlinksInPath()
        let payload = root.appendingPathComponent("payload"), nested = payload.appendingPathComponent("旅行照片")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = NSMutableData(), destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw BrowserFailure.message("ISO JPEG fixture failed") }
        try (data as Data).write(to: payload.appendingPathComponent("封面.jpg"))
        try (data as Data).write(to: nested.appendingPathComponent("照片.jpg"))
        try await VideoFixture.create(at: nested.appendingPathComponent("视频.mp4"))
        let iso = root.appendingPathComponent("光盘测试.iso")
        try await Task.detached { try createDiskImage(from: payload, at: iso) }.value
        let suite = "DiskImageChecks-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = DiskImageService(directory: root.appendingPathComponent("mounts"))
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"), defaults: defaults,
                                 monitoringEnabled: false, diskImageService: service)
        var mounted: MountedDiskImage?
        do {
            store.load(root)
            try await until { !store.isLoading }
            try expect(store.diskImages.map(\.path) == [iso.path] && store.navigationEntries.contains(where: { $0.path == iso.path }),
                       "ISO files appear beside folders without mounting")
            store.selectFolder(iso); store.openSelectedFolder()
            try await until { !store.isLoading && !store.isOperatingDiskImage }
            guard let image = store.activeDiskImage else { throw BrowserFailure.message(store.errorMessage ?? "ISO did not open") }
            mounted = image
            try expect(store.isReadOnlyDirectory && !store.canArchive && !store.canDeleteSelection,
                       "ISO mount disables moving and deleting before any filesystem write")
            try expect(store.assets.count == 1 && store.subdirectories.count == 1 && !store.canDeleteFolder(store.subdirectories[0]),
                       "ISO root preserves Unicode photos and subdirectories and disables folder deletion")
            store.deleteSelection()
            try expect(store.assets.count == 1 && store.errorMessage == nil, "Delete on a read-only image leaves photos unchanged")
            try expect(store.breadcrumbs.last == iso && !store.breadcrumbs.contains(image.root), "image breadcrumbs expose the source rather than private mount paths")
            let decoded = try await ThumbnailCache.shared.image(store.assets[0].preferred, maximum: 520)
            try expect(decoded.image.size.width > 0, "mounted ISO photo decodes through the existing thumbnail pipeline")
            let reused = try await service.mount(iso)
            try expect(reused == image, "repeated opens reuse the same read-only mount")
            store.goUp()
            try await until { !store.isLoading }
            try expect(store.directory == root && !store.isReadOnlyDirectory, "up from the image root returns to the source folder")
            store.navigateHistory(-1)
            try await until { !store.isLoading }
            try expect(store.activeDiskImage == image && store.isReadOnlyDirectory, "back navigation reenters the mounted image")
            store.load(image.root.appendingPathComponent("旅行照片", isDirectory: true))
            try await until { !store.isLoading && !store.isGeneratingPreviews }
            try expect(store.assets.count == 2 && store.assets.contains(where: \.isVideo), "nested ISO folders include both photos and videos")
            let movie = store.assets.first(where: \.isVideo)!
            let playable = try await AVURLAsset(url: movie.preferred.url).load(.isPlayable)
            try expect(playable, "mounted ISO video is playable without extracting the disc")
            try expect(defaults.string(forKey: "lastDiskImagePath") == iso.path && defaults.string(forKey: "lastDiskImageRelativePath") == "旅行照片",
                       "reopen settings retain the ISO source and relative subdirectory")
            let restarted = BrowserStore(supportDirectory: root.appendingPathComponent("restart-support"), defaults: defaults,
                                         monitoringEnabled: false, diskImageService: service)
            restarted.start()
            try await until { !restarted.isLoading && !restarted.isOperatingDiskImage && !restarted.isGeneratingPreviews }
            try expect(restarted.activeDiskImage == image && restarted.directory?.lastPathComponent == "旅行照片",
                       "restarting remounts or reuses the image and restores its subdirectory")
            restarted.cancelPreviewGeneration()
            let held = try FileHandle(forReadingFrom: image.root.appendingPathComponent("封面.jpg"))
            var busyRejected = false
            do { try await service.eject(image) } catch { busyRejected = true }
            try held.close()
            try expect(busyRejected && fm.fileExists(atPath: image.root.appendingPathComponent("封面.jpg").path),
                       "busy images report an error and are never forcibly unmounted")
            store.ejectDiskImage(image)
            try await until { !store.isLoading && !store.isOperatingDiskImage }
            try expect(store.mountedDiskImages.isEmpty && store.directory == root && !store.isReadOnlyDirectory,
                       "eject returns to the source folder and restores normal operations")
            try expect(!store.navigationHistory.contains(where: image.contains), "eject removes stale mount points from navigation history")
            try await service.eject(image)
            try expect(true, "an already-ejected image never detaches another device")
            mounted = nil
            let broken = root.appendingPathComponent("损坏.ISO")
            try Data("not an ISO".utf8).write(to: broken)
            store.load(broken)
            try await until { !store.isLoading && !store.isOperatingDiskImage }
            try expect(store.errorMessage != nil && store.directory == root && store.mountedDiskImages.isEmpty,
                       "invalid uppercase ISO reports an error and preserves the previous directory")
            store.load(iso)
            try await until { !store.isLoading && !store.isOperatingDiskImage && !store.isGeneratingPreviews }
            mounted = store.activeDiskImage
            store.cancelPreviewGeneration()
            try await store.ejectDiskImagesForTermination()
            try expect(store.mountedDiskImages.isEmpty && !store.isOperatingDiskImage, "quit cleanup normally ejects app-owned images")
            mounted = nil
        } catch {
            store.cancelPreviewGeneration()
            if let mounted { try await service.eject(mounted) }
            try fm.removeItem(at: root)
            throw error
        }
        try fm.removeItem(at: root)
    }

    private static func createDiskImage(from source: URL, at destination: URL) throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["makehybrid", "-iso", "-joliet", "-o", destination.path, source.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BrowserFailure.message(String(decoding: data, as: UTF8.self)) }
    }

    @MainActor static func realDiskImageChecks(in directory: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RealISOChecks-" + UUID().uuidString)
        let service = DiskImageService(directory: root.appendingPathComponent("mounts"))
        let thumbnails = ThumbnailCache(directory: root.appendingPathComponent("thumbnails"))
        let cache = DisplayPhotoCache(memoryBudget: 32 * 1024 * 1024)
        let images = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter(DiskImageService.supports).sorted { $0.path < $1.path }
        try expect(!images.isEmpty, "real disc-image directory contains ISO files")
        for source in images {
            let image = try await service.mount(source)
            do {
                let snapshot = try DirectorySnapshot.read(image.root)
                try expect(snapshot.isReadOnly, "\(source.lastPathComponent) mounted read-only")
                guard let sample = try firstPhoto(in: image.root) else { throw BrowserFailure.message("No supported photo found in \(source.lastPathComponent)") }
                let assets = try DirectoryScanner.scan(sample.deletingLastPathComponent())
                guard let file = assets.flatMap(\.imageFiles).first(where: { $0.url.standardizedFileURL == sample.standardizedFileURL }) else { throw BrowserFailure.message("Real ISO sample was not scanned") }
                let thumbnail = try await thumbnails.image(file, maximum: 520)
                let preview = try await cache.image(file, hdr: false, maximum: 2800)
                try expect(thumbnail.image.size.width > 0 && preview.size.width > 0, "\(source.lastPathComponent) supports thumbnails and large previews")
                try await service.eject(image)
                try expect(true, "\(source.lastPathComponent) ejected without modifying the image")
            } catch { try await service.eject(image); throw error }
        }
        try FileManager.default.removeItem(at: root)
    }

    private static func firstPhoto(in root: URL) throws -> URL? {
        // The enumerator owns directory descriptors: release it before attempting eject.
        try autoreleasepool {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])!
            while let url = enumerator.nextObject() as? URL {
                if DirectoryScanner.renderedExtensions.contains(url.pathExtension.lowercased()),
                   try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { return url }
            }
            return nil
        }
    }
}
