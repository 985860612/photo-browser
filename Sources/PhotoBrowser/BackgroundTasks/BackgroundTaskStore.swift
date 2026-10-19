import SwiftUI
import AppKit
import BrowserCore

@MainActor final class BackgroundTaskStore: ObservableObject {
    static let shared = BackgroundTaskStore()
    let coordinator: BackgroundTaskCoordinator
    init(coordinator: BackgroundTaskCoordinator = .shared) { self.coordinator = coordinator }
    @Published private(set) var tasks: [BackgroundTaskRecord] = []
    @Published private(set) var activities: [String: String] = [:]
    @Published var error: String?
    @Published var root = URL(fileURLWithPath: "/Volumes/照片库", isDirectory: true)
    @Published var selectedAssets: [PhotoAsset] = []
    @Published var exclusions: [URL] = []
    @Published var selectedTask: String?
    @Published var revision = 0
    @Published private(set) var pendingPhotos: Set<String> = []
    @Published private(set) var submittedTasks: [String: String] = [:]
    @Published var aiConcurrency = UserDefaults.standard.object(forKey: "backgroundAIConcurrency") as? Int ?? 8
    @Published var vectorConcurrency = UserDefaults.standard.object(forKey: "backgroundVectorConcurrency") as? Int ?? 2
    private var poll: Task<Void, Never>?
    private var window: NSWindow?
    weak var browse: AIBrowseStore?
    private weak var browsingWindow: NSWindow?
    var activeCount: Int { tasks.filter { [.running, .queued, .pausing].contains($0.state) }.count }
    func start() {
        guard poll == nil else { return }
        poll = Task {
            do {
                try await self.coordinator.start(aiConcurrency: aiConcurrency, vectorConcurrency: vectorConcurrency)
                while !Task.isCancelled {
                    try await refresh()
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription; poll = nil }
        }
    }
    func refresh() async throws {
        tasks = try await self.coordinator.tasks()
        activities = await self.coordinator.activities()
        if let failure = await self.coordinator.issue { error = failure }
        revision += 1
    }
    func configureConcurrency() {
        aiConcurrency = max(1, min(32, aiConcurrency)); vectorConcurrency = max(1, min(4, vectorConcurrency))
        UserDefaults.standard.set(aiConcurrency, forKey: "backgroundAIConcurrency")
        UserDefaults.standard.set(vectorConcurrency, forKey: "backgroundVectorConcurrency")
        run { try await self.coordinator.start(aiConcurrency: self.aiConcurrency, vectorConcurrency: self.vectorConcurrency) }
    }
    func run(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task { do { try await action(); try await refresh() } catch { self.error = error.localizedDescription } }
    }
    func pause(_ id: String) { run { try await self.coordinator.pause(id) } }
    func resume(_ id: String, retry: Bool = false) { run { try await self.coordinator.resume(id, retryFailures: retry) } }
    func cancel(_ id: String) { run { try await self.coordinator.cancel(id) } }
    func submit(_ asset: PhotoAsset) {
        start()
        let identity = AICatalogItem.identity(asset)
        guard !pendingPhotos.contains(identity) else { return }
        pendingPhotos.insert(identity)
        Task {
          do {
            let root = asset.preferred.url.deletingLastPathComponent()
            try await self.coordinator.prepareScope(root, assets: [asset])
            var options = BackgroundTaskOptions(root: root); options.photoIDs = [AICatalogItem.identity(asset)]
            options.vector = false; options.force = true
            self.selectedTask = try await self.coordinator.create(options)
            submittedTasks[identity] = selectedTask
            try await refresh()
          } catch { self.error = error.localizedDescription }
          pendingPhotos.remove(identity)
        }
    }
    func isGenerating(_ asset: PhotoAsset) -> Bool {
        let id = AICatalogItem.identity(asset)
        return pendingPhotos.contains(id) || tasks.contains { $0.id == submittedTasks[id] && [.queued, .running, .pausing].contains($0.state) }
    }
    func cancelPhoto(_ asset: PhotoAsset) {
        if let id = submittedTasks[AICatalogItem.identity(asset)] { cancel(id) }
    }
    func show(root: URL? = nil, assets: [PhotoAsset] = [], exclusions: [URL] = []) {
        if NSApp.keyWindow?.identifier?.rawValue != "PhotoBrowser.BackgroundTasks" { browsingWindow = NSApp.keyWindow }
        if let root { self.root = root }
        selectedAssets = assets; self.exclusions = exclusions; start()
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("后台任务")
        window.identifier = NSUserInterfaceItemIdentifier("PhotoBrowser.BackgroundTasks")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BackgroundTaskWindow(store: self).preferredColorScheme(.dark))
        window.minSize = NSSize(width: 1050, height: 660)
        window.center(); self.window = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showSimilar(_ item: AICatalogItem, root: URL) {
        guard let browse else { return }
        browse.active = true; browse.activate(directory: root)
        if browse.root != root { browse.setRoot(root) }
        browse.showSimilar(item); browsingWindow?.makeKeyAndOrderFront(nil)
    }
    func shutdown() async throws {
        poll?.cancel(); poll = nil
        try await self.coordinator.shutdown()
    }
}
