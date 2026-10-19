import Foundation
import AppKit
@testable import BrowserCore

@main struct CatalogChecks {
    static func require(_ yes: Bool, _ detail: String) throws { if !yes { throw BrowserFailure.message(detail) } }
    static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.contains("--library") { try await benchmark(); return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("AICatalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try await exclusionChecks(in: temp)
        try await visualSearchChecks(in: temp)
        let root = temp.appendingPathComponent("photos"), other = temp.appendingPathComponent("photos-other")
        for folder in [root, other, root.appendingPathComponent("sub"), root.appendingPathComponent("_del"), root.appendingPathComponent(".hidden"), root.appendingPathComponent("@Recently-Snapshot")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("photo".utf8).write(to: root.appendingPathComponent("same.JPG"))
        try Data("raw".utf8).write(to: root.appendingPathComponent("same.ARW"))
        try Data("psd".utf8).write(to: root.appendingPathComponent("skip.PSD"))
        try Data("video".utf8).write(to: root.appendingPathComponent("skip.MOV"))
        try Data("photo".utf8).write(to: root.appendingPathComponent("sub/same.JPG"))
        for name in ["_del/hidden.JPG", ".hidden/hidden.JPG", "@Recently-Snapshot/old.JPG"] { try Data().write(to: root.appendingPathComponent(name)) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let repo = try AICatalogRepository(databaseURL: temp.appendingPathComponent("catalog.sqlite"), runs: temp.appendingPathComponent("no-runs"), generated: temp.appendingPathComponent("generated"))
        try await repo.synchronize(root: root) { _ in }
        var query = AICatalogFilter(); query.state = "processing.pending"
        let initial = try await repo.page(root: root, filter: query)
        try require(initial.items.count == 2, "inventory must group RAW/JPG, exclude videos/PSD/trash/symlinks")
        try require(Set(initial.items.map(\.id)).count == 2, "global identity must distinguish same stem in different directories")
        try require(initial.items.first { $0.directory.path == root.path }?.asset.imageFiles.count == 2, "format family")
        let writer = try AICatalogWriter(repo.databaseURL, root: root)
        try writer.transaction {
            for n in 0..<125 {
                let file = PhotoFile(url: root.appendingPathComponent("image\(n).JPG"), kind: .rendered, modified: Date(timeIntervalSince1970: Double(n)))
                let asset = PhotoAsset(id: "image\(n)", name: "image\(n)", files: [file])
                let scene = n < 80 ? "公园" : "城市", subject = n % 2 == 0 ? "人" : "花"
                let m = RecognitionMetadata(title: "飞机 \(n)", description: "literal_100%", sections: [RecognitionSection(id: "scene_codes", name: "场景", tags: [RecognitionTag(code: scene, name: scene)]), RecognitionSection(id: "subject_codes", name: "主体", tags: [RecognitionTag(code: subject, name: subject)])], rawResponse: "never index raw response", modelName: nil, failure: nil)
                try writer.put(AICatalogItem(asset: asset, metadata: m, state: "processing.succeeded"), stamp: "v1", priority: 20, analysisDate: "2026", generation: nil)
            }
        }
        query = AICatalogFilter()
        var ids: Set<String> = [], cursor: AICatalogCursor?
        repeat {
            let page = try await repo.page(root: root, filter: query, after: cursor)
            try require(ids.isDisjoint(with: page.items.map(\.id)), "cursor repeated item")
            ids.formUnion(page.items.map(\.id)); cursor = page.hasMore ? page.cursor : nil
            try require(page.items.allSatisfy { $0.metadata?.rawResponse == "" }, "raw response must stay out of derived blobs")
        } while cursor != nil
        try require(ids.count == 125, "keyset must return every item exactly once")
        query.tags = ["scene_codes": ["公园", "城市"], "subject_codes": ["人"]]
        let summary = try await repo.summary(root: root, filter: query)
        try require(summary.total == 63, "OR within field, AND across fields")
        query.tags["scene_codes"] = ["城市"]
        let facets = try await repo.facets(root: root, filter: query, field: "scene_codes")
        try require(facets.first { $0.name == "公园" }?.count == 40 && facets.first { $0.name == "城市" }?.count == 23, "facet must omit its own constraint")
        query.tags = [:]; query.text = "飞机 literal_100%"
        try require(try await repo.summary(root: root, filter: query).total == 125, "Chinese words AND and literal LIKE escaping")
        query.text = "missing"; query.tags = ["scene_codes": ["城市"]]
        try require(try await repo.page(root: root, filter: query).items.isEmpty, "empty combination")
        try require(!AICatalogPaths.contains(other, in: root), "path boundary must not match shared prefix")
        let cancelled = Task { try await repo.summary(root: root, filter: AICatalogFilter()) }; cancelled.cancel()
        do { _ = try await cancelled.value; throw BrowserFailure.message("cancelled query returned results") } catch is CancellationError {}
        // Snapshot changes invalidate results, while a sidecar edit does not.
        let original = initial.items.first { $0.directory.path == root.path }!.asset
        let recognized = RecognitionMetadata(title: "old", description: "", sections: [], rawResponse: "", modelName: nil, failure: nil)
        try writer.transaction { try writer.put(AICatalogItem(asset: original, metadata: recognized, state: "processing.succeeded"), stamp: "v2", priority: 30, analysisDate: "2027", generation: nil) }
        try Data("sidecar".utf8).write(to: root.appendingPathComponent("same.xmp"))
        try await repo.synchronize(root: root) { _ in }
        let withSidecar = try await repo.page(root: root, filter: AICatalogFilter())
        try require(withSidecar.items.first?.metadata?.title == "old" && withSidecar.items.first?.asset.files.contains { $0.kind == .sidecar } == true, "Adding XMP preserves AI results and updates copied file family")
        try Data("changed photo".utf8).write(to: root.appendingPathComponent("same.JPG"))
        try await repo.synchronize(root: root) { _ in }
        query = AICatalogFilter(); query.state = "processing.pending"
        try require(try await repo.page(root: root, filter: query).items.count == 2, "source change must clear old classifications and prune gone files")
        let final = try await repo.summary(root: root, filter: query)
        try require(final.complete && final.states["processing.succeeded"] == nil, "successful inventory prunes missing membership")
        // Exercise the real V2 importer and persisted native overrides, without model requests.
        let runs = temp.appendingPathComponent("runs"), stage = runs.appendingPathComponent("v2"), format = stage.appendingPathComponent("format")
        try FileManager.default.createDirectory(at: format, withIntermediateDirectories: true)
        for (source, target) in [("recognition-format", "text-format"), ("recognition-dictionary", "dictionary")] {
            try FileManager.default.copyItem(at: L10n.resourceBundle.url(forResource: source, withExtension: "json")!, to: format.appendingPathComponent(target + ".json"))
        }
        let manifest: [String: Any] = ["schema_version": "2.0.0", "source_root": root.path]
        try JSONSerialization.data(withJSONObject: manifest).write(to: stage.appendingPathComponent("manifest.json"))
        let record = stage.appendingPathComponent("mirror/record.json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        let currentAsset = try DirectoryScanner.scan(root).first { !$0.isVideo }!
        let analysisID = UUID().uuidString
        var wire: [String: Any] = ["facts": ["exif": ["captured_local": "2020-06-01T10:30:00"]], "files": GeneratedRecognitionStore.identities(currentAsset), "processing": ["state_code": "processing.succeeded", "current_analysis_id": analysisID], "analyses": [["analysis_id": analysisID, "created_at": "2030-01-01T00:00:00Z", "raw_response": "标题：批次照片\n场景：公园"]]]
        try JSONSerialization.data(withJSONObject: wire).write(to: record)
        let queue = stage.appendingPathComponent("queue.sqlite")
        do {
            let queueDB = try AICatalogDatabase(queue, write: true)
            try queueDB.execute("CREATE TABLE assets(payload TEXT,record_path TEXT,asset_id TEXT,state TEXT)")
            try queueDB.execute("INSERT INTO assets VALUES(?,?,?,?)", [.text("{\"directory\":\".\"}"), .text(record.path), .text("fixture"), .text("succeeded")])
        }
        let unchangedQueue = try Data(contentsOf: queue), unchangedRecord = try Data(contentsOf: record)
        let importRepo = try AICatalogRepository(databaseURL: temp.appendingPathComponent("import.sqlite"), runs: runs, generated: temp.appendingPathComponent("native"))
        try await importRepo.synchronize(root: root) { _ in }
        let imported = try await importRepo.page(root: root, filter: AICatalogFilter())
        try require(imported.items.count == 1 && imported.items[0].metadata?.title == "批次照片", "V2 local import uses current analysis and protocol parser")
        let expectedLocalDate = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .current, year: 2020, month: 6, day: 1, hour: 10, minute: 30))
        try require(imported.items[0].asset.metadata?.captured == expectedLocalDate, "EXIF without a UTC offset keeps native local-time semantics")
        let again = try AICatalogDatabase(importRepo.databaseURL).rows("SELECT stamp FROM photo WHERE key=?", [.text(imported.items[0].id)])[0][0].string
        try await importRepo.synchronize(root: root) { _ in }
        try require(try AICatalogDatabase(importRepo.databaseURL).rows("SELECT stamp FROM photo WHERE key=?", [.text(imported.items[0].id)])[0][0].string == again, "Unchanged metadata retains its source stamp")
        let native = GeneratedRecognitionStore(root: temp.appendingPathComponent("native"))
        _ = try await native.save(currentAsset, analysis: ["analysis_id": UUID().uuidString, "created_at": "2026-01-01T00:00:00Z", "raw_response": "标题：本地覆盖\n场景：城市"])
        try await importRepo.synchronize(root: root) { _ in }
        try require(try await importRepo.page(root: root, filter: AICatalogFilter()).items.first?.metadata?.title == "本地覆盖", "Local generated override wins over newer batch analysis")
        try require(try await importRepo.page(root: root, filter: AICatalogFilter()).items.first?.asset.metadata?.captured == expectedLocalDate, "Native AI regeneration preserves cached source facts and capture ordering")
        try require(try Data(contentsOf: record) == unchangedRecord, "Source record must remain read-only")
        try require(try await importRepo.page(root: root, filter: AICatalogFilter()).items.first?.preview?.path == imported.items.first?.preview?.path, "Native override must preserve a valid local preview")
        wire["updated_at"] = "2031-01-01T00:00:00Z"
        try JSONSerialization.data(withJSONObject: wire).write(to: record)
        try await importRepo.synchronize(root: root) { _ in }
        try require(try await importRepo.page(root: root, filter: AICatalogFilter()).items.first?.metadata?.title == "本地覆盖", "Refreshing changed batch records must preserve local override")
        try require(try Data(contentsOf: queue) == unchangedQueue, "Source queue must remain read-only")
        let noExtension = root.appendingPathComponent("Camera f_1.78_191", isDirectory: false)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .jpeg, properties: [:])!.write(to: noExtension)
        let attrs = try FileManager.default.attributesOfItem(atPath: noExtension.path)
        let knownFile = PhotoFile(url: noExtension, kind: .rendered, size: (attrs[.size] as! NSNumber).int64Value,
                                  modified: attrs[.modificationDate] as! Date, formatHint: "jpeg")
        let knownPhoto = PhotoAsset(id: "camera f_1.78_191", name: "Camera f_1.78_191", files: [knownFile])
        var identity = GeneratedRecognitionStore.identities(knownPhoto)[0]; identity["role_code"] = "file.rendered"
        let noExtRecord = stage.appendingPathComponent("mirror/no-extension.json")
        let noExtWire: [String: Any] = ["files": [identity], "processing": ["state_code": "processing.succeeded", "current_analysis_id": analysisID],
            "analyses": [["analysis_id": analysisID, "raw_response": "标题：无后缀照片\n场景：街道"]]]
        try JSONSerialization.data(withJSONObject: noExtWire).write(to: noExtRecord)
        do {
            let db = try AICatalogDatabase(queue, write: true)
            let payload: [String: Any] = ["directory": ".", "files": [["name": noExtension.lastPathComponent, "role": "rendered", "format": "jpeg"]]]
            try db.execute("INSERT INTO assets VALUES(?,?,?,?)", [.text(String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)), .text(noExtRecord.path), .text("no-extension"), .text("succeeded")])
        }
        try await importRepo.synchronize(root: root) { _ in }
        let withKnown = try await importRepo.page(root: root, filter: AICatalogFilter())
        let extensionless = withKnown.items.first { $0.asset.id == knownPhoto.id }
        try require(extensionless?.asset.preferred.format == "JPEG" && extensionless?.metadata?.title == "无后缀照片", "Role and format from metadata preserve extensionless filenames and captions")
        let nativeAssets = try DirectoryScanner.scan(root, knownAssets: AICatalogKnownAssets.read(importRepo.databaseURL, directory: root))
        try require(nativeAssets.contains { $0.id == knownPhoto.id }, "Show in Folder can select the original extensionless family")
        let cache = ThumbnailCache(directory: temp.appendingPathComponent("thumbs"))
        let preview = try await cache.image(knownFile, maximum: 720)
        let upload = try PhotoRecognitionGenerator.jpeg(preview.image)
        try require(upload.width == 4 && upload.height == 3, "Extensionless JPEG uses the existing thumbnail and upload preparation path")
        let gifURL = root.appendingPathComponent("twin.GIF", isDirectory: false)
        try bitmap.representation(using: .gif, properties: [:])!.write(to: gifURL)
        try bitmap.representation(using: .jpeg, properties: [:])!.write(to: root.appendingPathComponent("twin.JPG"))
        let gifAttrs = try FileManager.default.attributesOfItem(atPath: gifURL.path)
        let gifPhoto = PhotoAsset(id: "twin.gif", name: "twin.GIF", files: [PhotoFile(url: gifURL, kind: .rendered,
            size: (gifAttrs[.size] as! NSNumber).int64Value, modified: gifAttrs[.modificationDate] as! Date, formatHint: "gif")])
        var gifIdentity = GeneratedRecognitionStore.identities(gifPhoto)[0]; gifIdentity["role_code"] = "file.rendered"
        var gifWire = noExtWire; gifWire["files"] = [gifIdentity]
        let gifRecord = stage.appendingPathComponent("mirror/gif.json")
        try JSONSerialization.data(withJSONObject: gifWire).write(to: gifRecord)
        do {
            let db = try AICatalogDatabase(queue, write: true)
            let payload: [String: Any] = ["directory": ".", "stem": "twin.gif", "files": [["name": "twin.GIF", "format": "gif"]]]
            try db.execute("INSERT INTO assets VALUES(?,?,?,?)", [.text(String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)), .text(gifRecord.path), .text("gif"), .text("succeeded")])
        }
        try await importRepo.synchronize(root: root) { _ in }
        let distinct = try DirectoryScanner.scan(root, knownAssets: AICatalogKnownAssets.read(importRepo.databaseURL, directory: root))
        try require(distinct.contains { $0.id == "twin.gif" && $0.preferred.format == "GIF" } && distinct.contains { $0.id == "twin" }, "Authoritative batch IDs keep an unusual format distinct from an ordinary JPEG family")
        try require(try await importRepo.lastIndexed(root: root) != nil, "Completed inventory is reusable without source I/O")
        let offline = temp.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: root, to: offline)
        var inventoryFailed = false
        do { try await importRepo.synchronize(root: root) { _ in } } catch { inventoryFailed = true }
        try require(inventoryFailed, "Unavailable source inventory must report failure")
        try require(try await importRepo.lastIndexed(root: root) == nil, "Failed scope stays incomplete")
        try require(try await importRepo.page(root: root, filter: AICatalogFilter()).items.count == 3, "Unavailable inventory must preserve cached memberships")
        try FileManager.default.moveItem(at: offline, to: root)
        let nasRoot = temp.appendingPathComponent("nas-only", isDirectory: true)
        let nasRun = nasRoot.appendingPathComponent(".photobrowser/v2/fixture", isDirectory: true)
        let nasRecords = nasRun.appendingPathComponent("assets/aa", isDirectory: true)
        try FileManager.default.createDirectory(at: nasRecords, withIntermediateDirectories: true)
        for name in ["text-format.json", "dictionary.json"] {
            try FileManager.default.copyItem(at: format.appendingPathComponent(name), to: nasRun.appendingPathComponent(name))
        }
        let nasPhotoURL = nasRoot.appendingPathComponent(noExtension.lastPathComponent, isDirectory: false)
        try FileManager.default.copyItem(at: noExtension, to: nasPhotoURL)
        let nasAttrs = try FileManager.default.attributesOfItem(atPath: nasPhotoURL.path)
        let nasPhoto = PhotoAsset(id: knownPhoto.id, name: knownPhoto.name, files: [PhotoFile(url: nasPhotoURL, kind: .rendered,
            size: (nasAttrs[.size] as! NSNumber).int64Value, modified: nasAttrs[.modificationDate] as! Date)])
        var nasIdentity = GeneratedRecognitionStore.identities(nasPhoto)[0]; nasIdentity["role_code"] = "file.rendered"
        var nasWire = noExtWire; nasWire["files"] = [nasIdentity]
        try JSONSerialization.data(withJSONObject: nasWire).write(to: nasRecords.appendingPathComponent("photo.json"))
        let nasRepo = try AICatalogRepository(databaseURL: temp.appendingPathComponent("nas.sqlite"), runs: temp.appendingPathComponent("no-local-runs"), generated: temp.appendingPathComponent("no-native"))
        try await nasRepo.synchronize(root: nasRoot) { _ in }
        let fromNAS = try await nasRepo.page(root: nasRoot, filter: AICatalogFilter())
        try require(fromNAS.items.count == 1 && fromNAS.items[0].asset.id == knownPhoto.id, "NAS-only metadata rebuild includes and validates extensionless originals in the first pass")
        print("PASS AI catalog: inventory, formats, collisions, keyset, OR/AND, facets, Chinese search, escaping, cancellation, snapshots, pruning")
    }
    static func benchmark() async throws {
        let path = CommandLine.arguments.last!, root = URL(fileURLWithPath: path)
        let repo = try AICatalogRepository()
        let start = Date()
        try await repo.synchronize(root: root) { p in
            if (p.imported > 0 && p.imported % 4096 == 0) || (p.scanned > 0 && p.scanned % 2000 == 0) || p.complete { print("progress imported=\(p.imported) scanned=\(p.scanned) complete=\(p.complete) issue=\(p.issue ?? "")") }
        }
        print("SYNC seconds=\(Date().timeIntervalSince(start))")
        let summary = try await repo.summary(root: root, filter: AICatalogFilter()); print("SUMMARY \(summary.total) \(summary.states) complete=\(summary.complete)")
        var pageMS: [Double] = [], facetMS: [Double] = [], searchMS: [Double] = [], tagMS: [Double] = []
        var query = AICatalogFilter()
        let field = "scene_codes", coldStart = Date()
        let first = try await repo.facets(root: root, filter: query, field: field).first
        print("cold scene facet ms=\(Date().timeIntervalSince(coldStart)*1000)")
        for _ in 0..<20 {
            var t = Date(); _ = try await repo.page(root: root, filter: query); pageMS.append(Date().timeIntervalSince(t)*1000)
            t = Date(); _ = try await repo.facets(root: root, filter: query, field: field); facetMS.append(Date().timeIntervalSince(t)*1000)
            query.text = "飞机"; t = Date(); _ = try await repo.page(root: root, filter: query); searchMS.append(Date().timeIntervalSince(t)*1000); query.text = ""
            if let first { query.tags[field] = [first.code]; t = Date(); _ = try await repo.page(root: root, filter: query); tagMS.append(Date().timeIntervalSince(t)*1000); query.tags = [:] }
        }
        for (name, values) in [("page", pageMS), ("facets cached", facetMS), ("Chinese search", searchMS), ("tag", tagMS)] {
            guard !values.isEmpty else { continue }
            print("\(name) p95-ms=\(values.sorted()[Int(Double(values.count-1)*0.95)])")
        }
    }
}
