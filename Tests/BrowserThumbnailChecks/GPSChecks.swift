import AppKit
import ImageIO
import BrowserCore

extension ThumbnailChecks {
    static func gpsChecks() async throws {
        func require(_ value: Bool, _ label: String) throws {
            guard value else { throw BrowserFailure.message(label) }; print("PASS " + label)
        }
        try require(PhotoLocation(latitude: 0, longitude: 0) != nil, "equator and prime meridian are valid GPS values")
        for pair in [(Double.nan, 10.0), (10.0, Double.infinity), (90.01, 10.0), (10.0, -180.01)] {
            try require(PhotoLocation(latitude: pair.0, longitude: pair.1) == nil, "invalid coordinates never become map targets")
        }
        try require(PhotoLocation(exifLatitude: 10, latitudeRef: "?", exifLongitude: 20, longitudeRef: "E") == nil,
                    "unknown hemisphere references cannot silently point to a guessed location")
        try require(PhotoLocation(exifLatitude: 10, latitudeRef: "N", exifLongitude: nil, longitudeRef: "E") == nil,
                    "incomplete coordinates do not provide a map target")
        try require(PhotoLocation(latitude: 10, longitude: 20, altitude: .nan)?.altitude == nil,
                    "invalid altitude does not discard otherwise valid GPS")
        let legacy = try JSONDecoder().decode(PhotoMetadata.self, from: Data(#"{"camera":"Old camera","iso":400}"#.utf8))
        try require(legacy.location == nil && legacy.iso == 400, "metadata predating GPS remains readable")

        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("GPSChecks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let image = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        func fixture(_ name: String, gps: [CFString: Any]?) throws -> PhotoFile {
            let url = root.appendingPathComponent(name + ".jpg")
            let output = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(output, image, gps.map { [kCGImagePropertyGPSDictionary: $0] as CFDictionary })
            try require(CGImageDestinationFinalize(output), "GPS metadata fixture created")
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return PhotoFile(url: url, kind: .rendered, size: Int64(values.fileSize!), modified: values.contentModificationDate!)
        }
        for (name, latRef, lonRef, altitudeRef, sign) in [("north-east", "N", "E", 0, 1.0), ("south-west", "S", "W", 1, -1.0)] {
            let file = try fixture(name, gps: [kCGImagePropertyGPSLatitude: 12.25, kCGImagePropertyGPSLatitudeRef: latRef,
                                               kCGImagePropertyGPSLongitude: 34.5, kCGImagePropertyGPSLongitudeRef: lonRef,
                                               kCGImagePropertyGPSAltitude: 23.5, kCGImagePropertyGPSAltitudeRef: altitudeRef])
            let original = try Data(contentsOf: file.url)
            let cacheDirectory = root.appendingPathComponent(name + "-cache"), cache = ThumbnailCache(directory: cacheDirectory)
            let preview = try await cache.image(file, maximum: 520)
            let expected = PhotoLocation(latitude: sign * 12.25, longitude: sign * 34.5, altitude: sign * 23.5)!
            try require(preview.metadata?.location == expected, "ImageIO preserves hemispheres and altitude reference in thumbnail metadata")
            if MetadataReader.executable != nil {
                let values = try MetadataReader().read(directory: root, assets: [PhotoAsset(id: name, name: name, files: [file])])
                try require(values[name]?.location == expected, "ExifTool GPS agrees with native GPS decoding")
            }
            let old = PhotoMetadata()
            let key = ThumbnailCache.digest("v1|\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)|520")
            try JSONEncoder().encode(old).write(to: cacheDirectory.appendingPathComponent(key + ".json"))
            let headerKey = ThumbnailCache.digest("metadata-v1|\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)")
            try Data(#"{"metadata":{"camera":"Legacy camera","lensModel":"Legacy lens"}}"#.utf8)
                .write(to: cacheDirectory.appendingPathComponent(headerKey + ".json"))
            let jpeg = cacheDirectory.appendingPathComponent(key + ".jpg")
            let bytes = try Data(contentsOf: jpeg)
            let date = try jpeg.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let reopened = ThumbnailCache(directory: cacheDirectory)
            let oldPreview = try await reopened.image(file, maximum: 520)
            try require(oldPreview.metadata?.location == nil, "legacy JPEG metadata can lack GPS")
            let enriched = try await reopened.sourceMetadata(file)
            try require(enriched?.location == expected, "legacy original-header cache is enriched with GPS even when the lens was already known")
            var freshJPEG = jpeg; freshJPEG.removeAllCachedResourceValues()
            try require(try Data(contentsOf: jpeg) == bytes && freshJPEG.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date,
                        "GPS enrichment does not regenerate cached JPEGs")
            let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheDirectory.appendingPathComponent(headerKey + ".json"))) as! [String: Any]
            try require(stored["version"] as? Int == 2, "enriched header cache records its GPS-capable schema")
            try require(try Data(contentsOf: file.url) == original, "GPS reading leaves original photo bytes unchanged")
            try fm.removeItem(at: file.url)
            let offline = try await ThumbnailCache(directory: cacheDirectory).sourceMetadata(file)
            try require(offline?.location == expected, "GPS survives cache recreation with the original offline")
            let roundtrip = try JSONDecoder().decode(PhotoMetadata.self, from: JSONEncoder().encode(enriched))
            try require(roundtrip.location == expected, "GPS coordinates survive metadata persistence")
        }
        let missing = try fixture("no-gps", gps: nil), absent = ThumbnailCache(directory: root.appendingPathComponent("missing-cache"))
        try require((try await absent.sourceMetadata(missing))?.location == nil, "photos without GPS do not invent a location")
        try fm.removeItem(at: missing.url)
        let negative = try await ThumbnailCache(directory: root.appendingPathComponent("missing-cache")).sourceMetadata(missing)
        try require(negative?.location == nil, "known missing GPS is cached without repeatedly opening the source")
    }
}
