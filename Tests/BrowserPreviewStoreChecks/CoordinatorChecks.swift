import AppKit
import Combine
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func coordinatorChecks() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CoordinatorChecks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "CoordinatorChecks-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("support"),
                                 thumbnails: ThumbnailCache(directory: root.appendingPathComponent("cache")),
                                 defaults: defaults, monitoringEnabled: false)
        defer { store.cancelPreviewGeneration() }
        let file = PhotoFile(url: root.appendingPathComponent("missing.jpg"), kind: .rendered)
        let asset = PhotoAsset(id: "a", name: "a", files: [file])
        let group = PhotoGroup(id: "g", name: "manual", assetIDs: [asset.id])
        store.assets = [asset]; store.groups = [group]; store.selection = [asset.id]; store.focusedID = asset.id
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        let before = changes
        store.previewCoordinator.start(files: [file], priority: [])
        try expect(changes > before && store.isGeneratingPreviews && store.previewTotal == 1,
                   "coordinator-owned progress forwards updates to the existing browser observer")
        try await until { !store.isGeneratingPreviews }
        try expect(store.previewCompleted == 1 && store.previewFailures == 1,
                   "browser reads completion and errors directly from the coordinator")
        try expect(store.groups[0].id == group.id && store.selection == [asset.id] && store.focusedID == asset.id,
                   "preview coordination leaves group, focus and selection ownership with the browser")
        store.previewCoordinator.cancel()
        try expect(store.previewTotal == 0 && store.previewFailures == 0 && store.adjacentTotal == 0,
                   "cancelling the coordinator clears progress without duplicate store state")
        var completed = false
        store.captureDates.load([asset], scope: "first") { _ in completed = true }
        try expect(store.isReadingSortDates, "capture-time loader exposes its own task state")
        store.captureDates.cancel(reset: true)
        try await Task.sleep(for: .milliseconds(30))
        try expect(!completed && !store.isReadingSortDates && store.assets[0].metadata == nil,
                   "cancelled capture-time work never applies obsolete metadata to the browser")
    }
}
