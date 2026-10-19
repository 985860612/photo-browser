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
        print("PASS native AI UI: page, facets, selected inspector, label interactions, empty result clears selection")
    }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() { if Date() > deadline { throw BrowserFailure.message("UI wait timed out") }; try await Task.sleep(for: .milliseconds(2)) }
    }
}
