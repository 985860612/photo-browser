import AppKit
import CoreImage
import Metal
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func focusPointChecks(root: URL) async throws {
        func decode(_ tags: [String: Any]) throws -> FocusPointMetadata {
            try FocusPointMetadata.decode(JSONSerialization.data(withJSONObject: [tags]))
        }
        // Same point dimensions and array padding as the user's EOS 70D originals.
        var canon: [String: Any] = ["IFD0:Make": "Canon", "IFD0:Model": "Canon EOS 70D", "IFD0:Orientation": 1,
            "Canon:FocusMode": 0, "Canon:NumAFPoints": 31, "Canon:ValidAFPoints": 19,
            "Canon:AFImageWidth": 5472, "Canon:AFImageHeight": 3648,
            "Canon:AFAreaWidths": Array(repeating: 229, count: 19) + Array(repeating: 0, count: 12),
            "Canon:AFAreaHeights": Array(repeating: 277, count: 19) + Array(repeating: 0, count: 12),
            "Canon:AFAreaXPositions": Array(repeating: 0, count: 31),
            "Canon:AFAreaYPositions": Array(repeating: 0, count: 31),
            "Canon:AFPointsInFocus": 9, "Canon:AFPointsSelected": "9, 18, 25"]
        let result = try decode(canon)
        try expect(result.regions.count == 2 && result.regions[0].kind == .inFocus && result.regions[1].kind == .selected,
                   "Canon printed point indices support scalar/multiple values, merge focused points and discard padded entries")
        try expect(abs(result.regions[0].rect.midX - 0.5) < 1e-9 && abs(result.regions[0].rect.width - 229.0/5472) < 1e-9,
                   "Canon AF sensor coordinates normalize to the photo")
        canon["Canon:FocusMode"] = 3
        try expect(try decode(canon).availability == .manualFocus, "Canon manual focus never invents an AF point")
        canon["Canon:FocusMode"] = 0
        canon["Canon:AFPointsInFocus"] = "(none)"; canon["Canon:AFPointsSelected"] = "(none)"
        try expect(try decode(canon).regions.isEmpty, "Canon no-focus sentinel does not select the centre")
        canon["Canon:AFPointsInFocus"] = 0; canon["Canon:AFAreaXPositions"] = "0"
        try expect(try decode(canon).regions.isEmpty, "Truncated Canon arrays fail safely")

        var sony: [String: Any] = ["IFD0:Make": "SONY", "IFD0:Model": "ILCE-7M4", "IFD0:Orientation": 1,
            "Sony:FocusMode": 2, "Sony:FocusLocation": "1000 800 300 240", "Sony:FocusFrameSize": "200 80 257"]
        let original = CGRect(x: 0.2, y: 0.25, width: 0.2, height: 0.1)
        let expected = [original,
            CGRect(x: 0.6, y: 0.25, width: 0.2, height: 0.1),
            CGRect(x: 0.6, y: 0.65, width: 0.2, height: 0.1),
            CGRect(x: 0.2, y: 0.65, width: 0.2, height: 0.1),
            CGRect(x: 0.25, y: 0.2, width: 0.1, height: 0.2),
            CGRect(x: 0.65, y: 0.2, width: 0.1, height: 0.2),
            CGRect(x: 0.65, y: 0.6, width: 0.1, height: 0.2),
            CGRect(x: 0.25, y: 0.6, width: 0.1, height: 0.2)]
        for orientation in 1...8 {
            sony["IFD0:Orientation"] = orientation
            let metadata = try decode(sony), rect = metadata.regions.first?.rect ?? .zero, wanted = expected[orientation - 1]
            try expect(abs(rect.minX-wanted.minX) + abs(rect.minY-wanted.minY) + abs(rect.width-wanted.width) + abs(rect.height-wanted.height) < 1e-8,
                       "Focus frame handles EXIF orientation \(orientation), including mirrors")
            try expect(metadata.regions.first?.kind == .recorded, "Sony recorded area does not claim confirmed focus")
        }
        sony["Sony:FocusMode"] = 0
        try expect(try decode(sony).availability == .manualFocus, "Sony default centre in manual mode is not an AF point")
        sony["Sony:FocusMode"] = 2; sony["Sony:FocusFrameSize"] = "0 0 0"
        try expect(try decode(sony).availability == .notRecorded, "Sony centre without a valid frame is not fabricated")
        sony["Sony:FocusFrameSize"] = "nan 80 257"
        try expect(try decode(sony).regions.isEmpty, "Non-finite coordinates are rejected")
        try expect(try decode(["IFD0:Make": "Unknown"]).availability == .unsupported, "Unsupported cameras have an explicit state")
        try await focusPresentationChecks(root: root, result: result)
        try await focusRenderChecks(root: root)
        if let paths = ProcessInfo.processInfo.environment["PHOTO_FOCUS_TEST_FILES"] {
            for path in paths.components(separatedBy: "\n") where !path.isEmpty {
                let file = PhotoFile(url: URL(fileURLWithPath: path), kind: path.lowercased().hasSuffix(".jpg") ? .rendered : .raw)
                let value = try FocusPointReader().read(file)
                try expect(value.availability == .available && !value.regions.isEmpty, "Read actual focus metadata: \(file.url.lastPathComponent)")
            }
        }
    }

    @MainActor private static func focusPresentationChecks(root: URL, result: FocusPointMetadata) async throws {
        let first = PhotoFile(url: root.appendingPathComponent("old.CR2"), kind: .raw)
        let second = PhotoFile(url: root.appendingPathComponent("new.ARW"), kind: .raw)
        var continuation: CheckedContinuation<FocusPointMetadata, Never>?
        let presentation = FocusPointPresentation { file in
            if file == first { return await withCheckedContinuation { continuation = $0 } }
            return FocusPointMetadata(availability: .manualFocus)
        }
        let old = Task { await presentation.load(first) }
        try await until { continuation != nil }
        await presentation.load(second)
        continuation?.resume(returning: result); await old.value
        try expect(presentation.file == second && presentation.metadata?.availability == .manualFocus,
                   "A late metadata response cannot overlay a different photo")
        try expect(presentation.regions(for: first, enabled: true).isEmpty && presentation.regions(for: second, enabled: false).isEmpty,
                   "Different-file metadata and disabled overlays are hidden immediately")
        await presentation.load(nil)
        try expect(presentation.metadata == nil && presentation.file == nil && !presentation.loading, "Disabling focus points clears presentation state")
        continuation = nil
        let cancelled = Task { await presentation.load(first) }
        try await until { continuation != nil }
        cancelled.cancel(); continuation?.resume(returning: result); await cancelled.value
        try expect(presentation.metadata == nil && !presentation.loading, "Cancelled focus reads do not publish results or leave a loading spinner")
        let reader = FocusPointReader(); reader.cancel()
        do {
            _ = try reader.read(first)
            throw BrowserFailure.message("Cancelled focus reader launched work")
        } catch is CancellationError { try expect(true, "A cancelled reader cannot start ExifTool") }
        let suite = "PhotoBrowser.FocusChecks.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserStore(supportDirectory: root.appendingPathComponent("focus-store"), defaults: defaults, monitoringEnabled: false)
        try expect(!store.showFocusPoints, "Focus display defaults to off")
        store.showFocusPoints = true
        let restored = BrowserStore(supportDirectory: root.appendingPathComponent("focus-store"), defaults: defaults, monitoringEnabled: false)
        try expect(restored.showFocusPoints, "Focus switch preference survives reopening")
    }
}
