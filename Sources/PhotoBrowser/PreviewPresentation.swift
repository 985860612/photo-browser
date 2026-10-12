import AppKit
import SwiftUI
import BrowserCore

/// Both viewers follow the same progressive path and share decoded pixels.
@MainActor final class PreviewPresentation: ObservableObject {
    @Published private(set) var photo: DisplayPhoto?
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var fileID: String?
    @Published private(set) var loading = false
    @Published var failure: String?
    private var ticket = UUID()
    private let cache: DisplayPhotoCache
    private let thumbnails: ThumbnailCache

    init(cache: DisplayPhotoCache = .shared, thumbnails: ThumbnailCache = .shared) {
        self.cache = cache; self.thumbnails = thumbnails
    }

    func load(_ file: PhotoFile?, hdr: Bool, maximum: Int?, metadata: (PhotoMetadata?) -> Void) async {
        let request = UUID(); ticket = request
        failure = nil; loading = file != nil
        guard let file else { photo = nil; thumbnail = nil; fileID = nil; return }
        if let cached = await cache.cached(file, hdr: hdr, maximum: maximum, protect: true) {
            guard ticket == request, !Task.isCancelled else { return }
            photo = cached; thumbnail = nil; fileID = file.id; loading = false; metadata(cached.metadata)
            return
        }
        guard ticket == request, !Task.isCancelled else { return }
        photo = nil; thumbnail = nil; fileID = file.id
        if maximum == nil, let browsing = await cache.cached(file, hdr: hdr, maximum: 2800, protect: true) {
            guard ticket == request, !Task.isCancelled else { return }
            photo = browsing
        }
        // Do not make a cached thumbnail or slow RAW embedded preview block the original.
        let quick = Task { @MainActor in
            do {
                let result = try await thumbnails.image(file, maximum: 520)
                guard !Task.isCancelled, ticket == request, photo == nil else { return }
                thumbnail = result.image
            } catch { /* The original still has its own load/error path. */ }
        }
        defer { quick.cancel() }
        do {
            let result = try await cache.image(file, hdr: hdr, maximum: maximum)
            guard ticket == request, !Task.isCancelled else { return }
            photo = result; thumbnail = nil; loading = false; metadata(result.metadata)
        } catch is CancellationError {}
        catch {
            guard ticket == request, !Task.isCancelled else { return }
            failure = error.localizedDescription; loading = false
        }
    }
}
