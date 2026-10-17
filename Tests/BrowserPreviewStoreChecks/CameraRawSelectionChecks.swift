import AppKit
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func cameraRawSelectionChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraRawSelection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserStore(supportDirectory: root, monitoringEnabled: false)
        func file(_ name: String, _ kind: PhotoKind) -> PhotoFile { PhotoFile(url: root.appendingPathComponent(name), kind: kind) }
        let raw = file("a.NEF", .raw), jpeg = file("a.JPG", .rendered), other = file("b.JPG", .rendered)
        let a = PhotoAsset(id: "a", name: "a", files: [jpeg, raw])
        let b = PhotoAsset(id: "b", name: "b", files: [other])
        let movie = PhotoAsset(id: "movie", name: "movie", files: [file("movie.mov", .video)])
        let live = PhotoAsset(id: "live", name: "live", files: [file("live.livp", .rendered)])
        store.assets = [a, b, movie, live]
        store.selection = [a.id, b.id, movie.id, live.id]
        let sources = store.cameraRawSources(for: a)
        try expect(Set(sources) == Set([raw, other]), "Camera Raw batch uses one format per capture and excludes videos and Live Photos")
        try expect(store.cameraRawSources(for: a, file: jpeg) == [jpeg], "explicit format remains a single-file action during multi-selection")
        store.selection = [b.id]
        try expect(store.cameraRawSources(for: a) == [raw], "right-clicking an unselected photo opens that photo only")
    }
}
