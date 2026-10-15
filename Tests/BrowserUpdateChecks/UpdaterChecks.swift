import AppKit
import BrowserCore
import CryptoKit
import Sparkle

@main struct UpdaterChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2",
           let marker = Bundle.main.object(forInfoDictionaryKey: "UpdateTestRelaunchMarker") as? String {
            try Data(Bundle.main.bundlePath.utf8).write(to: URL(fileURLWithPath: marker))
            return
        }
        if let index = args.firstIndex(of: "--generate-test-key") {
            let key = Curve25519.Signing.PrivateKey()
            try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: URL(fileURLWithPath: args[index + 1]))
            print(key.publicKey.rawRepresentation.base64EncodedString())
            return
        }
        if args.contains("--probe") {
            print("Probe starting: \(Bundle.main.bundlePath), version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "nil")")
            fflush(stdout)
            let driver = UpdateProbe()
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
            driver.updater = updater
            try updater.start()
            if args.contains("automatic") { updater.checkForUpdatesInBackground() }
            else { updater.checkForUpdates() }
            // The driver exits with the result; keep the app event loop alive for Sparkle's helpers.
            NSApp.run()
            print("Probe event loop ended without a result")
            fflush(stdout)
            exit(1)
        }
        let model = AppUpdater()
        var moving = true
        model.start { moving }
        if Bundle.main.bundleURL.pathExtension != "app" {
            try require(!model.isAvailable && !model.canCheckForUpdates && model.status != nil, "Source launch must explain why updating is unavailable")
            print("PASS: source launch does not start an updater")
            return
        }
        try require(model.isAvailable, "Packaged updater failed to start: \(model.status ?? "unknown")")
        try require(!model.automaticallyChecksForUpdates, "Test app must have scheduled checks disabled")
        model.automaticallyChecksForUpdates = true
        try require(model.automaticallyChecksForUpdates && UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks"), "Automatic checks were not persisted")
        model.automaticallyDownloadsUpdates = true
        try require(model.automaticallyDownloadsUpdates && UserDefaults.standard.bool(forKey: "SUAutomaticallyUpdate"), "Automatic downloads were not persisted")
        model.automaticallyChecksForUpdates = false
        model.automaticallyDownloadsUpdates = false
        var installed = false
        try require(model.postponeRelaunch { installed = true }, "File operations did not postpone the update")
        try await Task.sleep(for: .milliseconds(350))
        try require(!installed, "Installer ran during file operations")
        moving = false
        try await Task.sleep(for: .milliseconds(400))
        try require(installed, "Installer did not resume after file operations")
        try require(!model.postponeRelaunch {}, "Idle app should not postpone the update")
        print("PASS: packaged updater starts, preferences persist, and restart waits for file operations")
    }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "UpdaterChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
