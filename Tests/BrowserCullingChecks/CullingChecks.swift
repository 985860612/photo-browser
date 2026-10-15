import AppKit
import BrowserCore
import CullingCore
import ImageIO
import Vision

@main struct CullingChecks {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PhotoBrowser-Culling-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let image = fixture()
        let files = (0..<5).map { index in
            PhotoAsset(id: "photo\(index)", name: "photo\(index)", files: [PhotoFile(url: root.appendingPathComponent("photo\(index).jpg"), kind: .rendered, size: 100)])
        }
        var options = AnalysisOptions()
        options.aesthetics = false; options.faces = false; options.classification = false
        let first = try VisionPhotoAnalyzer.analyze(image, asset: files[0], options: options)
        try require(first.featurePrint != nil, "real Vision produces a securely archived image feature")
        let feature = try VisionPhotoAnalyzer.feature(first.featurePrint!)
        let distance = try VisionPhotoAnalyzer.distance(feature, VisionPhotoAnalyzer.feature(first.featurePrint!))
        try require(distance.isFinite && distance < 0.0001, "feature archive roundtrip preserves zero distance for identical images")
        let full = try VisionPhotoAnalyzer.analyze(image, asset: files[0], options: AnalysisOptions())
        if VisionPhotoAnalyzer.supportsAesthetics {
            try require(full.aesthetics.map { $0.isFinite && (-1...1).contains($0) } == true && full.isUtility != nil,
                        "real Apple aesthetics API returns its documented score range and utility flag")
        }
        try require(full.faces.allSatisfy { $0.quality.map { (0...1).contains($0) } ?? true }, "face quality remains optional and bounded")
        var checks = 0, cancelled = false
        do {
            _ = try VisionPhotoAnalyzer.analyze(image, asset: files[0], options: options) {
                checks += 1; if checks >= 2 { throw CancellationError() }
            }
        } catch is CancellationError { cancelled = true }
        try require(cancelled, "analysis checks cancellation between Vision requests")

        var analyses: [String: PhotoAnalysis] = [:]
        for (index, asset) in files.enumerated() {
            var result = PhotoAnalysis(assetID: asset.id, fingerprint: asset.fingerprint, signature: options.signature)
            result.featurePrint = first.featurePrint
            result.captured = Date(timeIntervalSince1970: index == 4 ? 1000 : Double(index))
            analyses[asset.id] = result
        }
        var session = CullingSession()
        let groups = try SimilarityBuilder.build(assets: files, analyses: analyses, protectedIDs: [], session: session)
        try require(groups.count == 1 && groups[0].assetIDs.count == 4 && !groups[0].assetIDs.contains(files[4].id),
                    "identical nearby photos form a group while a separate time window stays apart")
        let protected = try SimilarityBuilder.build(assets: files, analyses: analyses, protectedIDs: Set(files.map(\.id)), session: session)
        try require(protected.isEmpty, "existing panorama and manual groups are protected from similarity selection")
        session.excludedFromSimilarity.insert(files[1].id)
        let excluded = try SimilarityBuilder.build(assets: files, analyses: analyses, protectedIDs: [], session: session)
        try require(excluded[0].assetIDs.count == 3 && !excluded[0].assetIDs.contains(files[1].id), "manual exclusion survives rebuilding")
        session.manualGroups = [SimilarityGroup(id: "manual", assetIDs: [files[0].id, files[1].id])]
        let manual = try SimilarityBuilder.build(assets: files, analyses: analyses, protectedIDs: [], session: session)
        try require(manual.contains { $0.id == "manual" && $0.assetIDs.count == 2 }
                    && Set(manual.flatMap(\.assetIDs)).count == manual.flatMap(\.assetIDs).count,
                    "manual groups are preserved without duplicate automatic membership")
        let changed = PhotoAsset(id: files[0].id, name: files[0].name,
                                 files: [PhotoFile(url: files[0].preferred.url, kind: .rendered, size: 200)])
        try require(!first.isCurrent(for: changed), "file fingerprint changes invalidate machine analysis")
        let repository = CullingRepository(directory: root.appendingPathComponent("support"))
        session.decisions[changed.id] = CullingDecision(mark: .reject, fingerprint: files[0].fingerprint)
        try repository.save(session, in: root)
        try repository.save(first, in: root)
        let restored = try repository.loadSession(in: root)
        try require(restored.decisions[changed.id]?.mark == .reject && restored.manualGroups == session.manualGroups,
                    "human marks and manual group edits persist independently of analysis")
        let loaded = try repository.loadAnalyses(for: [files[0], changed], in: root)
        try require(loaded[files[0].id] != nil, "analysis cache can restore unchanged file snapshots")
        var damaged = first; damaged.featurePrint = Data("broken feature archive".utf8)
        try repository.save(damaged, in: root)
        let discarded = try repository.loadAnalyses(for: [files[0]], in: root)
        try require(discarded.isEmpty, "corrupt feature archives are discarded so analysis can regenerate them")
        try repository.save(first, in: root)
        let invalidated = try repository.loadAnalyses(for: [changed], in: root)
        try require(invalidated.isEmpty && restored.decisions[changed.id]?.mark == .reject,
                    "changed files lose machine results but keep the user's decision for review")
        let other = root.appendingPathComponent("other")
        let otherSession = try repository.loadSession(in: other)
        try require(otherSession.decisions.isEmpty, "same filenames in another directory cannot inherit decisions")
        let sessionFile = repository.libraryDirectory(root).appendingPathComponent("decisions.json")
        try Data("corrupt user decision file".utf8).write(to: sessionFile)
        var refused = false
        do { _ = try repository.loadSession(in: root) } catch { refused = true }
        try require(refused && (try Data(contentsOf: sessionFile)) == Data("corrupt user decision file".utf8),
                    "corrupt human records report an error and are never silently overwritten")
        print("PASS all culling core checks")
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw BrowserFailure.message(message) }
        print("PASS \(message)")
    }
    static func fixture() -> CGImage {
        let context = CGContext(data: nil, width: 512, height: 384, bitsPerComponent: 8, bytesPerRow: 512 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 384))
        for index in 0..<28 {
            context.setFillColor(CGColor(red: CGFloat(index % 7) / 7, green: CGFloat(index % 5) / 5, blue: CGFloat(index % 3) / 3, alpha: 1))
            context.fillEllipse(in: CGRect(x: (index * 59) % 480, y: (index * 31) % 350, width: 15 + index * 3, height: 20 + index))
        }
        return context.makeImage()!
    }
}
