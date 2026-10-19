import Foundation

public enum BackgroundState: String, Codable, Sendable, CaseIterable {
    case queued = "task.queued", running = "task.running", pausing = "task.pausing", paused = "task.paused"
    case completed = "task.completed", errors = "task.errors", cancelled = "task.cancelled"
    case pending = "item.pending", preparing = "item.preparing", succeeded = "item.succeeded"
    case reused = "item.reused", failed = "item.failed", disabled = "item.disabled"
    case blocked = "item.blocked"
    public var title: String { BackgroundVocabulary.title(rawValue) }
    public var finished: Bool { [.succeeded, .reused, .disabled, .failed, .cancelled, .blocked].contains(self) }
}
public enum BackgroundStage: String, Codable, Sendable { case preview, ai, vector }

public enum BackgroundVocabulary {
    private struct Term: Decodable { let code: String; let name: String; let en: String }
    private static let terms: [String: Term] = {
        guard let data = try? RecognitionContract.resource("background-task-dictionary", "json"),
              let entries = try? JSONDecoder().decode([Term].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.code, $0) })
    }()
    public static func title(_ code: String) -> String {
        guard let term = terms[code] else { return code }
        return L10n.language == "zh-Hans" ? term.name : term.en
    }
}
public struct BackgroundTaskOptions: Codable, Sendable {
    public var root: URL
    public var ai = true
    public var vector = true
    public var force = false
    public var photoIDs: [String]?
    public var exclusions: [URL] = []
    public init(root: URL) { self.root = root }
}
public struct BackgroundTaskRecord: Identifiable, Sendable {
    public let id: String
    public let root: URL
    public let state: BackgroundState
    public let ai: Bool
    public let vector: Bool
    public let model: String
    public let total: Int
    public let done: Int
    public let reused: Int
    public let failed: Int
    public let active: Int
    public let aiDone: Int
    public let vectorDone: Int
    public let aiFailed: Int
    public let vectorFailed: Int
    public let created: Date
    public let elapsed: Double
    public let issue: String?
    public var rate: Double { elapsed > 0 ? Double(max(0, done - reused)) / elapsed : 0 }
    public var remainingSeconds: Double? { rate > 0 ? Double(max(0, total - done)) / rate : nil }
}
public struct BackgroundPhotoResult: Identifiable, Sendable {
    public var id: String { item.id }
    public let row: Int64
    public let item: AICatalogItem
    public let ai: BackgroundState
    public let vector: BackgroundState
    public let preview: BackgroundState
    public let aiIssue: String?
    public let vectorIssue: String?
    public let previewIssue: String?
    public let vectorUpdated: Date?
    public var issue: String? { previewIssue ?? aiIssue ?? vectorIssue }
}
public struct BackgroundResultPage: Sendable {
    public let items: [BackgroundPhotoResult]
    public let after: Int64?
    public let hasMore: Bool
}
public struct BackgroundTaskEstimate: Sendable {
    public let photos: Int
    public let ai: Int
    public let vectors: Int
}
struct BackgroundWork: Sendable {
    let taskID: String
    let row: Int64
    let snapshot: String
    let item: AICatalogItem
    let stage: BackgroundStage
    let preview: URL?
    let configuration: AIModelConfiguration
    let prompt: String
    var token: String { taskID + ":" + String(row) }
}
