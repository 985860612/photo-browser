import AVKit
import SwiftUI
import BrowserCore

struct VideoPreviewView: View {
    let file: PhotoFile
    @ObservedObject var playback: VideoPlayback
    var body: some View {
        ZStack {
            Color.black
            NativeVideoPlayer(player: playback.player)
            if playback.fileID == file.id {
                if let failure = playback.failure {
                    ContentUnavailableView(L10n.text("视频播放失败"), systemImage: "film", description: Text(failure))
                } else if playback.loading { ProgressView(L10n.text("加载视频…")) }
            }
        }.task(id: file) { await playback.load(file) }
    }
}

private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating; view.videoGravity = .resizeAspect; view.player = player
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
