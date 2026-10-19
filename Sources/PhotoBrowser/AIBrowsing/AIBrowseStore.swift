import AppKit
import SwiftUI
import BrowserCore

@MainActor final class AIBrowseStore: ObservableObject {
    @Published var active = false
    @Published private(set) var similarityTitle = ""
    private var restoreAfterSimilarity = false
    private var rankedItems: [AICatalogItem] = []
    private var rankKey = ""
    private var normalPosition: (filter: AICatalogFilter, scroll: String?, focused: String?, selection: Set<String>, loaded: Int)?
    func showSimilar(_ item: AICatalogItem) {
        if filter.similaritySeedID == nil { normalPosition = (filter, scrollID, focused, selection, items.count) }
        similarityTitle = item.title; large = false; fullscreen = false
        filter.similaritySeedID = item.id
    }
    func clearSimilarity() {
        var plain = filter; plain.similaritySeedID = nil
        if let position = normalPosition, position.filter == plain {
            restoreScroll = position.scroll; focused = position.focused; selection = position.selection; restoreCount = position.loaded
        }
        normalPosition = nil; similarityTitle = ""
        restoreAfterSimilarity = true; filter = plain
    }
    @Published private(set) var root: URL?
    @Published private(set) var excludedDirectories: [URL] = []
    @Published var filter = AICatalogFilter() { didSet { if filter != oldValue { persist(); reload(debounce: filter.text != oldValue.text) } } }
    @Published private(set) var items: [AICatalogItem] = []
    @Published var selection: Set<String> = []
    @Published var focused: String?
    @Published var scrollID: String?
    @Published var large = false
    @Published var fullscreen = false
    @Published var fields: [AICatalogField] = []
    @Published var states: [AICatalogField] = []
    @Published var expanded: Set<String> = ["scene_codes", "subject_codes", "environment_codes"]
    @Published var facets: [String: [AICatalogFacet]] = [:]
    @Published var facetErrors: [String: String] = [:]
    @Published var facetSearch: [String: String] = [:]
    @Published var expandedLists: Set<String> = []
    @Published var counts: [String: Int] = [:]
    @Published var total = 0
    @Published var complete = false
    @Published var loading = false
    @Published var syncing = false
    @Published var status = ""
    @Published var error: String?
    var selected: AICatalogItem? { items.first { $0.id == focused } }
    var repository: AICatalogRepository?
    private var pageTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var facetTasks: [String: Task<Void, Never>] = [:]
    private var syncTask: Task<Void, Never>?
    private var scopeTask: Task<Void, Never>?
    private var cursor: AICatalogCursor?
    private var hasMore = false
    private var ticket = UUID()
    private var syncTicket = UUID()
    private var lastProgress = Date.distantPast
    private var restoreCount = 60
    private var restoreScroll: String?
    private var anchor: String?
    private var pendingNavigation: (anchor: String, offset: Int, extending: Bool)?
    private var names: [String: String] = UserDefaults.standard.dictionary(forKey: "aiBrowseLabelNames") as? [String: String] ?? [:]
    func remember(field: String, code: String, name: String) { names[field + "|" + code] = name; UserDefaults.standard.set(names, forKey: "aiBrowseLabelNames") }
    func label(field: String, code: String) -> String { names[field + "|" + code] ?? facets[field]?.first { $0.code == code }?.name ?? code }
    private var observer: NSObjectProtocol?
    private struct Saved: Codable { let root: URL; let filter: AICatalogFilter; let scroll: String?; let loaded: Int? }
    init() {
        excludedDirectories = (UserDefaults.standard.stringArray(forKey: "aiBrowseExcludedDirectories") ?? []).map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        if let bytes = UserDefaults.standard.data(forKey: "aiBrowseState"), let saved = try? JSONDecoder().decode(Saved.self, from: bytes) {
            root = saved.root; filter = saved.filter; scrollID = saved.scroll; restoreScroll = saved.scroll; restoreCount = saved.loaded ?? 60
        }
        observer = NotificationCenter.default.addObserver(forName: BackgroundTaskCoordinator.didChange, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, self.active, !self.loading else { return }
                self.reload(preservingPages: true)
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func excludedAncestor(of directory: URL) -> URL? {
        excludedDirectories.filter { AICatalogPaths.contains(directory, in: $0) }.max { $0.path.count < $1.path.count }
    }
    func isDirectlyExcluded(_ directory: URL) -> Bool {
        excludedDirectories.contains { $0.path == directory.standardizedFileURL.path }
    }
    func setExcluded(_ excluded: Bool, directory: URL) {
        let directory = URL(fileURLWithPath: directory.path, isDirectory: true).standardizedFileURL
        guard isDirectlyExcluded(directory) != excluded else { return }
        if excluded { excludedDirectories.append(directory) }
        else { excludedDirectories.removeAll { $0.path == directory.path } }
        excludedDirectories.sort { $0.path < $1.path }
        UserDefaults.standard.set(excludedDirectories.map(\.path), forKey: "aiBrowseExcludedDirectories")
        if let selected, excludedAncestor(of: selected.directory) != nil { focused = nil; selection = []; fullscreen = false; large = false }
        facets = [:]; counts = [:]; total = 0
        reload()
    }
    func activate(directory: URL?) {
        active = true
        if repository == nil {
            do { repository = try AICatalogRepository(); fields = try repository!.fields(); states = try repository!.states() }
            catch { self.error = error.localizedDescription; return }
        }
        if root == nil { root = directory }
        if items.isEmpty { reload(preservingPages: true) }
        if !syncing { prepareIndex() }
    }
    func chooseRoot() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.title = L10n.text("选择分类浏览范围"); panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url { setRoot(url) }
    }
    func setRoot(_ url: URL) {
        guard root != url.standardizedFileURL else { return }
        scopeTask?.cancel(); syncTask?.cancel(); syncTicket = UUID(); syncing = false
        restoreCount = 60; restoreScroll = nil
        root = url.standardizedFileURL; items = []; selection = []; focused = nil; scrollID = nil
        filter = AICatalogFilter(); persist(); reload(); prepareIndex()
    }
    func persist() {
        guard let root else { return }
        do { UserDefaults.standard.set(try JSONEncoder().encode(Saved(root: root, filter: filter, scroll: scrollID, loaded: items.count)), forKey: "aiBrowseState") }
        catch { self.error = error.localizedDescription }
    }
    private func prepareIndex() {
        guard let repository, let root else { return }
        scopeTask?.cancel()
        scopeTask = Task {
            do {
                let indexed = try await repository.lastIndexed(root: root)
                try Task.checkCancellation()
                guard self.root == root else { return }
                if indexed != nil { status = L10n.text("本地索引已就绪，刷新可检查照片变化") }
                else { synchronize() }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func reload(debounce: Bool = false, preservingPages: Bool = false) {
        pageTask?.cancel(); summaryTask?.cancel(); facetTasks.values.forEach { $0.cancel() }
        ticket = UUID(); let request = ticket
        pendingNavigation = nil
        guard let repository, let root else { return }
        let restoring = restoreAfterSimilarity; restoreAfterSimilarity = false
        let query = filter, exclusions = excludedDirectories, target = preservingPages || restoring ? max(60, items.count, restoreCount) : 60
        loading = true
        if !preservingPages { restoreCount = 60; if !restoring { restoreScroll = nil }; items = []; cursor = nil; hasMore = false }
        pageTask = Task {
            do {
                if debounce { try await Task.sleep(for: .milliseconds(200)) }
                var result: [AICatalogItem] = [], after: AICatalogCursor?
                if let seedID = query.similaritySeedID {
                    guard let seed = try await repository.item(id: seedID), excludedAncestor(of: seed.directory) == nil else {
                        clearSimilarity(); status = L10n.text("相似参考图已失效，已恢复普通筛选"); return
                    }
                    similarityTitle = seed.title
                    let revision = try await repository.visualRevision(root: root)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let key = String(decoding: try encoder.encode(query), as: UTF8.self) + root.path + exclusions.map(\.path).joined(separator: "|") + revision
                    if rankKey != key {
                        let ranked = try await repository.rankedPhotos(root: root, filter: query, excluding: exclusions)
                        try Task.checkCancellation(); guard ticket == request else { return }
                        rankedItems = ranked.map(\.item); rankKey = key
                    }
                    items = Array(rankedItems.prefix(max(60, target))); hasMore = items.count < rankedItems.count; loading = false
                    selection.formIntersection(Set(items.map(\.id))); if !items.contains(where: { $0.id == focused }) { focused = items.first?.id }
                    status = L10n.text("按相似度排序，最多显示 500 张；索引进度见后台任务")
                    loadCounts(request: request); return
                }
                repeat {
                    let page = try await repository.page(root: root, filter: query, after: after, excluding: exclusions)
                    try Task.checkCancellation(); guard ticket == request else { return }
                    result += page.items; after = page.cursor
                    items = result; cursor = page.cursor; hasMore = page.hasMore; loading = page.hasMore && result.count < target
                    if !page.hasMore { break }
                } while result.count < target
                restoreCount = 60
                if let restoreScroll { scrollID = restoreScroll; self.restoreScroll = nil }
                selection.formIntersection(Set(items.map(\.id)))
                if let focused, !items.contains(where: { $0.id == focused }) { self.focused = nil; fullscreen = false; large = false; if preservingPages { status = L10n.text("选中的照片已移出当前筛选结果") } }
                loadCounts(request: request)
            } catch is CancellationError {} catch { if ticket == request { self.error = error.localizedDescription; loading = false } }
        }
    }
    func loadMore() {
        if filter.similaritySeedID != nil {
            guard !loading, hasMore else { return }
            items = Array(rankedItems.prefix(items.count + 60)); hasMore = items.count < rankedItems.count
            let pending = pendingNavigation; pendingNavigation = nil
            if let pending, focused == pending.anchor { step(pending.offset, extending: pending.extending) }; return
        }
        guard !loading, hasMore, let repository, let root else { return }
        let query = filter, request = ticket, after = cursor, exclusions = excludedDirectories
        loading = true
        pageTask = Task {
            do {
                let page = try await repository.page(root: root, filter: query, after: after, excluding: exclusions)
                try Task.checkCancellation(); guard ticket == request else { return }
                items += page.items; cursor = page.cursor; hasMore = page.hasMore; loading = false
                let pending = pendingNavigation; pendingNavigation = nil
                if let pending, focused == pending.anchor { step(pending.offset, extending: pending.extending) }
            } catch is CancellationError {} catch { if ticket == request { self.error = error.localizedDescription; loading = false } }
        }
    }
    private func loadCounts(request: UUID) {
        summaryTask?.cancel()
        guard let repository, let root else { return }
        let query = filter, exclusions = excludedDirectories
        summaryTask = Task {
            do {
                let summary = try await repository.summary(root: root, filter: query, excluding: exclusions)
                try Task.checkCancellation(); guard ticket == request else { return }
                total = summary.total; counts = summary.states; complete = summary.complete
            } catch is CancellationError {} catch { if ticket == request { self.error = error.localizedDescription } }
        }
        for field in expanded { loadFacet(field) }
    }
    func loadFacet(_ field: String) {
        facetTasks[field]?.cancel()
        guard filter.state == "processing.succeeded", let repository, let root else { return }
        let query = filter, search = facetSearch[field] ?? "", limit = expandedLists.contains(field) ? 1000 : 10, request = ticket, exclusions = excludedDirectories
        facetErrors[field] = nil
        facetTasks[field] = Task {
            do {
                if !search.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
                let result = try await repository.facets(root: root, filter: query, field: field, search: search, limit: limit, excluding: exclusions)
                try Task.checkCancellation(); guard ticket == request else { return }
                facets[field] = result
            } catch is CancellationError {} catch { if ticket == request { facetErrors[field] = error.localizedDescription } }
        }
    }
    func toggle(_ field: String, code: String) {
        var tags = filter.tags
        if tags[field]?.contains(code) == true { tags[field]?.remove(code) } else { tags[field, default: []].insert(code) }
        filter.tags = tags
    }
    func synchronize() {
        guard !syncing, let repository, let root else { return }
        syncing = true; error = nil; status = L10n.text("正在导入已有识别结果…")
        let request = UUID(); syncTicket = request
        syncTask = Task {
            do {
                try await repository.synchronize(root: root) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.syncTicket == request else { return }
                        if Date().timeIntervalSince(self.lastProgress) > 2 {
                            self.lastProgress = Date()
                            self.status = progress.scanned > 0 ? L10n.text("已核对 \(progress.scanned) 张照片") : L10n.text("已导入 \(progress.imported) 条识别结果")
                            if self.items.isEmpty && !self.loading { self.reload() }
                            else { self.loadCounts(request: self.ticket) }
                        }
                        if let issue = progress.issue { self.error = issue }
                    }
                }
                try Task.checkCancellation(); guard syncTicket == request else { return }
                syncing = false; status = L10n.text("索引更新完成"); reload(preservingPages: true)
            } catch is CancellationError {} catch { if syncTicket == request { syncing = false; self.error = error.localizedDescription; status = L10n.text("索引更新未完成"); reload(preservingPages: true) } }
        }
    }
    func select(_ item: AICatalogItem, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        pendingNavigation = nil
        if modifiers.contains(.shift), let anchor, let a = items.firstIndex(where: { $0.id == anchor }), let b = items.firstIndex(where: { $0.id == item.id }) {
            selection.formUnion(items[min(a,b)...max(a,b)].map(\.id))
        } else if modifiers.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }; anchor = item.id
        } else { selection = [item.id]; anchor = item.id }
        focused = item.id
    }
    func step(_ offset: Int, extending: Bool = false) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == focused }
        if let index, index + offset >= items.count, hasMore {
            let amount = pendingNavigation?.anchor == focused ? (pendingNavigation!.offset + offset) : offset
            pendingNavigation = (items[index].id, amount, extending); loadMore(); return
        }
        let next = index.map { max(0, min(items.count - 1, $0 + offset)) } ?? 0
        select(items[next], modifiers: extending ? [.shift] : []); scrollID = items[next].id
        if next >= items.count - 5 { loadMore() }
    }
    func copyFiles() {
        let urls = items.filter { selection.contains($0.id) }.flatMap { $0.asset.files.map { $0.url as NSURL } }
        guard !urls.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls)
    }
    func reveal() { if let item = selected { NSWorkspace.shared.activateFileViewerSelecting([item.asset.preferred.url]) } }
    func handleKeyDown(_ event: NSEvent, in window: NSWindow?) -> NSEvent? {
        guard let window, !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
              window.identifier?.rawValue != "PhotoBrowser.Settings", window.identifier?.rawValue != "PhotoBrowser.BackgroundTasks", window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 8, modifiers == .command { copyFiles(); return nil }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return event }
        switch event.keyCode {
        case 51, 117: return nil // Never route destructive directory actions into a cross-folder selection.
        case 53: fullscreen = false; large = false; return nil
        case 123, 124: step(event.keyCode == 123 ? -1 : 1, extending: modifiers.contains(.shift)); return nil
        case 49: if selected != nil && !event.isARepeat { fullscreen.toggle() }; return nil
        default: return event
        }
    }
}
