import Foundation

/// Decoded originals stay in RAM. HDR pixels are never stored as an SDR JPEG.
public actor DisplayPhotoCache {
    public static let shared = DisplayPhotoCache()
    public struct Statistics: Sendable {
        public let decodes: Int
        public let hits: Int
        public let bytes: Int
        public let entries: Int
        public let pending: Int
    }
    private struct Key: Hashable {
        let file: PhotoFile
        let hdr: Bool
        let maximum: Int?
    }
    private struct Entry {
        let photo: DisplayPhoto
        var touched: UInt64
    }
    private struct Pending {
        let ticket: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<DisplayPhoto, Error>]
        let background: Bool
        let priority: PreviewWorkPriority
        let generation: UUID
    }
    private let workers: PreviewWorkQueue
    private let budget: Int
    private var entries: [Key: Entry] = [:]
    private var pending: [Key: Pending] = [:]
    private var protected: Key?
    private var clock: UInt64 = 0
    private var bytes = 0
    private var decodes = 0
    private var hits = 0
    private var generation = UUID()
    private var workingSet: [PhotoFile: Int] = [:]
    private var workingHDR = true
    private var memoryPressure: DispatchSourceMemoryPressure?

    public init(memoryBudget: Int? = nil, workers: PreviewWorkQueue = PreviewWorkQueue()) {
        // Covers browsing and native-resolution entries together; independent of thumbnail RAM.
        // One sixteenth of physical RAM (128 MiB...4 GiB) accommodates neighboring high-resolution RAWs.
        budget = max(0, memoryBudget ?? min(4 * 1024 * 1024 * 1024, max(128 * 1024 * 1024,
                                                               Int(ProcessInfo.processInfo.physicalMemory / 16))))
        self.workers = workers
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        memoryPressure = pressure
        pressure.setEventHandler { [weak self] in Task { await self?.releaseNeighbors() } }
        pressure.resume()
    }

    deinit { memoryPressure?.cancel() }

    public func setWorkingSet(current: PhotoFile?, neighbors: [PhotoFile], hdr: Bool) {
        workingHDR = hdr
        let files = current.map { [$0] + neighbors } ?? []
        workingSet = Dictionary(files.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
    }

    public func releaseNeighbors() {
        for key in Array(entries.keys) where key != protected { remove(key) }
    }

    public func statistics() -> Statistics {
        Statistics(decodes: decodes, hits: hits, bytes: bytes, entries: entries.count, pending: pending.count)
    }

    /// Inspect actual residency without touching LRU order or counting a UI cache hit.
    public func readyCount(_ files: [PhotoFile], hdr: Bool, maximum: Int?) -> Int {
        files.filter { file in
            entries[Key(file: file, hdr: hdr, maximum: maximum)] != nil
                || (maximum != nil && entries[Key(file: file, hdr: hdr, maximum: nil)] != nil)
        }.count
    }

    /// A native-resolution entry can satisfy a smaller request, but never the reverse.
    public func cached(_ file: PhotoFile, hdr: Bool, maximum: Int?, protect: Bool = false) -> DisplayPhoto? {
        let key = Key(file: file, hdr: hdr, maximum: maximum)
        let native = Key(file: file, hdr: hdr, maximum: nil)
        let found = entries[key] != nil ? key : (maximum != nil && entries[native] != nil ? native : nil)
        guard let found, var entry = entries[found] else { return nil }
        clock &+= 1; entry.touched = clock; entries[found] = entry; hits += 1
        if protect { protected = found }
        return entry.photo
    }

    public func image(_ file: PhotoFile, hdr: Bool, maximum: Int? = nil,
                      background: Bool = false) async throws -> DisplayPhoto {
        try Task.checkCancellation()
        let key = Key(file: file, hdr: hdr, maximum: maximum)
        if !background { protected = key }
        if let photo = cached(file, hdr: hdr, maximum: maximum, protect: !background) { return photo }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var request = pending[key] {
                    request.waiters[waiter] = continuation; pending[key] = request
                    if !background { request.priority.promote() }
                    return
                }
                let ticket = UUID(), workers = workers, priority = PreviewWorkPriority()
                let queuedAt = ProcessInfo.processInfo.systemUptime
                let task = Task {
                    let result: Result<DisplayPhoto, Error>
                    do {
                        let photo = try await workers.run(background: background, priority: priority) { check in
                            try OriginalPhotoDecoder.decode(file, hdr: hdr, maximum: maximum, queuedAt: queuedAt, check: check)
                        }
                        result = .success(photo)
                    } catch { result = .failure(error) }
                    finish(key, ticket: ticket, result: result)
                }
                decodes += 1
                pending[key] = Pending(ticket: ticket, task: task, waiters: [waiter: continuation], background: background, priority: priority, generation: generation)
            }
        } onCancel: { Task { await self.cancel(key, waiter: waiter) } }
    }

    public func removeAll() {
        generation = UUID()
        entries.removeAll(); bytes = 0; protected = nil
    }
    public func invalidate(_ files: [PhotoFile]) {
        let urls = Set(files.map(\.url))
        for key in Array(entries.keys) where urls.contains(key.file.url) { remove(key) }
        for key in Array(pending.keys) where urls.contains(key.file.url) {
            if let request = pending.removeValue(forKey: key) {
                request.task.cancel(); request.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
            }
        }
    }

    private func cancel(_ key: Key, waiter: UUID) {
        guard var request = pending[key], let continuation = request.waiters.removeValue(forKey: waiter) else { return }
        if request.waiters.isEmpty { pending.removeValue(forKey: key); request.task.cancel() }
        else { pending[key] = request }
        continuation.resume(throwing: CancellationError())
    }

    private func finish(_ key: Key, ticket: UUID, result: Result<DisplayPhoto, Error>) {
        guard let request = pending[key], request.ticket == ticket else { return }
        pending.removeValue(forKey: key)
        if case .success(let photo) = result, request.generation == generation, photo.memoryCost <= budget {
            // A modified source must not leave obsolete versions occupying the cache.
            let obsolete = entries.keys.filter { $0.file.url == key.file.url && $0.file != key.file }
            for old in obsolete { remove(old) }
            if key.maximum == nil { remove(Key(file: key.file, hdr: key.hdr, maximum: 2800)) }
            var mayInsert = true
            while bytes + photo.memoryCost > budget {
                guard let victim = entries.filter({ $0.key != protected }).max(by: {
                    let a = rank($0.key), b = rank($1.key)
                    return a == b ? $0.value.touched > $1.value.touched : a < b
                })?.key else { break }
                // Do not evict a near neighbor just to store a farther preloaded photo.
                if request.background, key != protected, rank(key) >= rank(victim), rank(victim) != Int.max {
                    mayInsert = false; break
                }
                remove(victim)
            }
            if mayInsert && bytes + photo.memoryCost <= budget {
                clock &+= 1
                entries[key] = Entry(photo: photo, touched: clock); bytes += photo.memoryCost
            }
        }
        request.waiters.values.forEach { $0.resume(with: result) }
    }

    private func rank(_ key: Key) -> Int { key.hdr == workingHDR ? workingSet[key.file] ?? Int.max : Int.max }

    private func remove(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) { bytes -= entry.photo.memoryCost }
    }
}
