import AppKit
import Sparkle

/// Exercises Sparkle's real feed parser, download validation, extraction and installer in disposable app bundles.
@MainActor final class UpdateProbe: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    var updater: SPUUpdater?
    private var expected: String {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--expect") else { return "found" }
        return args[index + 1]
    }
    private func finish(_ result: String) {
        if let index = CommandLine.arguments.firstIndex(of: "--result") {
            try! Data(result.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        print("\(result == expected ? "PASS" : "FAIL"): update probe: \(result), expected \(expected)")
        fflush(stdout)
        exit(result == expected ? 0 : 1)
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        print("Probe found update: \(appcastItem.versionString), expected \(expected)")
        fflush(stdout)
        if expected == "found" { finish("found") }
        else { reply(.install) }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { finish("release-notes-error") }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        finish("current")
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        finishError(error)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.install) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement(); finish(relaunched ? "installed" : "not-relaunched")
    }
    func dismissUpdateInstallation() {}
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Automatic feed signature errors may never reach the user driver.
        if expected == "signature-error" { finishError(error) }
    }
    private func finishError(_ error: Error) {
        var details = "", current: NSError? = error as NSError, signatureFailure = false
        while let value = current {
            details += "\(value.domain):\(value.code):\(value.localizedDescription) \(value.localizedFailureReason ?? "")\n"
            if value.domain == SUSparkleErrorDomain,
               [Int(SUError.validationError.rawValue), Int(SUError.signatureError.rawValue)].contains(value.code) { signatureFailure = true }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        print(details)
        finish(signatureFailure ? "signature-error" : "other-error")
    }
}
