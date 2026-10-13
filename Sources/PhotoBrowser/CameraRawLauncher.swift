import AppKit
import BrowserCore

@MainActor enum CameraRawLauncher {
    static func open(_ file: PhotoFile, completion: @escaping (Error?) -> Void) throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.bridge") else {
            throw BrowserFailure.message(L10n.text("未找到 Adobe Bridge。请先安装 Bridge 并启用 Camera Raw。"))
        }
        // Bridge's loaded thumbnails use canonical paths (e.g. /private/tmp rather than /tmp).
        let resolved = file.url.withUnsafeFileSystemRepresentation { path in realpath(path, nil) }
        guard let resolved else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(resolved) }
        let messages = [String(cString: resolved),
                        L10n.text("无法在 Camera Raw 中打开照片："),
                        L10n.text("Bridge 未能打开 Camera Raw。请确认 Camera Raw 已启用且支持此照片格式。")]
        let encoded = try JSONSerialization.data(withJSONObject: messages)
        // ExtendScript may interpret UTF-8 JSX files as the legacy system encoding.
        // ASCII JSON with escaped UTF-16 units preserves all paths and localized messages.
        let arguments = String(decoding: encoded, as: UTF8.self).utf16.map { unit in
            unit <= 127 ? String(UnicodeScalar(unit)!) : String(format: "\\u%04x", unit)
        }.joined()
        let request = "photoBrowserCameraRaw_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let script = """
        #target bridge
        (function (args) {
            var key = "\(request)", task, doc, file = new File(args[0]);
            var deadline = new Date().getTime() + 30000;
            function cleanup() {
                if (task !== undefined) app.cancelTask(task);
                delete $.global[key];
            }
            function fail(error) {
                cleanup();
                alert(args[1] + error.message);
            }
            try {
                if (!file.exists) throw new Error(args[0]);
                doc = app.document;
                app.bringToFront();
                doc.bringToFront();
                if (doc.thumbnail.spec.fsName != file.parent.fsName)
                    doc.thumbnail = new Thumbnail(file.parent);
                $.global[key] = function () {
                    try {
                        if (new Date().getTime() >= deadline) throw new Error(args[2]);
                        var selected = doc.getSelection();
                        var menu = MenuElement.find("OpenInCameraRaw");
                        if (!menu) throw new Error(args[2]);
                        if (selected.length == 1 && selected[0].spec.fsName == file.fsName) {
                            cleanup();
                            // Refresh Bridge's command context immediately before dispatch.
                            doc.deselectAll();
                            doc.select(selected[0]);
                            doc.chooseMenuItem("OpenInCameraRaw");
                            return;
                        }
                        var children = doc.thumbnail.children;
                        for (var i = 0; i < children.length; i++) {
                            if (children[i].spec.fsName == file.fsName) {
                                doc.deselectAll();
                                doc.select(children[i]);
                                return;
                            }
                        }
                    } catch (error) { fail(error); }
                };
                task = app.scheduleTask('$.global["' + key + '"]()', 200, true);
            } catch (error) { fail(error); }
        })(\(arguments));
        """
        let scripts = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoBrowser/CameraRaw", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let url = scripts.appendingPathComponent(UUID().uuidString + ".jsx")
        try Data(script.utf8).write(to: url, options: .atomic)
        launch(url, with: app, completion: completion)
    }
    private static func launch(_ url: URL, with app: URL, completion: @escaping (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
            Task { @MainActor in completion(error) }
        }
    }
}
