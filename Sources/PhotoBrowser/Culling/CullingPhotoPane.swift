import AppKit
import SwiftUI
import BrowserCore
import CullingCore

struct CullingPhotoPane: View {
    @EnvironmentObject private var store: BrowserStore
    let asset: PhotoAsset
    let file: PhotoFile
    let title: String
    let analysis: PhotoAnalysis?
    @Binding var sharedZoom: Double
    @Binding var sharedPan: CGPoint
    let sync: Bool
    let pixelRequest: Int
    let subjectRequest: Int
    let fitRequest: Int
    @StateObject private var preview = PreviewPresentation()
    @State private var localZoom = 1.0
    @State private var localPan = CGPoint.zero
    @State private var fitScale = 1.0
    @State private var native = false
    @State private var pixels = false
    private var zoom: Binding<Double> { sync ? $sharedZoom : $localZoom }
    private var pan: Binding<CGPoint> { sync ? $sharedPan : $localPan }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Text(asset.name).lineLimit(1)
                Spacer(minLength: 4)
                CullingMarkBadge(mark: store.culling.mark(for: asset))
            }.font(.caption).padding(9)
            ZStack {
                Color.black
                PhotoCanvas(photo: preview.fileID == file.id ? preview.photo : nil, identity: file.id,
                            hdr: store.hdrPreview, zoom: zoom, fitScale: $fitScale, normalizedPan: pan) { preview.failure = $0 }
                if preview.photo == nil, let thumbnail = preview.thumbnail, preview.fileID == file.id {
                    Image(nsImage: thumbnail).resizable().scaledToFit().allowsHitTesting(false)
                }
                if preview.loading { ProgressView().controlSize(.small).allowsHitTesting(false) }
                if let failure = preview.failure {
                    VStack { Spacer(); Text(failure).font(.caption).padding(10).background(.black.opacity(0.8)) }
                }
            }.clipped()
        }
        .task(id: "\(file.id)|\(file.modified)|\(file.size)|\(store.hdrPreview)|\(native)") {
            await preview.load(file, hdr: store.hdrPreview, maximum: native ? nil : 2800) { _ in }
            if pixels { setPixels() }
        }
        .onChange(of: pixelRequest) { _, _ in pixels = true; native = true; if preview.photo != nil { setPixels() } }
        .onChange(of: fitScale) { _, _ in if pixels && !preview.loading { setPixels() } }
        .onChange(of: sharedZoom) { _, value in if abs(value - 1) < 0.0001 { pixels = false } }
        .onChange(of: sync) { _, value in
            if !value { localZoom = sharedZoom; localPan = sharedPan }
        }
        .onChange(of: fitRequest) { _, _ in pixels = false; zoom.wrappedValue = 1; pan.wrappedValue = .zero }
        .onChange(of: subjectRequest) { _, _ in
            pixels = false
            if let region = analysis?.faces.first ?? analysis?.subjects.first {
                zoom.wrappedValue = min(10, max(1, 0.65 / max(region.width, region.height, 0.01)))
                pan.wrappedValue = CGPoint(x: 0.5 - region.x - region.width / 2, y: 0.5 - region.y - region.height / 2)
            }
        }
    }
    private func setPixels() {
        zoom.wrappedValue = min(10, max(0.1, 1 / (fitScale * (NSApp.keyWindow?.backingScaleFactor ?? 2))))
        pan.wrappedValue = .zero
    }
}
