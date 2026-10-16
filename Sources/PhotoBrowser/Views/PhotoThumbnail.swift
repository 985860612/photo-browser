import AppKit
import SwiftUI
import BrowserCore

struct PhotoThumbnail: View {
    @EnvironmentObject private var store: BrowserStore
    let asset: PhotoAsset
    let selected: Bool
    let focused: Bool
    let height: Double
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var hovered = false
    @State private var duration: Double?

    var body: some View {
        VStack(spacing: 7) {
            Color.clear.frame(height: height).overlay {
                if let image { Image(nsImage: image).resizable().scaledToFit().padding(5) }
                else if let failure {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(failure)
                } else { ProgressView().controlSize(.small) }
            }
                .overlay(alignment: .bottomTrailing) {
                    if asset.isLivePhoto {
                        Image(systemName: "livephoto").font(.system(size: 12)).padding(4)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(5)
                    } else if asset.isVideo {
                        Label(VideoMedia.durationLabel(duration), systemImage: "play.fill")
                            .font(.system(size: 10, weight: .medium)).padding(4).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(5)
                    }
                }
            Text(asset.name).font(.system(size: 11, weight: focused ? .semibold : .regular)).lineLimit(1)
            Text(asset.formatLabel).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(selected ? 0.09 : (hovered ? 0.045 : 0))))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(focused ? Color.blue.opacity(0.65) : (selected ? Color.white.opacity(0.16) : .clear), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onAppear { store.previewAppeared(asset) }
        .task(id: asset.preferred.id + "\(asset.preferred.modified.timeIntervalSince1970)") {
            do { let result = try await ThumbnailCache.shared.image(asset.preferred, maximum: 520); image = result.image; duration = result.metadata?.duration; failure = nil }
            catch is CancellationError {}
            catch { failure = error.localizedDescription }
        }
    }
}
