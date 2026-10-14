import Foundation
import Combine
import BrowserCore

struct ThumbnailProgress {
    var running = false
    var completed = 0
    var total = 0
    var failures = 0
    var details = ""
}

/// Owns warming tasks and progress. BrowserStore supplies a snapshot, never the task internals.
@MainActor final class PreviewCoordinator: ObservableObject {
    @Published private(set) var thumbnailsProgress = ThumbnailProgress()
    @Published private(set) var adjacentReady = 0
    @Published private(set) var adjacentTotal = 0
    @Published private(set) var adjacentVideoReady = 0
    @Published private(set) var adjacentVideoTotal = 0

    private struct Key: Hashable {
        let file: PhotoFile
        let hdr: Bool
        let maximum: Int?
    }
    private struct Job {
        let ticket: UUID
        let task: Task<Void, Never>
    }
    private var jobs: [Key: Job] = [:]
    private var request: String?
    private struct Context {
        let request: String
        let neighbors: [PhotoFile]
        let videos: [PhotoFile]
        let hdr: Bool
        let maximum: Int?
    }
    private var context: Context?
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailTicket = UUID()
    private var thumbnailQueue: [PhotoFile] = []
    private let thumbnails: ThumbnailCache
    private let cache: DisplayPhotoCache
    private let video: VideoPlayback

    init(thumbnails: ThumbnailCache, cache: DisplayPhotoCache, video: VideoPlayback) {
        self.thumbnails = thumbnails; self.cache = cache; self.video = video
    }

    func prepare(request: String, current: PhotoFile?, neighbors: [PhotoFile], videos: [PhotoFile],
                 hdr: Bool, maximum: Int?) async {
        self.request = request
        context = Context(request: request, neighbors: neighbors, videos: videos, hdr: hdr, maximum: maximum)
        video.prepareNeighbors(videos)
        await cache.setWorkingSet(current: current, neighbors: neighbors, hdr: hdr)
        guard self.request == request, !Task.isCancelled else { return }
        let ready = await cache.readyCount(neighbors, hdr: hdr, maximum: maximum)
        guard self.request == request, !Task.isCancelled else { return }
        adjacentTotal = neighbors.count; adjacentReady = ready
        let keys = neighbors.map { Key(file: $0, hdr: hdr, maximum: maximum) }
        var retained = Set(keys)
        // A neighbor becoming visible keeps its decode; the foreground promotes shared work.
        if let current { retained.insert(Key(file: current, hdr: hdr, maximum: maximum)) }
        for key in Array(jobs.keys) where !retained.contains(key) {
            jobs.removeValue(forKey: key)?.task.cancel()
        }
        for key in keys where jobs[key] == nil {
            let ticket = UUID(), cache = cache
            let task = Task { [weak self] in
                do { _ = try await cache.image(key.file, hdr: key.hdr, maximum: key.maximum, background: true) }
                catch { /* Bad or cancelled neighbors do not stop the remaining range. */ }
                if self?.jobs[key]?.ticket == ticket { self?.jobs.removeValue(forKey: key) }
                await self?.updateCurrentReadiness()
            }
            jobs[key] = Job(ticket: ticket, task: task)
        }
    }

    private func updateCurrentReadiness() async {
        guard let context else { return }
        await updateReadiness(request: context.request, neighbors: context.neighbors, videos: context.videos,
                              hdr: context.hdr, maximum: context.maximum)
    }

    func updateReadiness(request: String, neighbors: [PhotoFile], videos: [PhotoFile], hdr: Bool, maximum: Int?) async {
        let ready = await cache.readyCount(neighbors, hdr: hdr, maximum: maximum)
        guard self.request == request, !Task.isCancelled else { return }
        adjacentTotal = neighbors.count; adjacentReady = ready
        adjacentVideoTotal = min(8, videos.count)
        adjacentVideoReady = min(adjacentVideoTotal, video.preparedCount)
    }

    func cancelAdjacent() {
        request = nil; context = nil
        for job in jobs.values { job.task.cancel() }
        jobs.removeAll()
        adjacentReady = 0; adjacentTotal = 0
        adjacentVideoReady = 0; adjacentVideoTotal = 0
        video.cancelPreparation()
    }

    func cancel() {
        cancelAdjacent()
        thumbnailTicket = UUID(); thumbnailTask?.cancel(); thumbnailTask = nil
        thumbnailQueue = []; thumbnailsProgress = ThumbnailProgress()
    }

    func start(files: [PhotoFile], priority: [PhotoFile]) {
        cancel()
        guard !files.isEmpty else { return }
        thumbnailQueue = files
        thumbnailsProgress = ThumbnailProgress(running: true, total: files.count)
        prioritize(priority)
        let ticket = thumbnailTicket
        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            var completed = 0, failures = 0, details: [String] = []
            var lastUpdate = Date.distantPast
            while thumbnailTicket == ticket, !Task.isCancelled, !thumbnailQueue.isEmpty {
                let file = thumbnailQueue.removeFirst()
                do { _ = try await thumbnails.image(file, maximum: 520, background: true) }
                catch is CancellationError { return }
                catch {
                    failures += 1
                    if details.count < 20 { details.append("\(file.url.lastPathComponent)：\(error.localizedDescription)") }
                }
                guard thumbnailTicket == ticket, !Task.isCancelled else { return }
                completed += 1
                // Batch cache-hit updates instead of redrawing the gallery for each file.
                if Date().timeIntervalSince(lastUpdate) >= 0.25 || thumbnailQueue.isEmpty {
                    thumbnailsProgress = ThumbnailProgress(running: true, completed: completed, total: files.count,
                                                           failures: failures, details: details.joined(separator: "\n"))
                    lastUpdate = Date()
                }
            }
            guard thumbnailTicket == ticket, !Task.isCancelled else { return }
            do { try await thumbnails.trim() }
            catch is CancellationError { return }
            catch { thumbnailsProgress.details += L10n.text("\n缓存清理失败：\(error.localizedDescription)") }
            guard thumbnailTicket == ticket, !Task.isCancelled else { return }
            thumbnailsProgress.running = false; thumbnailTask = nil
        }
    }

    func prioritize(_ files: [PhotoFile]) {
        guard thumbnailsProgress.running else { return }
        let rank = Dictionary(files.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
        let priority = thumbnailQueue.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        thumbnailQueue = priority + thumbnailQueue.filter { rank[$0.id] == nil }
    }
}
