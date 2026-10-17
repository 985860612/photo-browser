import Foundation
import Combine
import BrowserCore

/// Metadata stays independent of image decoding: flipping the switch never reloads the photo.
@MainActor final class FocusPointPresentation: ObservableObject {
    @Published private(set) var metadata: FocusPointMetadata?
    @Published private(set) var file: PhotoFile?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    private var ticket = UUID()
    private let loadMetadata: (PhotoFile) async throws -> FocusPointMetadata

    init(load: @escaping (PhotoFile) async throws -> FocusPointMetadata = { try await FocusPointCache.shared.read($0) }) {
        loadMetadata = load
    }

    func load(_ file: PhotoFile?) async {
        let request = UUID(); ticket = request
        self.file = file; metadata = nil; failure = nil; loading = file != nil
        guard let file else { return }
        do {
            let result = try await loadMetadata(file)
            guard ticket == request else { return }
            if Task.isCancelled { loading = false; return }
            metadata = result; loading = false
        } catch is CancellationError {
            if ticket == request { loading = false }
        } catch {
            guard !Task.isCancelled, ticket == request else { return }
            failure = error.localizedDescription; loading = false
        }
    }

    func regions(for file: PhotoFile?, enabled: Bool) -> [FocusRegion] {
        guard enabled, let file, self.file == file else { return [] }
        return metadata?.regions ?? []
    }
}

actor FocusPointCache {
    static let shared = FocusPointCache()
    private let workers = PreviewWorkQueue()
    private var entries: [PhotoFile: FocusPointMetadata] = [:]
    private var order: [PhotoFile] = []

    func read(_ file: PhotoFile) async throws -> FocusPointMetadata {
        try Task.checkCancellation()
        if let cached = entries[file] { touch(file); return cached }
        let reader = FocusPointReader()
        let result = try await withTaskCancellationHandler {
            try await workers.run(background: true) { check in
                try check(); return try reader.read(file)
            }
        } onCancel: { reader.cancel() }
        try Task.checkCancellation()
        entries[file] = result; touch(file)
        while order.count > 96 { entries.removeValue(forKey: order.removeFirst()) }
        return result
    }

    private func touch(_ file: PhotoFile) { order.removeAll { $0 == file }; order.append(file) }
}
