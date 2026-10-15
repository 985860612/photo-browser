import Foundation
import BrowserCore

/// The main actor only submits priorities. Indexing and dequeueing run on this actor's executor.
actor ThumbnailWarmQueue {
    private let files: [PhotoFile]
    private var positions: [String: [Int]] = [:]
    private var consumed: [Bool] = []
    private var cursor = 0
    private var preferred: [PhotoFile]
    private var priority: [Int] = []
    private var priorityCursor = 0
    private var initialized = false
    private var priorityRevision = 0

    init(files: [PhotoFile], priority: [PhotoFile]) {
        self.files = files; preferred = priority
    }

    private func initialize() {
        guard !initialized else { return }
        consumed = Array(repeating: false, count: files.count)
        for (index, file) in files.enumerated() { positions[file.id, default: []].append(index) }
        initialized = true
        applyPriority()
    }

    private func applyPriority() {
        var seen: Set<Int> = []
        priority = preferred.flatMap { positions[$0.id] ?? [] }.filter { !consumed[$0] && seen.insert($0).inserted }
        priorityCursor = 0
    }

    func prioritize(_ files: [PhotoFile], revision: Int) {
        guard !Task.isCancelled, revision >= priorityRevision else { return }
        priorityRevision = revision
        preferred = files
        if initialized { applyPriority() }
    }

    func prioritize(around index: Int, in assets: [PhotoAsset], revision: Int) {
        guard assets.indices.contains(index) else { return }
        prioritize(assets[max(0, index - 4)..<min(assets.count, index + 25)].map(\.preferred), revision: revision)
    }

    func next() -> PhotoFile? {
        guard !Task.isCancelled else { return nil }
        initialize()
        while priorityCursor < priority.count {
            let index = priority[priorityCursor]; priorityCursor += 1
            if !consumed[index] { consumed[index] = true; return files[index] }
        }
        while cursor < files.count {
            let index = cursor; cursor += 1
            if !consumed[index] { consumed[index] = true; return files[index] }
        }
        return nil
    }
}
