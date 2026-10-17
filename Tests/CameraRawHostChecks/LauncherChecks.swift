import AppKit
import BrowserCore

@main struct CameraRawLauncherChecks {
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw BrowserFailure.message(message) }
        print("PASS \(message)")
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--launch" {
            try await launch(CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) })
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("原始照片.tif"), alias = root.appendingPathComponent("alias.tif")
        try Data([1]).write(to: original)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let normalized = CameraRawLauncher.canonicalImages([PhotoFile(url: original, kind: .rendered), PhotoFile(url: alias, kind: .rendered)])
        try require(normalized == [original.resolvingSymlinksInPath()], "canonical paths deduplicate repeated and symlinked inputs")
        var emptyReported = false
        do { try CameraRawLauncher.open([]) { _ in } } catch { emptyReported = true }
        try require(emptyReported, "empty selections are rejected")
        let result = root.appendingPathComponent("result.json")
        func check(_ data: String?, exit: Int32 = 0, normal: Bool = true, accepts: Bool) throws {
            if let data { try Data(data.utf8).write(to: result) }
            else { try? FileManager.default.removeItem(at: result) }
            var accepted = true
            do { try CameraRawLauncher.validateResult(at: result, exitCode: exit, exitedNormally: normal) }
            catch { accepted = false }
            try require(accepted == accepts, "host result \(data ?? "missing"), exit \(exit), normal \(normal)")
        }
        let closed = #"{"version":1,"status":"closed","stage":"settings","code":0,"editorOpened":true}"#
        try check(closed, accepts: true)
        try check(closed.replacingOccurrences(of: "\"code\":0", with: "\"code\":-128"), accepts: true)
        try check(closed, exit: 9, accepts: false)
        try check(closed, normal: false, accepts: false)
        try check(nil, accepts: false)
        try check("{broken", accepts: false)
        for replacement in [("closed", "editing"), ("closed", "failed"), ("settings", "load"),
                            ("true", "false"), ("\"version\":1", "\"version\":2"), ("\"code\":0", "\"code\":-30504")] {
            try check(closed.replacingOccurrences(of: replacement.0, with: replacement.1), accepts: false)
        }
        var missingReported = false
        do { _ = try CameraRawLauncher.installedPlugin(in: [root]) } catch { missingReported = true }
        try require(missingReported, "a missing plug-in is reported without launching Bridge")
    }

    @MainActor static func launch(_ urls: [URL]) async throws {
        var ended = false, failure: Error?
        let files = urls.map { PhotoFile(url: $0, kind: .rendered) }
        let launched = try CameraRawLauncher.open(files) { error in failure = error; ended = true }
        try require(launched, "packaged launcher starts bundled native helper")
        let duplicate = try CameraRawLauncher.open(files.reversed()) { _ in fatalError("Duplicate request must not register a completion") }
        try require(!duplicate, "reopening the same batch in reverse order reuses the active editor")
        var busyReported = false
        do { try CameraRawLauncher.open(PhotoFile(url: urls[0].appendingPathExtension("other"), kind: .rendered)) { _ in } }
        catch { busyReported = true }
        try require(busyReported, "a different image cannot enter the active editor session")
        let deadline = Date().addingTimeInterval(40)
        while !ended && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try require(ended, "native helper reports completion asynchronously")
        if let failure { throw failure }
        try require(true, "normal Cancel is accepted by the actual Swift launcher")
    }
}
