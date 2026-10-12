import AppKit
import BrowserCore

@MainActor enum CameraRawLauncher {
    static func open(_ file: PhotoFile, completion: @escaping (Error?) -> Void) throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.Photoshop") else {
            throw BrowserFailure.message(L10n.text("未找到 Photoshop。请先安装 Photoshop 和 Camera Raw 插件。"))
        }
        if file.kind == .raw {
            launch(file.url, with: app, completion: completion)
            return
        }
        // A JSX document asks Photoshop to show the actual Camera Raw open dialog for all formats.
        // Opening a JPEG normally would follow Photoshop's preferences and could bypass Camera Raw.
        let encoded = try JSONSerialization.data(withJSONObject: [file.url.path], options: [.fragmentsAllowed])
        let pathExpression = String(decoding: encoded, as: UTF8.self) + "[0]"
        let errorText = try JSONSerialization.data(withJSONObject: L10n.text("无法在 Camera Raw 中打开照片："), options: [.fragmentsAllowed])
        let errorExpression = String(decoding: errorText, as: UTF8.self)
        let script = """
        #target photoshop
        app.bringToFront();
        try {
            var descriptor = new ActionDescriptor();
            descriptor.putPath(charIDToTypeID("null"), File(\(pathExpression)));
            descriptor.putObject(charIDToTypeID("As  "), stringIDToTypeID("Adobe Camera Raw"), new ActionDescriptor());
            executeAction(charIDToTypeID("Opn "), descriptor, DialogModes.ALL);
        } catch (error) {
            if (error.number != 8007) alert(\(errorExpression) + error.message);
        }
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
