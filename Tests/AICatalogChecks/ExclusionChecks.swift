import Foundation
@testable import BrowserCore

extension CatalogChecks {
    static func exclusionChecks(in temp: URL) async throws {
        let root = temp.appendingPathComponent("exclusions", isDirectory: true)
        let hidden = root.appendingPathComponent("藏_100%[a]'", isDirectory: true)
        let album = root.appendingPathComponent("album", isDirectory: true)
        let repo = try AICatalogRepository(databaseURL: temp.appendingPathComponent("exclusions.sqlite"))
        let writer = try AICatalogWriter(repo.databaseURL, root: root)
        var fixtures = (0..<125).map { (root.appendingPathComponent("keep"), "processing.succeeded", "可见", $0) }
        fixtures += [(hidden, "processing.succeeded", "隐藏", 125),
                     (hidden.appendingPathComponent("子目录"), "processing.succeeded", "隐藏", 126),
                     (hidden, "processing.pending", "", 127),
                     (hidden.appendingPathComponent("子目录"), "processing.failed", "", 128),
                     (root.appendingPathComponent("藏_100%[a]'-backup"), "processing.succeeded", "可见", 129),
                     (album, "processing.succeeded", "可见", 130),
                     (root.appendingPathComponent("Album"), "processing.succeeded", "可见", 131)]
        try writer.transaction {
            for (directory, state, scene, n) in fixtures {
                let file = PhotoFile(url: directory.appendingPathComponent("photo\(n).JPG"), kind: .rendered, modified: Date(timeIntervalSince1970: Double(n)))
                let metadata = RecognitionMetadata(title: "photo\(n)", description: "", sections: [RecognitionSection(id: "scene_codes", name: "场景", tags: [RecognitionTag(code: scene, name: scene)])], rawResponse: "", modelName: nil, failure: nil)
                let item = AICatalogItem(asset: PhotoAsset(id: "photo\(n)", name: "photo\(n)", files: [file]), metadata: metadata, state: state)
                try writer.put(item, stamp: "fixture", priority: 20, analysisDate: "2026", generation: nil)
            }
        }
        let query = AICatalogFilter()
        let warm = try await repo.facets(root: root, filter: query, field: "scene_codes")
        try require(warm.first { $0.code == "隐藏" }?.count == 2, "Warm the facet cache before changing exclusions")
        let exclusions = [hidden, album, hidden.appendingPathComponent("子目录"), temp.appendingPathComponent("unrelated")]
        var ids: Set<String> = [], cursor: AICatalogCursor?
        repeat {
            let page = try await repo.page(root: root, filter: query, after: cursor, excluding: exclusions)
            try require(ids.isDisjoint(with: page.items.map(\.id)), "Exclusion pagination must not repeat photos")
            try require(page.items.allSatisfy { !AICatalogPaths.contains($0.directory, in: hidden) && $0.directory.path != album.path }, "Every page excludes the whole subtree")
            ids.formUnion(page.items.map(\.id)); cursor = page.hasMore ? page.cursor : nil
        } while cursor != nil
        try require(ids.count == 127, "Exclusion preserves shared-prefix, case-distinct and special-character sibling paths")
        let summary = try await repo.summary(root: root, filter: query, excluding: exclusions)
        try require(summary.total == 127 && summary.states == ["processing.succeeded": 127], "State totals exclude pending and failed photos too")
        let facets = try await repo.facets(root: root, filter: query, field: "scene_codes", excluding: exclusions)
        try require(facets.count == 1 && facets[0].code == "可见" && facets[0].count == 127, "Exclusion must invalidate cached facets")
        var tagged = query; tagged.tags = ["scene_codes": ["隐藏"]]; tagged.text = "photo"
        try require(try await repo.page(root: root, filter: tagged, excluding: exclusions).items.isEmpty, "Search and tag queries must respect exclusions")
        try require(try await repo.summary(root: root, filter: query, excluding: [temp]).total == 0, "Excluded ancestors hide the current scope")
        try require(try await repo.summary(root: root, filter: query, excluding: [URL(fileURLWithPath: "/")]).total == 0, "Filesystem-root exclusion")
        let reopened = try AICatalogRepository(databaseURL: repo.databaseURL)
        try require(try await reopened.summary(root: root, filter: query).total == 130, "Removing exclusion restores indexed photos without reimport or regeneration")
        let restoredFacets = try await reopened.facets(root: root, filter: query, field: "scene_codes")
        try require(restoredFacets.first { $0.code == "隐藏" }?.count == 2, "Removing exclusion restores facet counts")
        print("PASS AI folder exclusions: subtree, path boundaries, case, special characters, pagination, states, facets, search, restore")
    }
}
