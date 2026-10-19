import AppKit
import SwiftUI
import BrowserCore

@main struct AIBrowseUIChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let savedExclusions = UserDefaults.standard.object(forKey: "aiBrowseExcludedDirectories")
        UserDefaults.standard.removeObject(forKey: "aiBrowseExcludedDirectories")
        defer {
            if let savedExclusions { UserDefaults.standard.set(savedExclusions, forKey: "aiBrowseExcludedDirectories") }
            else { UserDefaults.standard.removeObject(forKey: "aiBrowseExcludedDirectories") }
        }
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: "/Volumes/照片库", isDirectory: true)
        let config: [String: Any] = ["root": root.absoluteString, "filter": ["state": "processing.succeeded", "text": "", "tags": [:], "descending": true], "loaded": 60]
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: config), forKey: "aiBrowseState")
        let store = AIBrowseStore()
        store.repository = try AICatalogRepository(); store.fields = try store.repository!.fields(); store.states = try store.repository!.states(); store.active = true
        let directoryStore = BrowserStore()
        let hosting = NSHostingView(rootView: BrowsingWorkspaceView().environmentObject(directoryStore).environmentObject(store).preferredColorScheme(.dark).frame(minWidth: 1440, minHeight: 940))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1440,height: 940), styleMask: [.titled,.resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting; window.orderFront(nil)
        let start = Date(); store.reload()
        try await wait { !store.loading && !store.items.isEmpty }
        print("UI first page ready ms=\(Date().timeIntervalSince(start)*1000), rows=\(store.items.count)")
        print("STATE root=\(store.root?.path ?? "nil") error=\(store.error ?? "none") loading=\(store.loading) expanded=\(store.expanded)"); fflush(stdout)
        try await wait { store.facets["scene_codes"] != nil || !store.facetErrors.isEmpty }
        print("FACETS \(store.facets.keys) ERRORS \(store.facetErrors)"); fflush(stdout)
        if let first = store.items.first { store.select(first, modifiers: []) }
        try await Task.sleep(for: .seconds(1))
        hosting.displayIfNeeded()
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let output = URL(fileURLWithPath: CommandLine.arguments.last!)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output)
            print("UI screenshot: \(output.path)")
        }
        if let tag = store.facets["scene_codes"]?.first {
            var times: [Double] = []
            for _ in 0..<20 {
                let t = Date(); store.toggle("scene_codes", code: tag.code)
                try await wait { !store.loading }
                hosting.displayIfNeeded(); times.append(Date().timeIntervalSince(t)*1000)
            }
            print("UI tag-to-page p95 ms=\(times.sorted()[18])")
        }
        let total = try await store.repository!.summary(root: root, filter: store.filter).total
        try await wait { !store.loading && store.total == total && total > 0 }
        if let first = store.items.first {
            store.select(first, modifiers: [])
            store.setExcluded(true, directory: first.directory)
            try await wait { !store.loading && store.total < total }
            guard store.items.allSatisfy({ !AICatalogPaths.contains($0.directory, in: first.directory) }), store.focused == nil else {
                throw BrowserFailure.message("Excluded photos or their detail remained visible")
            }
            store.setExcluded(false, directory: first.directory)
            try await wait { !store.loading && store.total == total }
            print("PASS native AI UI folder exclusion and restoration")
        }
        store.filter.text = "__no_photo_should_match_9e058__"
        try await wait { !store.loading }
        guard store.items.isEmpty, store.focused == nil, store.selection.isEmpty else { throw BrowserFailure.message("Empty query must clear selection and detail") }
        window.orderOut(nil)
        try await visualSearchUI(output: URL(fileURLWithPath: CommandLine.arguments.last!).deletingLastPathComponent().appendingPathComponent("similar-photos-ui.png"))
        try await backgroundTasksUI(output: URL(fileURLWithPath: CommandLine.arguments.last!).deletingLastPathComponent().appendingPathComponent("background-tasks-ui.png"))
        print("PASS native AI UI: page, facets, selected inspector, label interactions, empty result clears selection")
    }
    @MainActor static func visualSearchUI(output: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VisualUI-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 128, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = bitmap.representation(using: .png, properties: [:])!
        for n in 0..<4 { try png.write(to: root.appendingPathComponent("photo\(n).PNG")) }
        let repo = try AICatalogRepository(databaseURL: root.appendingPathComponent("catalog.sqlite"), runs: root.appendingPathComponent("runs"), generated: root.appendingPathComponent("generated"))
        try await repo.synchronize(root: root) { _ in }
        var filter = AICatalogFilter(); filter.state = "processing.pending"
        let seed = try await repo.page(root: root, filter: filter).items[0]
        try await repo.indexVisualPhotos(root: root) { _ in }
        let store = AIBrowseStore(); store.repository = repo; store.active = true
        store.fields = try repo.fields(); store.states = try repo.states()
        store.setRoot(root); store.filter.state = "processing.pending"
        try await wait { !store.loading && store.items.count == 4 }
        let normal = store.filter
        store.select(seed, modifiers: []); store.scrollID = seed.id
        let hosting = NSHostingView(rootView: AIBrowseView(onDirectory: { _ in }).environmentObject(store).frame(width: 1440, height: 940))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 940), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua); window.contentView = hosting; window.orderFront(nil)
        store.showSimilar(seed)
        try await wait { !store.loading && store.items.count == 3 }
        guard store.filter.similaritySeedID == seed.id, store.items.allSatisfy({ $0.id != seed.id }), window.attachedSheet == nil else { throw BrowserFailure.message("Similarity must filter the existing wall without presenting a sheet") }
        let coverage = try await repo.visualIndexStatus(root: root)
        guard coverage.indexed == 4 else { throw BrowserFailure.message("Filtering unexpectedly changed vector coverage") }
        store.clearSimilarity()
        try await wait { !store.loading && store.items.count == 4 }
        guard store.filter == normal, store.focused == seed.id else { throw BrowserFailure.message("Clearing similarity did not restore the ordinary selection and filters") }
        store.showSimilar(seed)
        try await wait { !store.loading && store.items.count == 3 }
        let target = store.items[0]
        store.filter.text = target.asset.name
        try await wait { !store.loading && store.items.count == 1 }
        guard store.items[0].id == target.id else { throw BrowserFailure.message("Text and similarity filters did not compose") }
        store.clearSimilarity()
        try await wait { !store.loading && store.items.count == 1 }
        guard store.filter.text == target.asset.name else { throw BrowserFailure.message("Clearing similarity removed another filter") }
        store.filter.text = ""; store.showSimilar(seed)
        try await wait { !store.loading && store.items.count == 3 }
        try await Task.sleep(for: .milliseconds(300)); hosting.displayIfNeeded()
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        }
        window.orderOut(nil)
        print("PASS native inline similarity: no sheet, combined filtering, reference exclusion, restored selection and ordinary sorting; screenshot \(output.path)")
    }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() { if Date() > deadline { throw BrowserFailure.message("UI wait timed out") }; try await Task.sleep(for: .milliseconds(2)) }
    }
    @MainActor static func backgroundTasksUI(output: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundUI-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<48 { for x in 0..<72 {
            let offset = y * bitmap.bytesPerRow + x * 3
            bitmap.bitmapData![offset] = UInt8(x * 3); bitmap.bitmapData![offset + 1] = UInt8(y * 5); bitmap.bitmapData![offset + 2] = UInt8((x * y) % 255)
        } }
        let png = bitmap.representation(using: .png, properties: [:])!
        for n in 0..<65 { try png.write(to: root.appendingPathComponent("task-photo-\(n).PNG")) }
        let repository = try AICatalogRepository(databaseURL: root.appendingPathComponent("catalog.sqlite"), runs: root.appendingPathComponent("runs"), generated: root.appendingPathComponent("generated"))
        try await repository.synchronize(root: root) { _ in }
        let coordinator = BackgroundTaskCoordinator(databaseURL: repository.databaseURL)
        let tasks = BackgroundTaskStore(coordinator: coordinator)
        try await coordinator.start()
        var options = BackgroundTaskOptions(root: root); options.ai = false
        let id = try await coordinator.create(options)
        tasks.selectedTask = id; tasks.show(root: root)
        try await wait { tasks.tasks.first(where: { $0.id == id })?.state == .completed }
        guard tasks.error == nil, let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "PhotoBrowser.BackgroundTasks" }),
              let hosting = window.contentView else { throw BrowserFailure.message("Background task window failed to open") }
        let results = try await coordinator.results(root: root, taskID: id)
        guard results.items.count == 60, results.hasMore, results.items.allSatisfy({ $0.vector == .succeeded && $0.ai == .disabled }) else {
            throw BrowserFailure.message("Task result pagination or independent AI/vector states failed")
        }
        let list = BackgroundResultStore()
        list.load(coordinator: coordinator, root: root, taskID: id, ai: nil, vector: .succeeded, failures: false, exclusions: [])
        try await wait { !list.loading && list.rows.count == 60 }
        try await Task.sleep(for: .milliseconds(300)); hosting.displayIfNeeded()
        if let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: output)
        }
        options.force = true
        let second = try await coordinator.create(options)
        window.close()
        try await wait { tasks.tasks.first(where: { $0.id == second })?.state == .completed }
        guard tasks.error == nil else { throw BrowserFailure.message(tasks.error!) }
        try await tasks.shutdown()
        print("PASS native background UI: task progress, independent results, filtered pagination and work continues after closing the window; screenshot \(output.path)")
    }
}
