import Foundation
import Combine
import BrowserCore
import ImageIO

struct CaptureDates {
    var dates: [String: Date] = [:]
    var fingerprints: [String: String] = [:]
}

/// Owns capture-time backfill and cancellation, without changing library or selection state.
@MainActor final class CaptureDateLoader: ObservableObject {
    @Published private(set) var loading = false
    private var task: Task<Void, Never>?
    private var ticket = UUID()
    private var checked: [String: String] = [:]
    private var scope = ""
    private let thumbnails: ThumbnailCache
    private let workers = PreviewWorkQueue()

    init(thumbnails: ThumbnailCache) { self.thumbnails = thumbnails }

    func cancel(reset: Bool = false) {
        ticket = UUID(); task?.cancel(); task = nil; loading = false
        if reset { checked = [:] }
    }

    func load(_ assets: [PhotoAsset], scope: String, completed: @escaping (CaptureDates) -> Void) {
        if task != nil, self.scope == scope { return }
        cancel(); self.scope = scope
        let snapshot = assets.filter { !$0.isVideo && $0.metadata?.captured == nil && checked[$0.id] != $0.fingerprint }
        guard !snapshot.isEmpty else { return }
        let ticket = ticket, thumbnails = thumbnails, workers = workers
        loading = true
        task = Task { [weak self] in
            var result = CaptureDates()
            for asset in snapshot {
                do {
                    let preview = try await thumbnails.image(asset.preferred, maximum: 520, background: true)
                    if let captured = preview.metadata?.captured { result.dates[asset.id] = captured }
                    else {
                        let file = asset.metadataFile
                        result.dates[asset.id] = try await workers.run(background: true) { check in
                            try check()
                            guard let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                                  let metadata = ImageMetadataReader.read(source) else { return nil }
                            try check(); return metadata.captured
                        }
                    }
                } catch is CancellationError { return }
                catch { /* Missing capture dates use modification time; preview errors remain visible. */ }
                guard !Task.isCancelled, self?.ticket == ticket else { return }
                result.fingerprints[asset.id] = asset.fingerprint
            }
            guard let self, self.ticket == ticket, !Task.isCancelled else { return }
            self.checked.merge(result.fingerprints, uniquingKeysWith: { _, latest in latest })
            self.task = nil; self.loading = false
            completed(result)
        }
    }
}
