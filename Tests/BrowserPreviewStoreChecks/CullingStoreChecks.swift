import AppKit
import ImageIO
import BrowserCore
import CullingCore

extension PreviewStoreChecks {
    @MainActor static func cullingChecks() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PhotoBrowser-CullingStore-" + UUID().uuidString)
        let library = root.appendingPathComponent("library"), support = root.appendingPathComponent("support")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let bytes = NSMutableData(), output = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, nil); CGImageDestinationFinalize(output)
        for index in 0..<3 { try (bytes as Data).write(to: library.appendingPathComponent("photo\(index).jpg")) }
        try Data("paired raw".utf8).write(to: library.appendingPathComponent("photo0.arw"))
        try Data("sidecar".utf8).write(to: library.appendingPathComponent("photo0.xmp"))
        let assets = try DirectoryScanner.scan(library)
        let tracker = CullingProviderTracker()
        let culling = CullingStore(directory: support, provider: { asset, options in
            await tracker.record(asset.id)
            try await Task.sleep(for: .milliseconds(40))
            return PhotoAnalysis(assetID: asset.id, fingerprint: asset.fingerprint, signature: options.signature)
        })
        await culling.open(library, assets: assets, protectedIDs: [])
        defer { culling.close() }
        try expect(culling.available, "culling records open without requiring analysis")
        try expect(culling.mark(.keep, assets: [assets[0]]) && culling.mark(for: assets[0]) == .keep,
                   "RAW/JPEG/XMP family gets one persistent human decision")
        culling.start(assets: assets, options: AnalysisOptions())
        try await until { culling.completed >= 1 }
        culling.pause()
        let completed = culling.completed
        try await Task.sleep(for: .milliseconds(90))
        try expect(culling.completed == completed && !culling.running, "pause rejects late analysis results")
        let firstCount = await tracker.count(assets[0].id)
        culling.start(assets: assets, options: AnalysisOptions())
        try await until { !culling.running && !culling.grouping }
        let resumedFirstCount = await tracker.count(assets[0].id)
        try expect(culling.completed == assets.count && firstCount == resumedFirstCount,
                   "resuming skips checkpointed photos and finishes only pending work")
        try expect(culling.mark(for: assets[0]) == .keep, "machine analysis cannot overwrite human decisions")
        let group = SimilarityGroup(id: "ties", assetIDs: assets.map(\.id))
        culling.similarityGroups = [group]
        for asset in assets {
            var value = culling.analyses[asset.id]!
            value.aesthetics = 0.5; culling.analyses[asset.id] = value
        }
        try expect(culling.recommendedIDs.count == assets.count && culling.rank(of: assets[1].id, in: group) == 1,
                   "equal scores preserve tied recommendations rather than inventing a unique winner")
        culling.analyses.removeValue(forKey: assets[2].id)
        try expect(culling.recommendedIDs.isEmpty && culling.rank(of: assets[0].id, in: group) == nil,
                   "incomplete group scoring does not claim a winner or a complete ranking")
        culling.similarityGroups = []
        culling.start(assets: assets, options: AnalysisOptions())
        try await until { !culling.running && !culling.grouping }
        culling.undo()
        try expect(culling.mark(for: assets[0]) == .unreviewed, "undo restores and persists the previous human decision")
        try expect(culling.mark(.reject, assets: [assets[0]]), "reject is a reversible mark")
        try expect(fm.fileExists(atPath: assets[0].preferred.url.path), "reject never moves or deletes the original")
        let reopened = CullingStore(directory: support)
        await reopened.open(library, assets: assets, protectedIDs: [])
        try expect(reopened.mark(for: assets[0]) == .reject && reopened.analyses.count == assets.count,
                   "relaunch restores human marks and checkpointed analysis")
        var changed = assets
        try Data("external xmp edit".utf8).write(to: library.appendingPathComponent("photo0.xmp"))
        changed = try DirectoryScanner.scan(library)
        reopened.reconcile(changed, protectedIDs: [])
        try expect(reopened.mark(for: changed[0]) == .reject && reopened.decisionNeedsReview(changed[0])
                   && reopened.analysis(for: changed[0]) == nil,
                   "external edits retain marks, require human review, and invalidate analysis")
        reopened.close()

        let retryTracker = CullingProviderTracker()
        let retry = CullingStore(directory: root.appendingPathComponent("retry"), provider: { asset, options in
            let attempt = await retryTracker.record(asset.id)
            if asset.id == assets[1].id, attempt == 1 { throw BrowserFailure.message("Intentional read failure") }
            return PhotoAnalysis(assetID: asset.id, fingerprint: asset.fingerprint, signature: options.signature)
        })
        await retry.open(library, assets: changed, protectedIDs: [])
        retry.start(assets: changed, options: AnalysisOptions())
        try await until { !retry.running && !retry.grouping }
        try expect(retry.failures.count == 1 && retry.analyses.count == changed.count - 1,
                   "one failed read remains visible without discarding successful photos")
        retry.start(assets: changed, options: AnalysisOptions())
        try await until { !retry.running && !retry.grouping }
        let successfulCalls = await retryTracker.count(changed[0].id)
        try expect(retry.failures.isEmpty && retry.analyses.count == changed.count && successfulCalls == 1,
                   "retry processes failed photos while reusing successful analysis")
        retry.close()
        let late = CullingStore(directory: root.appendingPathComponent("late"), provider: { asset, options in
            await Task.detached { try? await Task.sleep(for: .milliseconds(120)) }.value
            return PhotoAnalysis(assetID: asset.id, fingerprint: asset.fingerprint, signature: options.signature)
        })
        await late.open(library, assets: changed, protectedIDs: [])
        late.start(assets: changed, options: AnalysisOptions())
        try await Task.sleep(for: .milliseconds(30))
        await late.open(root.appendingPathComponent("other"), assets: [], protectedIDs: [])
        try await Task.sleep(for: .milliseconds(160))
        try expect(late.analyses.isEmpty && late.available && !late.running,
                   "a provider that returns after a directory switch cannot contaminate the new folder")
        late.close()
        let blockedStorage = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blockedStorage)
        let unsaved = CullingStore(directory: blockedStorage)
        await unsaved.open(library, assets: changed, protectedIDs: [])
        try expect(!unsaved.mark(.keep, assets: [changed[0]]) && unsaved.mark(for: changed[0]) == .unreviewed
                   && unsaved.undoCount == 0 && unsaved.errorMessage != nil,
                   "failed persistence does not pretend to save a mark or add an undo entry")
        unsaved.close()

        let defaults = UserDefaults(suiteName: "PhotoBrowser.CullingChecks." + UUID().uuidString)!
        let browser = BrowserStore(supportDirectory: root.appendingPathComponent("browser"), defaults: defaults, monitoringEnabled: false)
        browser.load(library)
        try await until { !browser.isLoading && browser.culling.available }
        defer { browser.culling.close(); browser.cancelPreviewGeneration() }
        browser.setCullingActive(true)
        browser.culling.errorMessage = "Intentional culling error"
        try expect(browser.errorMessage == "Intentional culling error", "culling failures reach the shared browser alert even without the main view")
        browser.errorMessage = nil; browser.culling.errorMessage = nil
        let first = browser.visibleAssets[0]
        browser.select(first, modifiers: [])
        browser.markCullingSelection(.reject)
        try expect(browser.culling.mark(for: first) == .reject && browser.focusedID != first.id,
                   "marking advances focus through the visible photos")
        browser.setCullingFilter(.reject)
        try expect(browser.visibleAssets.map(\.id) == [first.id], "browser filters by persisted decision")
        let plan = try browser.cullingDeletionPlan([first])
        try expect(plan.fileCount == first.files.count && plan.record.isPendingDeletion,
                   "reviewed rejection plan includes paired formats and uses recoverable deletion")
        var stale = first
        stale = PhotoAsset(id: first.id, name: first.name,
                           files: [PhotoFile(url: first.preferred.url, kind: .rendered, size: first.preferred.size + 1)])
        var refusedStale = false
        do { _ = try browser.cullingDeletionPlan([stale]) } catch { refusedStale = true }
        try expect(refusedStale, "cleanup refuses a stale confirmation snapshot before moving any files")
        browser.archive(plan)
        try await until { !browser.isMoving }
        try expect(!fm.fileExists(atPath: first.preferred.url.path) && browser.culling.rejectedAssets.isEmpty,
                   "confirmed cleanup updates both the browser and culling results")
        let record = browser.history.first { $0.isPendingDeletion && $0.state == "complete" }!
        browser.undo(record)
        try await until { !browser.isMoving && !browser.isLoading && browser.culling.available }
        try expect(fm.fileExists(atPath: first.preferred.url.path)
                   && browser.culling.session.decisions[first.id]?.mark == .reject,
                   "move undo restores original files and preserves the user's culling decision")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(editor); window.makeFirstResponder(editor)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x",
                                    isARepeat: false, keyCode: 7)!
        try expect(browser.handleKeyDown(event, in: window) != nil, "typing X in a text editor does not change a culling mark")
        window.orderOut(nil)
        let corrupt = CullingRepository(directory: support).libraryDirectory(library).appendingPathComponent("decisions.json")
        try Data("corrupt".utf8).write(to: corrupt)
        await reopened.open(library, assets: assets, protectedIDs: [])
        try expect(!reopened.available && reopened.errorMessage != nil && !reopened.mark(.keep, assets: assets),
                   "failed restoration disables writes instead of overwriting manual records")
        reopened.close()
    }
}

private actor CullingProviderTracker {
    private var calls: [String: Int] = [:]
    @discardableResult func record(_ id: String) -> Int { calls[id, default: 0] += 1; return calls[id]! }
    func count(_ id: String) -> Int { calls[id, default: 0] }
}
