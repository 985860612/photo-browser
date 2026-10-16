import Foundation
import ImageIO
import BrowserCore

extension ThumbnailChecks {
    static func coordinateSystemChecks() async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw BrowserFailure.message(message) }
            print("PASS " + message)
        }
        for (marker, expected) in [(" WGS-84 ", PhotoCoordinateSystem.wgs84), ("wgs_1984", .wgs84), ("EPSG:4326", .wgs84),
                                   ("gcj-02", .gcj02), ("BD09", .bd09), ("BD-09-LL", .bd09)] {
            try require(PhotoCoordinateSystem(mapDatum: marker) == expected, "explicit datum marker recognized: \(marker)")
        }
        for marker: String? in [nil, "", "ASCII", "NAD83", "WGS84-like", "BD09MC"] {
            try require(PhotoCoordinateSystem(mapDatum: marker) == nil, "missing or unsupported datum is not guessed")
        }
        let suite = "CoordinateSystemChecks-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LocationPreferences(defaults: defaults)
        try require(preferences.preferredCoordinateSystem == .wgs84, "unconfigured coordinate preference defaults to WGS-84")
        for system in PhotoCoordinateSystem.allCases {
            preferences.preferredCoordinateSystem = system
            try require(LocationPreferences(defaults: defaults).preferredCoordinateSystem == system, "coordinate preference persists as a stable code: \(system.rawValue)")
        }
        defaults.set("unsupported", forKey: "preferredCoordinateSystem")
        try require(preferences.preferredCoordinateSystem == .wgs84, "obsolete coordinate preference uses the documented default")
        let wgs = PhotoLocation(latitude: 39.98843055555556, longitude: 116.33218333333333, altitude: 123)!
        let gcj = PhotoCoordinateSystem.wgs84.converting(wgs, to: .gcj02)!
        try require(abs(gcj.latitude - 39.989753186374145) < 1e-8 && abs(gcj.longitude - 116.338336968907) < 1e-8,
                    "reported photo matches the reference mainland-map coordinate")
        let bd = PhotoCoordinateSystem.gcj02.converting(gcj, to: .bd09)!
        for (source, point) in [(PhotoCoordinateSystem.wgs84, wgs), (.gcj02, gcj), (.bd09, bd)] {
            let restored = source.converting(point, to: .wgs84)!
            try require(abs(restored.latitude - wgs.latitude) < 0.000001 && abs(restored.longitude - wgs.longitude) < 0.000001 && restored.altitude == 123,
                        "\(source.label) normalizes to WGS-84 within one microdegree and preserves altitude")
            try require(source.converting(point, to: source) == point, "same-system coordinates remain exactly unchanged")
        }
        // Published reference: https://github.com/wandergis/coordtransform#exampleusage
        let bdReference = PhotoLocation(latitude: 39.915, longitude: 116.404)!
        let gcjReference = PhotoCoordinateSystem.bd09.converting(bdReference, to: .gcj02)!
        try require(abs(gcjReference.latitude - 39.90865673957631) < 0.000001 && abs(gcjReference.longitude - 116.39762729119315) < 0.000001,
                    "BD-09 reference decodes to the GCJ-02 reference")

        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(suite)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let image = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        for (index, marker) in ["WGS-84", "GCJ-02", "BD-09", "NAD83", nil].enumerated() {
            let name = "datum-\(index)", url = root.appendingPathComponent(name + ".jpg")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
            var gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: wgs.latitude, kCGImagePropertyGPSLatitudeRef: "N",
                                      kCGImagePropertyGPSLongitude: wgs.longitude, kCGImagePropertyGPSLongitudeRef: "E"]
            if let marker { gps[kCGImagePropertyGPSMapDatum] = marker }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
            try require(CGImageDestinationFinalize(destination), "datum fixture created")
            let original = try Data(contentsOf: url), values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let file = PhotoFile(url: url, kind: .rendered, size: Int64(values.fileSize!), modified: values.contentModificationDate!)
            let cacheDirectory = root.appendingPathComponent("cache-\(index)"), cache = ThumbnailCache(directory: cacheDirectory)
            let preview = try await cache.image(file, maximum: 520)
            let native = preview.metadata!
            try require(native.gpsMapDatum == marker && native.gpsMapDatumRead == true, "native reader preserves explicit and missing datum tags")
            let expected = PhotoCoordinateSystem(mapDatum: marker)
            for preferred in PhotoCoordinateSystem.allCases {
                try require(native.coordinateSystem(preferred: preferred) == (expected ?? preferred), "photo marker wins; only unrecognized metadata uses the preference")
            }
            if MetadataReader.executable != nil {
                let exif = try MetadataReader().read(directory: root, assets: [PhotoAsset(id: name, name: name, files: [file])])[name]!
                try require(exif.gpsMapDatum == marker && exif.gpsMapDatumRead == true && exif.detectedCoordinateSystem == expected,
                            "ExifTool and ImageIO agree on datum identification")
            }
            // Simulate a v2 source-header cache with GPS already present, but no datum schema.
            var old = native; old.gpsMapDatum = nil; old.gpsMapDatumRead = nil
            let key = ThumbnailCache.digest("metadata-v1|\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)")
            let metadataObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old))
            try JSONSerialization.data(withJSONObject: ["version": 2, "metadata": metadataObject])
                .write(to: cacheDirectory.appendingPathComponent(key + ".json"))
            let upgraded = try await ThumbnailCache(directory: cacheDirectory).sourceMetadata(file)
            try require(upgraded?.gpsMapDatum == marker && upgraded?.gpsMapDatumRead == true, "v2 GPS cache backfills datum once without changing raw coordinates")
            try require(try Data(contentsOf: url) == original, "automatic datum detection never changes the original photo")
            try fm.removeItem(at: url)
            let offline = try await ThumbnailCache(directory: cacheDirectory).sourceMetadata(file)
            try require(offline?.gpsMapDatum == marker && offline?.gpsMapDatumRead == true, "known or missing datum remains available with the original offline")
            let restored = try JSONDecoder().decode(PhotoMetadata.self, from: JSONEncoder().encode(upgraded))
            try require(restored.gpsMapDatum == marker && restored.gpsMapDatumRead == true, "datum provenance survives metadata persistence")
        }
    }
}
