import AppKit
import BrowserCore

extension PreviewStoreChecks {
    @MainActor static func directoryObserverChecks() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("ObserverChecks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var requests: [Bool] = [], failure: Error?
        let observer = try await DirectoryObserver(directory: root, pollInterval: 0.05,
            changed: { requests.append($0) }, failure: { failure = $0 })
        defer { observer.stop() }
        try await until { requests.count >= 3 || failure != nil }
        if let failure { throw failure }
        try expect(!requests.contains(true), "idle polling requests only lightweight checks and never promotes itself to a full scan")
        try Data([0]).write(to: root.appendingPathComponent("new.jpg"))
        try await until { requests.contains(true) || failure != nil }
        if let failure { throw failure }
        try expect(requests.contains(true), "actual directory events still request a complete reconciliation")
        observer.stop()
        let stopped = requests.count
        try await Task.sleep(for: .milliseconds(150))
        try expect(requests.count == stopped, "stopped observers cannot emit stale polling or directory events")
    }
}
