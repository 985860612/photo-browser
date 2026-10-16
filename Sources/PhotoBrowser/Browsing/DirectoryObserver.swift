import Foundation
import Darwin
import BrowserCore

@MainActor final class DirectoryObserver {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fileSources: [DispatchSourceFileSystemObject] = []
    private var timer: DispatchSourceTimer?
    private var identity = UUID()
    private let queue = DispatchQueue(label: "PhotoBrowser.directoryObservation", qos: .utility)
    private let changed: (Bool) -> Void
    private let failure: (Error) -> Void
    private var fileWatchTask: Task<Void, Never>?
    private var fileWatchID = UUID()
    private static let workers = PreviewWorkQueue()
    init(directory: URL, pollInterval: TimeInterval = 3,
         changed: @escaping (Bool) -> Void, failure: @escaping (Error) -> Void) async throws {
        self.changed = changed; self.failure = failure
        let descriptor = try await Self.workers.run(background: true) { _ in try WatchedDescriptor(directory) }
        sources = [source(descriptor)]
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.timer != nil else { return }
                self.changed(false)
            }
        }
        self.timer = timer; timer.resume()
    }
    private func source(_ descriptor: WatchedDescriptor) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor.fd, eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: queue)
        let ticket = identity
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in guard let self, self.identity == ticket else { return }; self.changed(true) }
        }
        source.setCancelHandler { descriptor.close() }; source.resume()
        return source
    }
    func watchFiles(_ files: [PhotoFile]) {
        fileSources.forEach { $0.cancel() }; fileSources.removeAll()
        fileWatchTask?.cancel(); fileWatchID = UUID()
        let ticket = fileWatchID, generation = identity
        fileWatchTask = Task { [weak self] in
            do {
                for file in files {
                    let descriptor = try await Self.workers.run(background: true) { _ in try WatchedDescriptor(file.url) }
                    guard let self, self.identity == generation, self.fileWatchID == ticket, !Task.isCancelled else { return }
                    self.fileSources.append(self.source(descriptor))
                }
            } catch is CancellationError {}
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
                if self?.fileWatchID == ticket, self?.identity == generation { self?.changed(true) }
            }
            catch { if self?.fileWatchID == ticket, self?.identity == generation { self?.stop(); self?.failure(error) } }
        }
    }
    func stop() {
        identity = UUID(); sources.forEach { $0.cancel() }; sources.removeAll()
        fileWatchID = UUID(); fileWatchTask?.cancel(); fileWatchTask = nil
        fileSources.forEach { $0.cancel() }; fileSources.removeAll()
        timer?.cancel(); timer = nil
    }
    deinit { sources.forEach { $0.cancel() }; fileSources.forEach { $0.cancel() }; timer?.cancel(); fileWatchTask?.cancel() }
}

/// Ownership survives cancellation while opening a slow network path off the UI thread.
private final class WatchedDescriptor: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false
    init(_ url: URL) throws {
        fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path]) }
    }
    func close() { lock.lock(); defer { lock.unlock() }; if !closed { closed = true; Darwin.close(fd) } }
    deinit { close() }
}

struct DirectorySnapshot {
    let assets: [PhotoAsset]
    let folders: [URL]
    let diskImages: [URL]
    let isReadOnly: Bool
    let dates: [String: Date]
    static func read(_ directory: URL) throws -> DirectorySnapshot {
        let assets = try DirectoryScanner.scan(directory)
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
        let folders = try entries.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map(\.standardizedFileURL)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let images = try entries.filter {
            guard DiskImageService.supports($0) else { return false }
            let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.map(\.standardizedFileURL).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var dates: [String: Date] = [:]
        for url in [directory] + folders { dates[url.path] = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast }
        let readOnly = try directory.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == true
        return DirectorySnapshot(assets: assets, folders: folders, diskImages: images, isReadOnly: readOnly, dates: dates)
    }
}
