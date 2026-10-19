import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import BrowserCore

extension CatalogChecks {
    static func visualSearchChecks(in temp: URL) async throws {
        let root = temp.appendingPathComponent("visual", isDirectory: true), hidden = root.appendingPathComponent("hidden", isDirectory: true)
        let repo = try AICatalogRepository(databaseURL: temp.appendingPathComponent("visual.sqlite"))
        let writer = try AICatalogWriter(repo.databaseURL, root: root)
        func item(_ name: String, in directory: URL? = nil) -> AICatalogItem {
            AICatalogItem(asset: PhotoAsset(id: name, name: name, files: [PhotoFile(url: (directory ?? root).appendingPathComponent(name + ".PNG"), kind: .rendered, size: 12, modified: Date(timeIntervalSince1970: 123))]))
        }
        func vector(_ entries: [(Int, Float)]) throws -> Data {
            var floats = [Float](repeating: 0, count: 768)
            for (index, value) in entries { floats[index] = value }
            return try AIImageVector(data: floats.withUnsafeBytes { Data($0) }).data
        }
        let seed = item("seed"), near = item("near"), far = item("far"), excluded = item("excluded", in: hidden), failed = item("failed")
        try writer.transaction { for photo in [seed, near, far, excluded, failed] { try writer.put(photo, stamp: "v1", priority: 1, analysisDate: "2026", generation: nil) } }
        let db = try AICatalogDatabase(repo.databaseURL, write: true)
        for (photo, data) in [(seed, try vector([(0,1)])), (near, try vector([(0,0.99),(1,0.1)])), (far, try vector([(2,1)])), (excluded, try vector([(0,1)]))] {
            try AIVisualStorage.put(db, AIVisualOutcome(item: photo, data: data, issue: nil))
        }
        try AIVisualStorage.put(db, AIVisualOutcome(item: failed, data: nil, issue: "fixture failure"))
        let hits = try await repo.similarPhotos(to: seed, root: root, excluding: [hidden], limit: 2)
        try require(hits.map(\.item.id) == [near.id, far.id] && hits[0].distance < hits[1].distance, "Rank by image-vector distance; omit source, failures and excluded directories")
        let subset = try await repo.similarPhotos(to: seed, root: root, limit: 1)
        try require(subset.first?.id == excluded.id, "Nearest-K must retain the best match regardless of visit order")
        let status = try await repo.visualIndexStatus(root: root, excluding: [hidden])
        try require(status.total == 4 && status.indexed == 3 && status.failed == 1 && status.complete, "Index coverage and failures follow scope exclusions")
        try db.execute("UPDATE photo_vector SET model='old-model' WHERE photo_id=(SELECT id FROM photo WHERE key=?)", [.text(near.id)])
        try require(try await repo.similarPhotos(to: seed, root: root, excluding: [hidden]).map(\.id) == [far.id], "Vector spaces from different model versions must not mix")
        try AIVisualStorage.put(db, AIVisualOutcome(item: near, data: try vector([(0,0.99),(1,0.1)]), issue: nil))
        var changed = near
        changed.asset = PhotoAsset(id: near.asset.id, name: near.asset.name, files: [PhotoFile(url: near.asset.preferred.url, kind: .rendered, size: 13, modified: Date(timeIntervalSince1970: 124))])
        try writer.transaction { try writer.put(changed, stamp: "v2", priority: 2, analysisDate: "2027", generation: nil) }
        try require(!AIVisualStorage.put(db, AIVisualOutcome(item: near, data: try vector([(0,1)]), issue: nil)), "An old in-flight extraction cannot overwrite a changed source snapshot")
        try require(try await repo.visualIndexStatus(root: root, excluding: [hidden]).indexed == 2, "Source changes invalidate cached vectors")
        try await repo.resetVisualIndex(root: root, excluding: [hidden], failuresOnly: true)
        let retry = try await repo.visualIndexStatus(root: root, excluding: [hidden])
        try require(retry.indexed == 2 && retry.failed == 0 && !retry.complete, "Retry failures preserves valid vectors and makes failed sources resumable")
        try require(try await repo.similarPhotos(to: seed, root: root, excluding: [root]).isEmpty, "Excluded scope ancestors produce no matches")
        let cancel = Task { try await repo.similarPhotos(to: seed, root: root) }; cancel.cancel()
        do { _ = try await cancel.value; throw BrowserFailure.message("Cancelled vector search returned results") } catch is CancellationError {}
        var heap = AIVisualHeap(limit: 7)
        let values = (0..<1000).map { (row: Int64($0), distance: Float(($0 * 71) % 137) / 100) }
        for value in values { heap.add(row: value.row, distance: value.distance) }
        let expected = values.sorted { $0.distance == $1.distance ? $0.row < $1.row : $0.distance < $1.distance }.prefix(7).map(\.row)
        try require(heap.sorted().map(\.row) == expected, "Bounded top-K agrees with exhaustive sorting, including ties")
        try await visualExtractionChecks(in: temp)
        print("PASS image-vector search: nearest-K, source exclusion, path rules, model versioning, source invalidation, cancellation and resume")
    }

    static func visualExtractionChecks(in temp: URL) async throws {
        let root = temp.appendingPathComponent("visual-pixels", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pixels = bitmap.bitmapData!
        for y in 0..<72 { for x in 0..<96 {
            let offset = y * bitmap.bytesPerRow + x * 3
            pixels[offset] = UInt8(x * 255 / 96); pixels[offset + 1] = UInt8(y * 255 / 72); pixels[offset + 2] = UInt8((x * y) % 73 * 255 / 73)
        } }
        let png = bitmap.representation(using: .png, properties: [:])!
        let repo = try AICatalogRepository(databaseURL: temp.appendingPathComponent("pixels.sqlite"))
        let writer = try AICatalogWriter(repo.databaseURL, root: root)
        var photos: [AICatalogItem] = []
        for n in 0..<65 {
            let file = root.appendingPathComponent("image\(n).PNG")
            try png.write(to: file)
            var photo = AICatalogItem(asset: PhotoAsset(id: "image\(n)", name: "image\(n)", files: [PhotoFile(url: file, kind: .rendered, size: Int64(png.count))]))
            photo.preview = file; photos.append(photo)
        }
        let bad = root.appendingPathComponent("bad.PNG")
        try Data("damaged thumbnail".utf8).write(to: bad)
        var failed = AICatalogItem(asset: PhotoAsset(id: "bad", name: "bad", files: [PhotoFile(url: bad, kind: .rendered)])); failed.preview = bad
        try writer.transaction { for photo in photos + [failed] { try writer.put(photo, stamp: "v1", priority: 1, analysisDate: "2026", generation: nil) } }
        let interrupted = Task {
            try await repo.indexVisualPhotos(root: root) { value in
                if value.indexed == 64 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { try await interrupted.value; throw BrowserFailure.message("Index cancellation was ignored") } catch is CancellationError {}
        try require(try await repo.visualIndexStatus(root: root).indexed == 64, "A completed vector batch survives cancellation")
        try await repo.indexVisualPhotos(root: root) { _ in }
        let status = try await repo.visualIndexStatus(root: root)
        try require(status.indexed == 65 && status.failed == 1 && status.complete, "Resume indexes remaining photos and records extraction failures")
        let result = try await repo.similarPhotos(to: photos[0], root: root, limit: 5)
        try require(result.count == 5 && result.allSatisfy { $0.distance < 0.0001 && $0.id != photos[0].id }, "Identical pixels give zero-distance matches without returning the source")
        try png.write(to: bad)
        try await repo.resetVisualIndex(root: root, failuresOnly: true)
        try await repo.indexVisualPhotos(root: root) { _ in }
        try require(try await repo.visualIndexStatus(root: root).indexed == 66, "Failed extraction can be retried after repairing its preview")
        for photo in photos { try FileManager.default.removeItem(at: photo.preview!) }
        try FileManager.default.removeItem(at: bad)
        try await repo.indexVisualPhotos(root: root) { _ in }
        try require(try await repo.similarPhotos(to: photos[0], root: root, limit: 5).count == 5, "Completed vectors support offline search and resume without reopening originals")
        print("PASS Vision extraction: 768-d vectors, bounded batch cancellation, persistence, failure retry and offline search")
    }
}
