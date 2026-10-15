import AppKit
import SwiftUI
import ImageIO
import Metal
import BrowserCore
import CullingCore

/// Opt-in visual check. Uses generated fixtures and isolated settings; no personal library is opened.
@main struct CullingUIChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PhotoBrowser-CullingUI-" + UUID().uuidString)
        let library = root.appendingPathComponent("library")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let outputPath = CommandLine.arguments.first { $0.hasPrefix("--output=") }.map { String($0.dropFirst(9)) }
        let destination = URL(fileURLWithPath: outputPath ?? "dist/culling-preview", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 4800,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.28, green: 0.61, blue: 0.82, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        context.setFillColor(CGColor(red: 0.18, green: 0.39, blue: 0.49, alpha: 1))
        context.move(to: CGPoint(x: 0, y: 240)); context.addLine(to: CGPoint(x: 360, y: 650)); context.addLine(to: CGPoint(x: 780, y: 210)); context.closePath(); context.fillPath()
        context.setFillColor(CGColor(red: 0.21, green: 0.47, blue: 0.35, alpha: 1))
        context.move(to: CGPoint(x: 430, y: 210)); context.addLine(to: CGPoint(x: 970, y: 570)); context.addLine(to: CGPoint(x: 1200, y: 230)); context.closePath(); context.fillPath()
        context.setFillColor(CGColor(red: 0.09, green: 0.31, blue: 0.42, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 230))
        for index in 0..<8 {
            let file = library.appendingPathComponent(String(format: "DSC%05d.jpg", index + 630))
            let output = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(output, context.makeImage()!, nil)
            guard CGImageDestinationFinalize(output) else { throw BrowserFailure.message("Fixture encoding failed") }
        }
        let suite = "PhotoBrowser.CullingUI." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"),
                                 thumbnails: ThumbnailCache(directory: root.appendingPathComponent("cache")),
                                 defaults: defaults, monitoringEnabled: false)
        defer { store.culling.close(); store.cancelPreviewGeneration() }
        let window = NSWindow(contentRect: NSRect(x: 60, y: 100, width: 1440, height: 940),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Photo Browser — Culling UI Check"
        window.contentView = NSHostingView(rootView: BrowserView().environmentObject(store).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        store.load(library)
        try await until { !store.isLoading && store.culling.available }
        store.setCullingActive(true)
        store.culling.start(assets: store.assets, options: AnalysisOptions())
        try await until { !store.culling.running && !store.culling.grouping }
        guard !store.culling.similarityGroups.isEmpty else { throw BrowserFailure.message("Real Vision produced no similarity group") }
        store.setCullingFilter(.similar, groupID: store.culling.similarityGroups[0].id)
        store.select(store.visibleAssets[1], modifiers: [])
        guard store.culling.mark(.keep, assets: [store.assets[0]]), store.culling.mark(.reject, assets: [store.assets[7]]) else {
            throw BrowserFailure.message("Fixture marks could not be saved")
        }
        try await snapshot(window, named: "compare", in: destination)
        store.culling.grid = true
        try await snapshot(window, named: "grid", in: destination)
        store.culling.grid = false
        window.setContentSize(NSSize(width: 1080, height: 740))
        try await snapshot(window, named: "compact", in: destination)
        window.setContentSize(NSSize(width: 1440, height: 940))
        store.culling.showAnalysisSheet = true
        try await snapshot(window, named: "analysis-sheet", in: destination)
        store.culling.showAnalysisSheet = false
        try await Task.sleep(for: .milliseconds(300))
        store.culling.showResultsSheet = true
        try await snapshot(window, named: "results-sheet", in: destination)
        store.culling.showResultsSheet = false
        window.orderOut(nil)
        print("PASS five culling UI snapshots: \(destination.path)")
    }
    @MainActor static func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(45)
        while !condition() {
            if Date() > deadline { throw BrowserFailure.message("UI fixture timed out") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    @MainActor static func snapshot(_ window: NSWindow, named name: String, in destination: URL) async throws {
        try await Task.sleep(for: .milliseconds(650))
        window.contentView?.layoutSubtreeIfNeeded()
        let output = destination.appendingPathComponent(name + ".png")
        if CommandLine.arguments.contains("--window-capture") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.attachedSheet?.windowNumber ?? window.windowNumber), output.path]
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
                throw BrowserFailure.message("Window capture failed. --window-capture requires Screen Recording permission.")
            }
        } else {
            guard let view = (window.attachedSheet ?? window).contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw BrowserFailure.message("No view bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if window.attachedSheet == nil {
                let panes = canvases(in: view)
                if name == "compare" || name == "compact", panes.count != 2 {
                    throw BrowserFailure.message("Comparison did not create both photo canvases")
                }
                for canvas in panes { try await verifyPixels(canvas) }
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw BrowserFailure.message("No PNG data") }
            try png.write(to: output)
        }
        print("PASS rendered \(name)")
    }
    @MainActor static func canvases(in view: NSView) -> [CanvasView] {
        (view as? CanvasView).map { [$0] } ?? view.subviews.flatMap { canvases(in: $0) }
    }
    @MainActor static func verifyPixels(_ canvas: CanvasView) async throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 256, height: 256, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .shared
        guard let texture = canvas.device?.makeTexture(descriptor: descriptor), let command = canvas.makeFrameCommandBuffer() else {
            throw BrowserFailure.message("UI canvas cannot allocate a render target")
        }
        try canvas.encodeFrame(to: texture, command: command)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }; command.commit()
        }
        if let error = command.error { throw error }
        var pixel = [UInt16](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(128, 128, 1, 1), mipmapLevel: 0)
        }
        guard pixel.prefix(3).contains(where: { Float(Float16(bitPattern: $0)) > 0.01 }) else {
            throw BrowserFailure.message("UI comparison canvas did not load photo pixels")
        }
        print("PASS actual comparison pane has decoded Metal pixels")
    }
}
