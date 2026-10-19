import AppKit
import BrowserCore
import Combine
import Sparkle

@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isAvailable = false
    @Published private(set) var status: String?
    private var controller: SPUStandardUpdaterController?
    private var observations = Set<AnyCancellable>()
    private var started = false
    private var fileOperationInProgress: () -> Bool = { false }
    private var postponedInstall: Task<Void, Never>?

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }
    var allowsAutomaticUpdates: Bool { controller?.updater.allowsAutomaticUpdates ?? false }
    var lastUpdateCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    func start(fileOperationInProgress: @escaping () -> Bool) {
        guard !started else { return }
        started = true
        self.fileOperationInProgress = fileOperationInProgress
        if Bundle.main.object(forInfoDictionaryKey: "PhotoBrowserLocalPreview") as? Bool == true {
            status = L10n.text("本地预览版不检查更新。"); return
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            status = L10n.text("请使用打包后的应用检查更新。")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        // Sparkle owns and persists these preferences, including changes in its update dialog.
        for publisher in [
            updater.publisher(for: \.automaticallyChecksForUpdates).map { _ in () }.eraseToAnyPublisher(),
            updater.publisher(for: \.automaticallyDownloadsUpdates).map { _ in () }.eraseToAnyPublisher(),
            updater.publisher(for: \.allowsAutomaticUpdates).map { _ in () }.eraseToAnyPublisher(),
            updater.publisher(for: \.lastUpdateCheckDate).map { _ in () }.eraseToAnyPublisher()
        ] {
            publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        }
        do {
            try updater.start()
            isAvailable = true
            if updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
        } catch {
            status = L10n.text("更新启动失败：\(error.localizedDescription)")
        }
    }

    func checkForUpdates() {
        guard isAvailable, canCheckForUpdates else { return }
        status = nil
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = L10n.text("发现新版本：\(item.displayVersionString)")
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        if reason?.intValue == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue) || reason?.intValue == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) {
            status = L10n.text("当前已是最新版本。")
        } else { status = error.localizedDescription }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let error = error as NSError? else { return }
        if error.domain == SUSparkleErrorDomain,
           [Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)].contains(error.code) { return }
        status = L10n.text("检查更新失败：\(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeRelaunch(until: installHandler)
    }

    @discardableResult func postponeRelaunch(until installHandler: @escaping () -> Void) -> Bool {
        guard fileOperationInProgress() else { return false }
        status = L10n.text("文件操作完成后将安装更新并重新启动。")
        postponedInstall?.cancel()
        postponedInstall = Task { [weak self] in
            while let self, self.fileOperationInProgress() {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            guard self != nil, !Task.isCancelled else { return }
            installHandler()
        }
        return true
    }
}
