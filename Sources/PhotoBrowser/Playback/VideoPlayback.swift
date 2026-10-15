import AVFoundation
import BrowserCore
import SwiftUI

@MainActor final class VideoPlayback: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var fileID: String?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published private(set) var isPlaying = false
    var livePhotoEnded: ((String) -> Void)?
    private var file: PhotoFile?
    private var asset: AVURLAsset?
    private var ticket = UUID()
    private var autoplayID: String?
    private var statusObserver: NSKeyValueObservation?
    private var playbackObserver: NSKeyValueObservation?
    private var endedObserver: NSObjectProtocol?
    private let memory: VideoMemory
    private var volumeObserver: NSKeyValueObservation?
    private var muteObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var restoring = false
    private var restoreStarted = false
    private var prepared: [PhotoFile: AVURLAsset] = [:]
    private var preparation: Task<Void, Never>?
    private var preparationID = UUID()
    private var preparingAsset: AVURLAsset?
    private var livePhotoMovie: LivePhotoMovie?
    private let livePhotoWorkers = PreviewWorkQueue()

    init(defaults: UserDefaults = .standard) {
        memory = VideoMemory(defaults: defaults)
        player.volume = memory.volume; player.isMuted = memory.muted
        volumeObserver = player.observe(\.volume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in guard let self else { return }; self.memory.volume = self.player.volume }
        }
        muteObserver = player.observe(\.isMuted, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in guard let self else { return }; self.memory.muted = self.player.isMuted }
        }
    }
    private func savePosition() {
        guard let file, !loading, !restoring, player.currentItem?.status == .readyToPlay else { return }
        let seconds = CMTimeGetSeconds(player.currentTime()), duration = CMTimeGetSeconds(player.currentItem!.duration)
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return }
        memory.save(file, seconds: seconds >= duration - 0.15 ? 0 : max(0, seconds))
    }
    func prepareNeighbors(_ files: [PhotoFile]) {
        let desired = Array(files.filter { $0.kind == .video }.prefix(8))
        let retained = Set(desired)
        prepared = prepared.filter { retained.contains($0.key) }
        preparationID = UUID(); preparation?.cancel(); preparingAsset?.cancelLoading()
        let request = preparationID
        preparation = Task { [weak self] in
            for file in desired {
                guard let self, request == self.preparationID, !Task.isCancelled else { return }
                if self.prepared[file] != nil { continue }
                let asset = AVURLAsset(url: file.url); self.preparingAsset = asset
                do {
                    guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { continue }
                    _ = try await asset.load(.duration)
                    guard request == self.preparationID, !Task.isCancelled else { return }
                    self.prepared[file] = asset
                } catch { /* A bad neighboring video does not affect the current player. */ }
                if request == self.preparationID { self.preparingAsset = nil }
            }
        }
    }
    var preparedCount: Int { prepared.count }
    func cancelPreparation() {
        preparationID = UUID(); preparation?.cancel(); preparation = nil
        preparingAsset?.cancelLoading(); preparingAsset = nil; prepared.removeAll()
    }

    func stop() {
        savePosition(); memory.volume = player.volume; memory.muted = player.isMuted
        if let timeObserver { player.removeTimeObserver(timeObserver) }; timeObserver = nil
        ticket = UUID(); asset?.cancelLoading(); asset = nil
        player.pause(); statusObserver = nil; playbackObserver = nil
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }
        endedObserver = nil; player.replaceCurrentItem(with: nil)
        livePhotoMovie = nil
        file = nil; fileID = nil; loading = false; failure = nil; isPlaying = false; autoplayID = nil
        restoring = false; restoreStarted = false
    }
    func pause() { autoplayID = nil; player.pause(); isPlaying = false; savePosition() }
    func playWhenReady(_ file: PhotoFile) {
        autoplayID = file.id
        if fileID == file.id, !loading, !restoring { player.play() }
    }
    func toggle() {
        guard fileID != nil, failure == nil else { return }
        if player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate || (loading && autoplayID == fileID) { pause(); return }
        autoplayID = fileID
        if let item = player.currentItem {
            let duration = CMTimeGetSeconds(item.duration), current = CMTimeGetSeconds(player.currentTime())
            if duration.isFinite && duration > 0 && current >= duration - 0.05 { player.seek(to: .zero) }
            if !loading, !restoring { player.play() }
        }
    }
    func load(_ file: PhotoFile) async {
        guard !Task.isCancelled else { return }
        // A replacement view must take over a cancelled preflight, while an installed item is shared.
        guard self.file != file || (loading && player.currentItem == nil) else { return }
        let autoplay = autoplayID == file.id
        stop(); self.file = file; fileID = file.id; loading = true
        autoplayID = autoplay ? file.id : nil
        let request = ticket
        do {
            let url: URL
            if file.isLivePhoto {
                let movie = try await livePhotoWorkers.run { check in try LivePhotoCache.shared.movie(file, check: check) }
                try Task.checkCancellation()
                guard request == ticket else { return }
                livePhotoMovie = movie; url = movie.url
            } else { url = file.url }
            let asset = prepared.removeValue(forKey: file) ?? AVURLAsset(url: url)
            self.asset = asset
            guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                throw BrowserFailure.message(L10n.text("系统无法播放此视频：\(file.url.lastPathComponent)"))
            }
            try Task.checkCancellation()
            guard request == ticket else { return }
            let item = AVPlayerItem(asset: asset)
            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, let item, self.ticket == request else { return }
                    if item.status == .failed { self.loading = false; self.failure = item.error?.localizedDescription ?? L10n.text("视频播放失败") }
                    if item.status == .readyToPlay, !self.restoreStarted {
                        self.restoreStarted = true; self.restoring = true
                        let duration = CMTimeGetSeconds(item.duration), saved = self.memory.position(file)
                        let seconds = duration.isFinite && saved < duration - 0.15 ? max(0, saved) : 0
                        if seconds > 0 { await self.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
                        guard self.ticket == request else { return }
                        self.restoring = false; self.loading = false
                        if self.autoplayID == file.id { self.player.play() }
                    }
                }
            }
            playbackObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.ticket == request else { return }
                    self.isPlaying = self.player.timeControlStatus != .paused
                }
            }
            endedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.ticket == request else { return }
                    self.pause()
                    if file.isLivePhoto { self.stop(); self.livePhotoEnded?(file.id) }
                }
            }
            player.replaceCurrentItem(with: item)
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.ticket == request { self?.savePosition() } }
            }
        } catch is CancellationError { if request == ticket { stop() } }
        catch { if request == ticket { loading = false; failure = error.localizedDescription } }
    }
}
