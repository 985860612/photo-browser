import AppKit
import BrowserCore

@MainActor enum CameraRawLauncher {
    struct HostResult: Decodable {
        let version: Int
        let status: String
        let stage: String
        let code: Int
        let editorOpened: Bool
    }
    private struct Session {
        let process: Process
        let images: Set<URL>
    }
    private static var session: Session?

    @discardableResult static func open(_ file: PhotoFile, completion: @escaping (Error?) -> Void) throws -> Bool {
        try open([file], completion: completion)
    }

    static func canonicalImages(_ files: [PhotoFile]) -> [URL] {
        var seen = Set<URL>()
        return files.map { $0.url.resolvingSymlinksInPath().standardizedFileURL }.filter { seen.insert($0).inserted }
    }

    @discardableResult static func open(_ files: [PhotoFile], completion: @escaping (Error?) -> Void) throws -> Bool {
        let images = canonicalImages(files)
        guard !images.isEmpty else { throw BrowserFailure.message(L10n.text("请先选择照片。")) }
        if let active = session {
            if let app = NSRunningApplication(processIdentifier: active.process.processIdentifier) {
                NSApp.yieldActivation(to: app)
                app.activate(options: [])
            }
            if active.images == Set(images) { return false }
            throw BrowserFailure.message(L10n.text("Camera Raw 正在编辑其他照片，请先完成或取消。"))
        }
        let helperApp = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CameraRawHost.app")
        let helper = helperApp.appendingPathComponent("Contents/MacOS/CameraRawHost")
        guard FileManager.default.isExecutableFile(atPath: helper.path), let identifier = Bundle(url: helperApp)?.bundleIdentifier else {
            throw BrowserFailure.message(L10n.text("Camera Raw 组件缺失，请重新安装完整应用。"))
        }
        let plugin = try installedPlugin()
        for image in images where !FileManager.default.isReadableFile(atPath: image.path) {
            throw BrowserFailure.message(L10n.text("文件不存在：\(image.path)"))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoBrowser/CameraRawHost", isDirectory: true)
        let request = support.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: request, withIntermediateDirectories: true)
        let result = request.appendingPathComponent("result.json")
        let manifest = request.appendingPathComponent("request.json")
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "images": images.map(\.path)])
        try data.write(to: manifest, options: .atomic)
        let process = Process()
        process.executableURL = helper
        // A JSON manifest avoids shell escaping and command-line size limits for large selections.
        process.arguments = [plugin.path, manifest.path, result.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { ended in
            Task { @MainActor in
                guard session?.process === ended else { return }
                session = nil
                do {
                    try validateResult(at: result, exitCode: ended.terminationStatus,
                                       exitedNormally: ended.terminationReason == .exit)
                    completion(nil)
                } catch { completion(error) }
            }
        }
        session = Session(process: process, images: Set(images))
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: identifier)
        do { try process.run() }
        catch {
            session = nil
            throw error
        }
        return true
    }

    static func installedPlugin(in roots: [URL]? = nil) throws -> URL {
        let roots = roots ?? [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"),
                              URL(fileURLWithPath: "/Library")]
        for root in roots {
            let plugin = root.appendingPathComponent("Application Support/Adobe/Plug-Ins/CC/File Formats/Camera Raw.plugin")
            if Bundle(url: plugin)?.executableURL != nil { return plugin }
        }
        throw BrowserFailure.message(L10n.text("未找到 Adobe Camera Raw 插件，请先安装 Camera Raw。"))
    }

    static func validateResult(at url: URL, exitCode: Int32, exitedNormally: Bool) throws {
        let result = try? JSONDecoder().decode(HostResult.self, from: Data(contentsOf: url))
        guard exitedNormally, exitCode == 0, let result, result.version == 1,
              result.status == "closed", result.stage == "settings", result.editorOpened,
              [0, -128].contains(result.code) else {
            let detail = result.map { "\($0.stage): \($0.code)" } ?? "process: \(exitCode)"
            throw BrowserFailure.message(L10n.text("Camera Raw 未能正常完成编辑（\(detail)）。诊断文件：\(url.path)"))
        }
    }
}
