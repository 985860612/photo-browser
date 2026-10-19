import AppKit
import BrowserCore

@main struct AIBrowseStoreChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.object(forKey: "aiBrowseState")
        let savedExclusions = UserDefaults.standard.object(forKey: "aiBrowseExcludedDirectories")
        UserDefaults.standard.removeObject(forKey: "aiBrowseExcludedDirectories")
        defer {
            if let savedExclusions { UserDefaults.standard.set(savedExclusions, forKey: "aiBrowseExcludedDirectories") }
            else { UserDefaults.standard.removeObject(forKey: "aiBrowseExcludedDirectories") }
        }
        UserDefaults.standard.removeObject(forKey: "aiBrowseState")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "aiBrowseState") } else { UserDefaults.standard.removeObject(forKey: "aiBrowseState") } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIStore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 0..<125 { try Data("inventory only".utf8).write(to: root.appendingPathComponent("image-\(n).JPG")) }
        let store = AIBrowseStore()
        store.repository = try AICatalogRepository(databaseURL: root.appendingPathComponent("catalog.sqlite"), runs: root.appendingPathComponent("runs"), generated: root.appendingPathComponent("generated"))
        store.setRoot(root)
        for _ in 0..<100 {
            if try await store.repository!.lastIndexed(root: root) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(try await store.repository!.lastIndexed(root: root) != nil, "Initial scope indexing must finish")
        store.filter.state = "processing.pending"
        let deadline = Date().addingTimeInterval(5)
        while store.loading || store.items.count != 60 {
            if Date() > deadline { throw BrowserFailure.message("Initial pending page timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.step(1)
        try require(store.focused == store.items.first?.id, "Arrow navigation starts at the first match")
        store.select(store.items.last!, modifiers: [])
        store.step(1)
        while store.loading { try await Task.sleep(for: .milliseconds(10)) }
        try require(store.items.count == 120 && store.focused == store.items[60].id, "A single next action advances across a page boundary")
        store.filter.tags = ["scene_codes": ["park", "city"], "subject_codes": ["flowers"]]
        store.filter.state = "processing.pending"
        try require(store.filter.tags["scene_codes"]?.count == 2, "Pending state must retain recognized tag selections")
        store.filter.state = "processing.succeeded"
        try require(store.filter.tags["subject_codes"] == ["flowers"], "Returning to recognized must restore tag selections")
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 200,height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        func key(_ code: UInt16) -> NSEvent { NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)! }
        try require(store.handleKeyDown(key(51), in: window) == nil, "AI Delete must be consumed, never reach directory file operations")
        let editor = NSTextView(); window.contentView = editor; window.makeFirstResponder(editor)
        try require(store.handleKeyDown(key(51), in: window) != nil, "Text editing Delete must remain available")
        window.makeFirstResponder(window); window.identifier = NSUserInterfaceItemIdentifier("PhotoBrowser.Settings")
        try require(store.handleKeyDown(key(49), in: window) != nil, "AI keyboard must not intercept settings")
        window.identifier = nil; store.similarityPresented = true
        try require(store.handleKeyDown(key(123), in: window) != nil, "Similar-photo sheets must not navigate the underlying photo wall")
        store.similarityPresented = false
        store.persist()
        let restored = AIBrowseStore()
        try require(restored.root?.path == root.path && restored.filter == store.filter && !restored.active, "Restore scope and filters while defaulting to directory mode")
        restored.repository = store.repository
        restored.activate(directory: root)
        try await Task.sleep(for: .milliseconds(50))
        try require(!restored.syncing, "Completed scopes must open from local cache without restarting inventory")
        while store.syncing { try await Task.sleep(for: .milliseconds(20)) }
        store.filter.state = "processing.pending"
        try await wait { !store.loading && store.items.count == 60 && store.total == 125 }
        store.select(store.items[0], modifiers: []); store.fullscreen = true; store.large = true
        store.setExcluded(true, directory: root)
        try require(store.focused == nil && store.selection.isEmpty && !store.fullscreen && !store.large, "Excluding the selected folder clears selection and preview immediately")
        try await wait { !store.loading && store.items.isEmpty && store.total == 0 && store.counts.isEmpty }
        let withExclusions = AIBrowseStore()
        try require(withExclusions.isDirectlyExcluded(root) && withExclusions.excludedAncestor(of: root.appendingPathComponent("child")) == root, "Exclusions persist independently of the derived catalog and include descendants")
        try require(withExclusions.excludedAncestor(of: URL(fileURLWithPath: root.path + "-backup")) == nil, "Shared-prefix siblings remain included")
        store.setExcluded(false, directory: root)
        try await wait { !store.loading && store.items.count == 60 && store.total == 125 }
        try require(!store.syncing && AIBrowseStore().excludedDirectories.isEmpty, "Removing exclusion restores cached results and saves the change")
        store.setExcluded(true, directory: root.appendingPathComponent("child"))
        store.setExcluded(true, directory: root)
        store.setExcluded(false, directory: root)
        try require(store.isDirectlyExcluded(root.appendingPathComponent("child")), "Removing a parent exclusion preserves explicit child exclusions")
        store.setExcluded(false, directory: root.appendingPathComponent("child"))
        print("PASS AI browse state: pending tag restoration, destructive-key guard, text/settings keys, persisted scope and filters, default directory mode")
        print("PASS AI exclusions: immediate selection reset, inherited paths, persisted settings, cached restoration, independent child rules")
    }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            if Date() > deadline { throw BrowserFailure.message("Exclusion state update timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw BrowserFailure.message(message) } }
}
