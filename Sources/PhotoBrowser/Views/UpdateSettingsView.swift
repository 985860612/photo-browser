import BrowserCore
import SwiftUI

struct UpdateSettingsView: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        Section {
            LabeledContent(L10n.text("当前版本"), value: updater.version)
            Toggle(L10n.text("自动检查更新"), isOn: $updater.automaticallyChecksForUpdates)
                .disabled(!updater.isAvailable)
            Toggle(L10n.text("自动下载并安装更新"), isOn: $updater.automaticallyDownloadsUpdates)
                .disabled(!updater.isAvailable || !updater.allowsAutomaticUpdates)
            Text(L10n.text("启动时及每隔 24 小时检查新版。开启自动更新后，在后台下载并在退出时安装；也可立即安装并重新启动。"))
                .font(.caption).foregroundStyle(.secondary)
            Button(L10n.text("检查更新…")) { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            if let date = updater.lastUpdateCheckDate {
                LabeledContent(L10n.text("上次检查"), value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if let status = updater.status { Text(status).font(.caption).textSelection(.enabled) }
        } header: { Label(L10n.text("软件更新"), systemImage: "arrow.down.circle") }
    }
}
