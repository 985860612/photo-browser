import Foundation

public struct DecodeTiming: Sendable {
    public let queue: Double
    public let source: Double
    public let decode: Double
}

/// A bounded session log. Durations are monotonic milliseconds, never wall-clock estimates.
public final class PreviewDiagnostics: @unchecked Sendable {
    public static let shared = PreviewDiagnostics()
    public struct Sample: Sendable, Identifiable {
        public let id: UUID
        public let path: String
        public var cached: Bool?
        public var timing: DecodeTiming?
        public var render: Double?
        public var failed = false
    }
    public struct Snapshot: Sendable {
        public let requests: Int
        public let hits: Int
        public let samples: [Sample]
    }
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var requests = 0
    private var hits = 0
    public init() {}
    public func begin(_ file: PhotoFile) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID(); requests += 1
        samples.append(Sample(id: id, path: file.url.path))
        if samples.count > 100 { samples.removeFirst(samples.count - 100) }
        return id
    }
    public func loaded(_ id: UUID, cached: Bool, timing: DecodeTiming?) {
        lock.lock(); defer { lock.unlock() }
        guard let index = samples.firstIndex(where: { $0.id == id }), samples[index].cached == nil else { return }
        samples[index].cached = cached; samples[index].timing = timing
        if cached { hits += 1 }
    }
    public func failed(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let index = samples.firstIndex(where: { $0.id == id }) { samples[index].failed = true }
    }
    public func currentSample(path: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return samples.last(where: { $0.path == path && $0.cached != nil && !$0.failed })?.id
    }
    public func rendered(_ id: UUID, milliseconds: Double) {
        lock.lock(); defer { lock.unlock() }
        guard let index = samples.firstIndex(where: { $0.id == id }), !samples[index].failed,
              samples[index].render == nil else { return }
        samples[index].render = milliseconds
    }
    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(requests: requests, hits: hits, samples: samples)
    }
    public func reset() { lock.lock(); samples = []; requests = 0; hits = 0; lock.unlock() }
}
