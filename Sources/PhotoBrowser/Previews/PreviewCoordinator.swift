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
    private var thumbnailQueue: ThumbnailWarmQueue?
    private var priorityTask: Task<Void, Never>?
    private var priorityAnchor: (index: Int, assets: [PhotoAsset], revision: Int)?
    private var priorityRevision = 0
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
        if adjacentTotal != neighbors.count { adjacentTotal = neighbors.count }
        if adjacentReady != ready { adjacentReady = ready }
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
        if adjacentTotal != neighbors.count { adjacentTotal = neighbors.count }
        if adjacentReady != ready { adjacentReady = ready }
        let videoTotal = min(8, videos.count), videoReady = min(videoTotal, video.preparedCount)
        if adjacentVideoTotal != videoTotal { adjacentVideoTotal = videoTotal }
        if adjacentVideoReady != videoReady { adjacentVideoReady = videoReady }
    }

    func cancelAdjacent() {
        request = nil; context = nil
        for job in jobs.values { job.task.cancel() }
        jobs.removeAll()
        if adjacentReady != 0 { adjacentReady = 0 }
        if adjacentTotal != 0 { adjacentTotal = 0 }
        if adjacentVideoReady != 0 { adjacentVideoReady = 0 }
        if adjacentVideoTotal != 0 { adjacentVideoTotal = 0 }
        video.cancelPreparation()
    }

    func cancel() {
        cancelAdjacent()
        thumbnailTicket = UUID(); thumbnailTask?.cancel(); thumbnailTask = nil
        priorityTask?.cancel(); priorityTask = nil; priorityAnchor = nil
        thumbnailQueue = nil; thumbnailsProgress = ThumbnailProgress()
    }

    func start(files: [PhotoFile], priority: [PhotoFile]) {
        cancel()
        guard !files.isEmpty else { return }
        let queue = ThumbnailWarmQueue(files: files, priority: priority)
        thumbnailQueue = queue
        thumbnailsProgress = ThumbnailProgress(running: true, total: files.count)
        let ticket = thumbnailTicket
        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            var completed = 0, failures = 0, details: [String] = []
            var lastUpdate = Date.distantPast
            let finished = await withTaskGroup(of: ThumbnailCompletion.self, returning: Bool.self) { group in
                @MainActor func enqueue() async {
                    guard self.thumbnailTicket == ticket, !Task.isCancelled, let file = await queue.next() else { return }
                    guard self.thumbnailTicket == ticket, !Task.isCancelled else { return }
                    let cache = self.thumbnails
                    group.addTask {
                        do { _ = try await cache.image(file, maximum: 520, background: true); return ThumbnailCompletion() }
                        catch is CancellationError { return ThumbnailCompletion(cancelled: true) }
                        catch { return ThumbnailCompletion(failure: "\(file.url.lastPathComponent)：\(error.localizedDescription)") }
                    }
                }
                // Bound the producer as well as the decoding queue; never enqueue the whole library.
                await enqueue(); await enqueue()
                while let result = await group.next() {
                    guard self.thumbnailTicket == ticket, !Task.isCancelled, !result.cancelled else { group.cancelAll(); return false }
                    completed += 1
                    if let failure = result.failure {
                        failures += 1
                        if details.count < 20 { details.append(failure) }
                    }
                    await enqueue()
                    if Date().timeIntervalSince(lastUpdate) >= 0.5 || completed == files.count {
                        self.thumbnailsProgress = ThumbnailProgress(running: true, completed: completed, total: files.count,
                                                               failures: failures, details: details.joined(separator: "\n"))
                        lastUpdate = Date()
                    }
                }
                return true
            }
            guard thumbnailTicket == ticket, !Task.isCancelled else { return }
            guard finished else { finishThumbnails(); return }
            do { try await thumbnails.trim() }
            catch is CancellationError { return }
            catch { thumbnailsProgress.details += L10n.text("\n缓存清理失败：\(error.localizedDescription)") }
            guard thumbnailTicket == ticket, !Task.isCancelled else { return }
            finishThumbnails()
        }
    }

    private func finishThumbnails() {
        priorityTask?.cancel(); priorityTask = nil; priorityAnchor = nil; thumbnailQueue = nil
        thumbnailsProgress.running = false; thumbnailTask = nil
    }

    func prioritize(_ files: [PhotoFile]) {
        guard thumbnailsProgress.running, let queue = thumbnailQueue else { return }
        priorityTask?.cancel(); priorityTask = nil; priorityAnchor = nil
        priorityRevision += 1
        let revision = priorityRevision
        Task { await queue.prioritize(files, revision: revision) }
    }

    func prioritize(around index: Int, in assets: [PhotoAsset]) {
        guard thumbnailsProgress.running, let queue = thumbnailQueue else { return }
        priorityRevision += 1
        priorityAnchor = (index, assets, priorityRevision)
        guard priorityTask == nil else { return }
        let ticket = thumbnailTicket
        priorityTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, self.thumbnailTicket == ticket, !Task.isCancelled else { return }
            let anchor = self.priorityAnchor
            self.priorityAnchor = nil
            if let anchor { await queue.prioritize(around: anchor.index, in: anchor.assets, revision: anchor.revision) }
            guard self.thumbnailTicket == ticket, !Task.isCancelled else { return }
            self.priorityTask = nil
            // Card appearances while the actor was working belong to the next bounded batch.
            if let anchor = self.priorityAnchor { self.prioritize(around: anchor.index, in: anchor.assets) }
        }
    }
}

private struct ThumbnailCompletion: Sendable {
    var failure: String?
    var cancelled = false
}
