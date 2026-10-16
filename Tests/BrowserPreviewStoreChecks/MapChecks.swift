import AppKit
import MapKit
import ImageIO
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func mapChecks() async throws {
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
        let item = try PhotoMapLauncher.item(location: location, name: store.focusedAsset!.name)
        let latitude: Double, longitude: Double
        #if compiler(>=6.2)
        if #available(macOS 26, *) { latitude = item.location.coordinate.latitude; longitude = item.location.coordinate.longitude }
        else { latitude = item.placemark.coordinate.latitude; longitude = item.placemark.coordinate.longitude }
        #else
        latitude = item.placemark.coordinate.latitude; longitude = item.placemark.coordinate.longitude
        #endif
        try expect(latitude == location.latitude && longitude == location.longitude && item.name == "照片 %s %@ 🌅",
                   "Apple Maps target preserves hemisphere signs and Unicode photo names without opening Maps during tests")
        let beijing = PhotoLocation(latitude: 39.98843055555556, longitude: 116.33218333333333)!
        let chinaItem = try await PhotoMapLauncher.resolvedItem(location: beijing, name: "IMG_20140528_183250", mapRegion: "CN") { input in
            try expect(input.coordinate.latitude == beijing.latitude && input.coordinate.longitude == beijing.longitude,
                       "country lookup receives original WGS-84 coordinates")
            return "CN"
        }
        let chinaPoint = mapPoint(chinaItem)
        try expect(abs(chinaPoint.latitude - 39.989753186374145) < 0.000001
                   && abs(chinaPoint.longitude - 116.338336968907) < 0.000001,
                   "reported Beijing photo opens about 525 m east and 147 m north on mainland Maps")
        try expect(beijing.latitude == 39.98843055555556 && beijing.longitude == 116.33218333333333,
                   "map conversion leaves original GPS unchanged")
        let repeated = try PhotoMapLauncher.item(location: beijing, name: "repeat", mainlandChinaMap: true)
        try expect(mapPoint(repeated).latitude == chinaPoint.latitude && mapPoint(repeated).longitude == chinaPoint.longitude,
                   "repeated map launches never accumulate GCJ-02 offsets")
        let tiananmen = PhotoLocation(latitude: 39.915, longitude: 116.404)!
        let reference = mapPoint(try PhotoMapLauncher.item(location: tiananmen, name: "reference", mainlandChinaMap: true))
        try expect(abs(reference.latitude - 39.916404282) < 0.000001 && abs(reference.longitude - 116.410244499) < 0.000001,
                   "second Beijing reference agrees with WGS-84 to GCJ-02 conversion")
        for (country, lat, lon) in [("HK", 22.3193, 114.1694), ("MO", 22.1987, 113.5439), ("TW", 25.033, 121.5654),
                                    ("KR", 37.5665, 126.978), ("JP", 35.6762, 139.6503), ("VN", 21.0285, 105.8542)] {
            let original = PhotoLocation(latitude: lat, longitude: lon)!
            let target = try await PhotoMapLauncher.resolvedItem(location: original, name: country, mapRegion: "CN") { _ in country }
            try expect(mapPoint(target).latitude == lat && mapPoint(target).longitude == lon,
                       "\(country) photo retains WGS-84 even with mainland system region")
        }
        for (original, region) in [(beijing, "US"), (beijing, ""), (location, "CN")] {
            let target = try await PhotoMapLauncher.resolvedItem(location: original, name: "unchanged", mapRegion: region) { _ in
                throw BrowserFailure.message("Unexpected country lookup")
            }
            try expect(mapPoint(target).latitude == original.latitude && mapPoint(target).longitude == original.longitude,
                       "international Maps or distant coordinates keep raw GPS without network lookup")
        }
        let lookupFailure = NSError(domain: "MapLookupTest", code: 1)
        do {
            _ = try await PhotoMapLauncher.resolvedItem(location: beijing, name: "failure", mapRegion: "CN") { _ in throw lookupFailure }
            throw BrowserFailure.message("Country lookup failure was swallowed")
        } catch { try expect((error as NSError) == lookupFailure, "lookup failure is reported instead of guessing a map position") }
        do {
            _ = try await PhotoMapLauncher.resolvedItem(location: beijing, name: "unknown", mapRegion: "CN") { _ in nil }
            throw BrowserFailure.message("Missing country was treated as mainland")
        } catch { try expect((error as NSError).domain == kCLErrorDomain, "unknown country does not silently launch an unverified position") }
        for system in PhotoCoordinateSystem.allCases {
            let encoded = PhotoCoordinateSystem.wgs84.converting(beijing, to: system)!
            let domestic = try await PhotoMapLauncher.resolvedItem(location: encoded, name: system.label, sourceSystem: system, mapRegion: "CN") { input in
                try expect(abs(input.coordinate.latitude - beijing.latitude) < 0.000001
                           && abs(input.coordinate.longitude - beijing.longitude) < 0.000001,
                           "\(system.label) uses normalized GPS for the country lookup")
                return "CN"
            }
            try expect(abs(mapPoint(domestic).latitude - chinaPoint.latitude) < 0.000001
                       && abs(mapPoint(domestic).longitude - chinaPoint.longitude) < 0.000001,
                       "\(system.label) reaches the same mainland target without double conversion")
            let international = try await PhotoMapLauncher.resolvedItem(location: encoded, name: system.label, sourceSystem: system, mapRegion: "US") { _ in
                throw BrowserFailure.message("Unexpected country lookup")
            }
            try expect(abs(mapPoint(international).latitude - beijing.latitude) < 0.000001
                       && abs(mapPoint(international).longitude - beijing.longitude) < 0.000001,
                       "\(system.label) reaches WGS-84 Maps without mainland mode")
        }
        try expect(store.preferredCoordinateSystem == .wgs84, "store starts with the documented coordinate preference")
        store.preferredCoordinateSystem = .bd09
        let preferenceStore = BrowserStore(supportDirectory: root, defaults: defaults, monitoringEnabled: false)
        defer { preferenceStore.cancelPreviewGeneration() }
        try expect(preferenceStore.preferredCoordinateSystem == .bd09, "coordinate-system setting survives store recreation")
        incoming.gpsMapDatum = "GCJ-02"; incoming.gpsMapDatumRead = true
        store.updateMetadata("a", value: incoming)
        try expect(store.focusedAsset?.metadata?.detectedCoordinateSystem == .gcj02
                   && store.focusedAsset?.metadata?.coordinateSystem(preferred: store.preferredCoordinateSystem) == .gcj02,
                   "legacy metadata accepts a matching datum and photo identification outranks the setting")
        let prepared = try await store.locationForMap(store.focusedAsset!)
        try expect(prepared.0 == location && prepared.1 == .gcj02, "map launch uses the photo marker and raw coordinates")
        incoming.gpsLatitude = 50; incoming.gpsLongitude = 100; incoming.gpsAltitude = 900
        incoming.gpsMapDatum = "WGS-84"
        store.updateMetadata("a", value: incoming)
        try expect(store.focusedAsset?.metadata?.detectedCoordinateSystem == .gcj02, "metadata from a different GPS point cannot change its coordinate system")
        try expect(store.focusedAsset?.metadata?.location == location, "later preview metadata cannot overwrite an existing GPS location or mix altitudes from another point")
        store.directory = root
        try store.saveSession()
        let restored = try store.sessions.restore([PhotoAsset(id: "a", name: "photo", files: [file])], in: root)
        try expect(restored.assets.first?.metadata?.location == location
                   && restored.assets.first?.metadata?.detectedCoordinateSystem == .gcj02,
                   "raw GPS and identified coordinate system survive the existing browser session format")
        let fixtureImage = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for marker: String? in ["GCJ-02", nil] {
            let photoURL = root.appendingPathComponent(UUID().uuidString + ".jpg")
            let destination = CGImageDestinationCreateWithURL(photoURL as CFURL, "public.jpeg" as CFString, 1, nil)!
            var gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 39.9, kCGImagePropertyGPSLatitudeRef: "N",
                                      kCGImagePropertyGPSLongitude: 116.3, kCGImagePropertyGPSLongitudeRef: "E"]
            if let marker { gps[kCGImagePropertyGPSMapDatum] = marker }
            CGImageDestinationAddImage(destination, fixtureImage, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
            try expect(CGImageDestinationFinalize(destination), "map metadata fixture created")
            let sourceFile = PhotoFile(url: photoURL, kind: .rendered)
            var old = PhotoMetadata(); old.gpsLatitude = 39.9; old.gpsLongitude = 116.3
            store.assets = [PhotoAsset(id: "legacy", name: "legacy", files: [sourceFile], metadata: old)]
            store.focusedID = "legacy"
            let mapInput = try await store.locationForMap(store.focusedAsset!)
            try expect(mapInput.1 == (marker == nil ? .bd09 : .gcj02),
                       "map launch reads the original datum before applying the preferred fallback")
            try expect(store.focusedAsset?.metadata?.gpsMapDatumRead == true && store.focusedAsset?.metadata?.gpsMapDatum == marker,
                       "opening Maps enriches legacy metadata even before the inspector finishes")
            if marker == nil {
                store.preferredCoordinateSystem = .wgs84
                let updated = try await store.locationForMap(store.focusedAsset!)
                try expect(updated.1 == .wgs84, "changing the fallback immediately affects an already-open untagged photo")
            }
        }
        store.assets[0].metadata?.gpsLatitude = 95
        store.openFocusedLocation()
        try expect(store.errorMessage == L10n.text("此照片没有有效的 GPS 坐标。"), "invalid GPS reports an error before launching a map")
    }

    private static func mapPoint(_ item: MKMapItem) -> CLLocationCoordinate2D {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return item.location.coordinate }
        else { return item.placemark.coordinate }
        #else
        return item.placemark.coordinate
        #endif
    }
}
