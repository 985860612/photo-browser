import AVFoundation
import BrowserCore
import SwiftUI

@MainActor final class VideoPlayback: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var fileID: String?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published private(set) var isPlaying = false
    private var file: PhotoFile?
    private var asset: AVURLAsset?
    private var ticket = UUID()
    private var autoplayID: String?
    private var statusObserver: NSKeyValueObservation?
    private var playbackObserver: NSKeyValueObservation?
    private var endedObserver: NSObjectProtocol?

    func stop() {
        ticket = UUID(); asset?.cancelLoading(); asset = nil
        player.pause(); statusObserver = nil; playbackObserver = nil
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }
        endedObserver = nil; player.replaceCurrentItem(with: nil)
        file = nil; fileID = nil; loading = false; failure = nil; isPlaying = false; autoplayID = nil
    }
    func pause() { autoplayID = nil; player.pause(); isPlaying = false }
    func playWhenReady(_ file: PhotoFile) {
        autoplayID = file.id
        if fileID == file.id { player.play() }
    }
    func toggle() {
        guard fileID != nil, failure == nil else { return }
        if player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate { pause(); return }
        autoplayID = fileID
        if let item = player.currentItem {
            let duration = CMTimeGetSeconds(item.duration), current = CMTimeGetSeconds(player.currentTime())
            if duration.isFinite && duration > 0 && current >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
        }
    }
    func load(_ file: PhotoFile) async {
        guard self.file != file else { return }
        let autoplay = autoplayID == file.id
        stop(); self.file = file; fileID = file.id; loading = true
        autoplayID = autoplay ? file.id : nil
        let request = ticket, asset = AVURLAsset(url: file.url)
        self.asset = asset
        do {
            guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                throw BrowserFailure.message(L10n.text("系统无法播放此视频：\(file.url.lastPathComponent)"))
            }
            try Task.checkCancellation()
            guard request == ticket else { return }
            let item = AVPlayerItem(asset: asset)
            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, let item, self.ticket == request else { return }
                    self.loading = item.status == .unknown
                    if item.status == .failed { self.failure = item.error?.localizedDescription ?? L10n.text("视频播放失败") }
                    if item.status == .readyToPlay, self.autoplayID == file.id { self.player.play() }
                }
            }
            playbackObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.ticket == request else { return }
                    self.isPlaying = self.player.timeControlStatus != .paused
                }
            }
            endedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.ticket == request { self?.pause() } }
            }
            player.replaceCurrentItem(with: item)
            if autoplayID == file.id { player.play() }
        } catch is CancellationError { if request == ticket { stop() } }
        catch { if request == ticket { loading = false; failure = error.localizedDescription } }
    }
}
