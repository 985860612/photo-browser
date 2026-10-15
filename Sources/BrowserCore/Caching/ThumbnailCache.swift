import AppKit
import ImageIO
import CryptoKit

public actor ThumbnailCache {
    public static let shared = ThumbnailCache()
    private final class Entry: NSObject {
        let preview: LoadedPreview
        init(_ preview: LoadedPreview) { self.preview = preview }
    }
    private struct Pending {
        let ticket: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<LoadedPreview, Error>]
        var keepInMemory: Bool
    }
    private let memory = NSCache<NSString, Entry>()
    private struct SourceMetadata: Codable {
        let metadata: PhotoMetadata?
        var version: Int? = 2
    }
    private final class MetadataEntry: NSObject {
        let value: SourceMetadata
        init(_ value: SourceMetadata) { self.value = value }
    }
    private let metadataMemory = NSCache<NSString, MetadataEntry>()
    private var metadataGeneration = UUID()
    private var pending: [String: Pending] = [:]
    private let directory: URL
    private let workers: PreviewWorkQueue
    private let disk: ThumbnailDiskStore
    private let local = PreviewWorkQueue()
    private let metadataWorkers = PreviewWorkQueue()
    private var maintenance: Task<Void, Never>?
    private var maintenanceNeeded = false
    private var maintenanceFailure: String?
    private var maintenanceID = UUID()
    private var knownKeys: [String: Set<String>] = [:]

    public init(directory: URL? = nil, workers: PreviewWorkQueue = .shared, diskLimit: Int64 = 2_000_000_000) {
        let directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoBrowser/Thumbnails", isDirectory: true)
        self.directory = directory
        disk = ThumbnailDiskStore(directory: directory, limit: diskLimit)
        self.workers = workers
        memory.countLimit = 160; memory.totalCostLimit = 180 * 1024 * 1024
        metadataMemory.countLimit = 160
    }

    public nonisolated static func digest(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
    private nonisolated static func key(_ file: PhotoFile, maximum: Int) -> String {
        Self.digest("\(file.kind == .video ? "video-v1" : "v1")|\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)|\(maximum)")
    }

    private nonisolated static func metadataKey(_ file: PhotoFile) -> String {
        Self.digest("metadata-v1|\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)")
    }

    /// Read the original header independently of old/embedded thumbnail metadata. No pixel decoding.
    /// Missing lens/GPS tags are cached too. Old headers are enriched once without regenerating JPEGs.
    public func sourceMetadata(_ file: PhotoFile) async throws -> PhotoMetadata? {
        try Task.checkCancellation()
        let key = Self.metadataKey(file)
        knownKeys[file.id, default: []].insert(key)
        if let cached = metadataMemory.object(forKey: key as NSString) {
            disk.touch(key); scheduleMaintenance(); return cached.value.metadata
        }
        let disk = disk, directory = directory, token = disk.token(key), generation = metadataGeneration
        let value = try await metadataWorkers.run(background: true) { check in
            try check()
            let saved: SourceMetadata? = try disk.read {
                let url = directory.appendingPathComponent(key + ".json")
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let bytes = try Data(contentsOf: url)
                do { return try JSONDecoder().decode(SourceMetadata.self, from: bytes) }
                catch is DecodingError { return nil } // Damaged local metadata can be reread.
            }
            if let saved, saved.version == 2, saved.metadata != nil { try check(); return saved }
            guard FileManager.default.fileExists(atPath: file.url.path),
                  let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw BrowserFailure.message(L10n.text("无法读取 \(file.url.lastPathComponent)"))
            }
            guard let metadata = ImageMetadataReader.read(source) else {
                throw BrowserFailure.message(L10n.text("无法读取 \(file.url.lastPathComponent)"))
            }
            let value = SourceMetadata(metadata: metadata)
            try check()
            try disk.write(JSONEncoder().encode(value), key: key, suffix: ".json", token: token)
            try check(); return value
        }
        try Task.checkCancellation()
        guard disk.token(key) == token, metadataGeneration == generation else { throw CancellationError() }
        metadataMemory.setObject(MetadataEntry(value), forKey: key as NSString)
        disk.touch(key); scheduleMaintenance()
        return value.metadata
    }

    /// Decode the original at native resolution; never substitute an embedded JPEG.
    public nonisolated func fullResolution(_ file: PhotoFile) async throws -> LoadedPreview {
        try await workers.run { check in try ThumbnailImageDecoder.fullResolution(file, check: check) }
    }

    /// Visible requests share the same decode with prefetch, but only visible images enter RAM.
    public func image(_ file: PhotoFile, maximum: Int, background: Bool = false) async throws -> LoadedPreview {
        try Task.checkCancellation()
        let key = Self.key(file, maximum: maximum)
        knownKeys[file.id, default: []].insert(key)
        if let cached = memory.object(forKey: key as NSString) { disk.touch(key); scheduleMaintenance(); return cached.preview }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var current = pending[key] {
                    current.waiters[waiter] = continuation
                    current.keepInMemory = current.keepInMemory || !background
                    pending[key] = current
                    return
                }
                let ticket = UUID(), directory = directory, workers = workers, disk = disk, diskToken = disk.token(key)
                let task = Task {
                    let result: Result<LoadedPreview, Error>
                    do {
                        let preview: LoadedPreview
                        if file.kind == .video {
                            let saved = try await workers.run(background: background) { check in
                                try disk.read { try ThumbnailImageDecoder.readCached(key: key, directory: directory, check: check) }
                            }
                            if let saved { preview = saved }
                            else {
                                let generated = try await VideoMedia.preview(file, maximum: maximum, background: background)
                                preview = try await workers.run(background: background) { check in
                                    try ThumbnailImageDecoder.saveVideo(generated, key: key, disk: disk, token: diskToken, check: check)
                                }
                            }
                        } else {
                            preview = try await workers.run(background: background) { check in
                                try ThumbnailImageDecoder.readOrGenerate(file, maximum: maximum, key: key, directory: directory, disk: disk, token: diskToken, check: check)
                            }
                        }
                        result = .success(preview)
                    } catch { result = .failure(error) }
                    finish(key, ticket: ticket, result: result)
                }
                pending[key] = Pending(ticket: ticket, task: task, waiters: [waiter: continuation], keepInMemory: !background)
            }
        } onCancel: {
            Task { await self.cancel(key, waiter: waiter) }
        }
    }

    private func cancel(_ key: String, waiter: UUID) {
        guard var current = pending[key], let continuation = current.waiters.removeValue(forKey: waiter) else { return }
        if current.waiters.isEmpty { pending.removeValue(forKey: key); current.task.cancel() }
        else { pending[key] = current }
        continuation.resume(throwing: CancellationError())
    }

    private func finish(_ key: String, ticket: UUID, result: Result<LoadedPreview, Error>) {
        guard let current = pending[key], current.ticket == ticket else { return }
        pending.removeValue(forKey: key)
        if case .success = result { disk.touch(key); scheduleMaintenance() }
        if case .success(let preview) = result, current.keepInMemory {
            memory.setObject(Entry(preview), forKey: key as NSString,
                             cost: Int(preview.image.size.width * preview.image.size.height) * 4)
        }
        current.waiters.values.forEach { $0.resume(with: result) }
    }

    /// Maintenance also uses the utility lane; never blocks memory hits or visible decoding.
    public func trim() async throws {
        // Only work in progress is protected. A large current directory cannot bypass the quota.
        let protected = Set(pending.keys), disk = disk
        try await local.run(background: true) { check in
            try check()
            try disk.trim(protecting: protected, check: check)
        }
    }

    public func diskUsage() async throws -> ThumbnailDiskUsage {
        let disk = disk
        return try await local.run(background: true) { _ in try disk.usage() }
    }
    public func diskMaintenanceError() -> String? { maintenanceFailure }
    /// Flush recent accesses when quitting, before the coalesced maintenance timer expires.
    public nonisolated func persistAccesses() throws { try disk.persistAccesses() }
    public func setDiskLimit(_ bytes: Int64) async throws { disk.setLimit(bytes); try await trim() }
    public func clear() async throws {
        metadataGeneration = UUID()
        maintenanceID = UUID()
        maintenance?.cancel(); maintenance = nil; maintenanceNeeded = false
        let requests = pending.values; pending.removeAll(); memory.removeAllObjects(); metadataMemory.removeAllObjects(); knownKeys.removeAll()
        for request in requests { request.task.cancel(); request.waiters.values.forEach { $0.resume(throwing: CancellationError()) } }
        let disk = disk
        try await local.run(background: true) { _ in try disk.clear() }
    }
    public func invalidate(_ files: [PhotoFile]) async throws {
        let keys = files.reduce(into: Set<String>()) { keys, file in
            keys.formUnion(knownKeys[file.id] ?? []); keys.insert(Self.key(file, maximum: 520)); keys.insert(Self.metadataKey(file))
        }
        guard !keys.isEmpty else { return }
        metadataGeneration = UUID()
        for key in keys {
            memory.removeObject(forKey: key as NSString)
            metadataMemory.removeObject(forKey: key as NSString)
            if let request = pending.removeValue(forKey: key) {
                request.task.cancel(); request.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
            }
        }
        let disk = disk
        try await local.run(background: true) { _ in try disk.invalidate(keys) }
    }
    private func scheduleMaintenance() {
        maintenanceNeeded = true
        guard maintenance == nil else { return }
        let ticket = UUID(); maintenanceID = ticket
        maintenance = Task { [weak self] in
            // Coalesce rapid hits; do not enumerate local cache files for every thumbnail.
            try? await Task.sleep(for: .seconds(2))
            await self?.performMaintenance(ticket)
        }
    }
    private func performMaintenance(_ ticket: UUID) async {
        while !Task.isCancelled, maintenanceID == ticket, maintenanceNeeded {
            maintenanceNeeded = false
            do { try await trim(); maintenanceFailure = nil }
            catch is CancellationError { break }
            catch { maintenanceFailure = error.localizedDescription; break }
        }
        if maintenanceID == ticket { maintenance = nil }
    }


}
