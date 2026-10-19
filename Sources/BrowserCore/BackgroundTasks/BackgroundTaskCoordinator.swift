import Foundation

public actor BackgroundTaskCoordinator {
    public static let shared = BackgroundTaskCoordinator()
    public nonisolated static let didChange = Notification.Name("PhotoBrowser.BackgroundTaskChanged")
    private let databaseURL: URL?
    private var repository: BackgroundTaskRepository?
    private var stopping = false
    public private(set) var issue: String?
    private var aiLimit = 8
    private var vectorLimit = 2
    private var notificationPending = false
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var work: [UUID: BackgroundWork] = [:]
    private var injected: (@Sendable (BackgroundWork) async throws -> BackgroundWorkOutput)?
    public init(databaseURL: URL? = nil) { self.databaseURL = databaseURL }
    init(databaseURL: URL, execute: @escaping @Sendable (BackgroundWork) async throws -> BackgroundWorkOutput) {
        self.databaseURL = databaseURL; injected = execute
    }
    private func storage() throws -> BackgroundTaskRepository {
        if let repository { return repository }
        let repo = try BackgroundTaskRepository(databaseURL: databaseURL)
        try repo.recover(); repository = repo
        return repo
    }
    public func start(aiConcurrency: Int = 8, vectorConcurrency: Int = 2) throws {
        _ = try storage(); stopping = false
        aiLimit = max(1, min(32, aiConcurrency)); vectorLimit = max(1, min(4, vectorConcurrency))
        try pump()
    }
    public func tasks() throws -> [BackgroundTaskRecord] { try storage().tasks() }
    public func activities() -> [String: String] {
        Dictionary(work.values.map { ($0.item.id, "stage." + $0.stage.rawValue) }, uniquingKeysWith: { first, _ in first })
    }
    public func results(root: URL, taskID: String? = nil, after: Int64 = 0, ai: BackgroundState? = nil, vector: BackgroundState? = nil, failuresOnly: Bool = false, exclusions: [URL] = []) throws -> BackgroundResultPage {
        try storage().results(root: root, taskID: taskID, after: after, ai: ai, vector: vector, failuresOnly: failuresOnly, exclusions: exclusions)
    }
    public func estimate(_ options: BackgroundTaskOptions) throws -> BackgroundTaskEstimate { try storage().estimate(options) }
    public func prepareScope(_ root: URL, assets: [PhotoAsset] = [], refresh: Bool = false) async throws {
        let repo = try AICatalogRepository(databaseURL: storage().databaseURL)
        for asset in assets { try await repo.update(asset, root: root) }
        let empty = try storage().estimate(BackgroundTaskOptions(root: root)).photos == 0
        if refresh || empty {
            try await repo.synchronize(root: root) { _ in }
        }
    }
    @discardableResult public func create(_ options: BackgroundTaskOptions) throws -> String {
        let configuration = try AIModelConfiguration.load()
        if options.ai {
            _ = try configuration.endpoint()
            guard try AIModelKeychain.read(configuration) != nil else { throw BrowserFailure.message(L10n.text("请先在设置 → AI 模型中配置服务和密钥。")) }
        }
        let id = try storage().create(options, configuration: configuration)
        try storage().state(id, .running); try pump(); return id
    }
    public func resume(_ id: String, retryFailures: Bool = false) throws {
        try storage().recoverOrphans(id, active: Array(work.values))
        if retryFailures { try storage().retry(id) }
        stopping = false; issue = nil
        try storage().state(id, .running); try pump()
    }
    public func pause(_ id: String) throws { try storage().state(id, .pausing); try storage().settle(); changed() }
    public func cancel(_ id: String) throws {
        try storage().state(id, .cancelled); try storage().cancelPending(id)
        for (key, value) in work where value.taskID == id { workers[key]?.cancel() }
        changed()
    }
    public func shutdown() throws {
        stopping = true
        for record in try storage().tasks() where [.queued, .running, .pausing].contains(record.state) { try storage().state(record.id, .paused) }
        for worker in workers.values { worker.cancel() }
    }
    private func changed() {
        guard !notificationPending else { return }; notificationPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            notificationPending = false
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }
    private func pump() throws {
        guard !stopping else { return }
        let repo = try storage()
        try repo.settle()
        for (stage, limit) in [(BackgroundStage.preview, 2), (.ai, aiLimit), (.vector, vectorLimit)] {
            while work.values.filter({ $0.stage == stage }).count < limit {
                guard let item = try repo.claim(stage) else { break }
                if try repo.reuse(item) {
                    try repo.finish(item, state: .reused); continue
                }
                let id = UUID(), runner = injected
                work[id] = item
                workers[id] = Task.detached(priority: .utility) { [weak self] in
                    do {
                        let result: BackgroundWorkOutput
                        if let runner { result = try await runner(item) }
                        else { result = try await BackgroundWorker.perform(item) }
                        Task.detached { await self?.finished(id, output: result, error: nil) }
                    } catch { Task.detached { await self?.finished(id, output: nil, error: error) } }
                }
            }
        }
        try repo.settle(); changed()
    }
    private func finished(_ id: UUID, output: BackgroundWorkOutput?, error: Error?) async {
        guard let item = work.removeValue(forKey: id) else { return }
        workers[id] = nil
        do {
            let repo = try storage()
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                let cancelled = try repo.taskState(item.taskID) == .cancelled
                try repo.finish(item, state: cancelled ? .cancelled : .pending)
            } else if let error {
                if item.stage == .ai, let http = error as? AIModelHTTPError, [401, 403].contains(http.status) {
                    try repo.finish(item, state: .pending, issue: error.localizedDescription)
                    try repo.blockAI(item.taskID, issue: error.localizedDescription)
                } else if item.stage == .preview,
                          let root = try repo.taskRoot(item.taskID),
                          !FileManager.default.fileExists(atPath: root.path) {
                    try repo.finish(item, state: .pending, issue: error.localizedDescription)
                    try repo.state(item.taskID, .pausing, issue: L10n.text("照片目录不可用，请连接存储设备后继续。"))
                } else { try repo.finish(item, state: .failed, issue: error.localizedDescription) }
            } else if let output {
                try repo.finish(item, state: output.reused ? .reused : .succeeded, preview: output.preview, data: output.data, metadata: output.metadata)
            }
            try pump()
        } catch {
            // A checkpoint error is visible and stops new dispatch; never silently repeat paid work.
            stopping = true; issue = error.localizedDescription
            do {
                for task in try storage().tasks() where [.running, .pausing].contains(task.state) {
                    try storage().state(task.id, .paused, issue: error.localizedDescription)
                }
            } catch { issue = (issue ?? "") + " · " + error.localizedDescription }
            for task in workers.values { task.cancel() }
            changed()
        }
    }
}
