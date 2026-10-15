import AppKit
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func mapChecks() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("MapChecks-" + UUID().uuidString)
        let suite = "MapChecks-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let store = BrowserStore(supportDirectory: root, defaults: defaults, monitoringEnabled: false)
        defer { store.cancelPreviewGeneration() }
        let file = PhotoFile(url: root.appendingPathComponent("photo.jpg"), kind: .rendered)
        let captured = Date(timeIntervalSince1970: 100)
        store.assets = [PhotoAsset(id: "a", name: "照片 %s %@ 🌅", files: [file], metadata: PhotoMetadata(captured: captured, sequence: 7))]
        store.focusedID = "a"
        var incoming = PhotoMetadata(captured: Date(timeIntervalSince1970: 200), sequence: 99)
        incoming.gpsLatitude = -12.25; incoming.gpsLongitude = -34.5; incoming.gpsAltitude = -23.5
        store.updateMetadata("a", value: incoming)
        try expect(store.focusedAsset?.metadata?.location == incoming.location && store.focusedAsset?.metadata?.captured == captured && store.focusedAsset?.metadata?.sequence == 7,
                   "GPS enrichment preserves the original capture time and sequence")
        let location = store.focusedAsset!.metadata!.location!
        let item = PhotoMapLauncher.item(location: location, name: store.focusedAsset!.name)
        let latitude: Double, longitude: Double
        #if compiler(>=6.2)
        if #available(macOS 26, *) { latitude = item.location.coordinate.latitude; longitude = item.location.coordinate.longitude }
        else { latitude = item.placemark.coordinate.latitude; longitude = item.placemark.coordinate.longitude }
        #else
        latitude = item.placemark.coordinate.latitude; longitude = item.placemark.coordinate.longitude
        #endif
        try expect(latitude == location.latitude && longitude == location.longitude && item.name == "照片 %s %@ 🌅",
                   "Apple Maps target preserves hemisphere signs and Unicode photo names without opening Maps during tests")
        incoming.gpsLatitude = 50; incoming.gpsLongitude = 100; incoming.gpsAltitude = 900
        store.updateMetadata("a", value: incoming)
        try expect(store.focusedAsset?.metadata?.location == location, "later preview metadata cannot overwrite an existing GPS location or mix altitudes from another point")
        store.directory = root
        try store.saveSession()
        let restored = try store.sessions.restore([PhotoAsset(id: "a", name: "photo", files: [file])], in: root)
        try expect(restored.assets.first?.metadata?.location == location, "GPS survives the existing browser session format")
        store.assets[0].metadata?.gpsLatitude = 95
        store.openFocusedLocation()
        try expect(store.errorMessage == L10n.text("此照片没有有效的 GPS 坐标。"), "invalid GPS reports an error before launching a map")
    }
}
