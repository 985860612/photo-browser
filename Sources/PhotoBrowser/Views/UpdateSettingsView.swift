import BrowserCore
import SwiftUI

struct UpdateSettingsView: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        Section {
            HStack {
                LabeledContent(L10n.text("当前版本"), value: updater.version)
                Button(L10n.text("检查更新…")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            Toggle(L10n.text("自动检查更新"), isOn: $updater.automaticallyChecksForUpdates)
                .disabled(!updater.isAvailable)
            Toggle(L10n.text("自动下载并安装更新"), isOn: $updater.automaticallyDownloadsUpdates)
                .disabled(!updater.isAvailable || !updater.allowsAutomaticUpdates)
        } header: { Label(L10n.text("软件更新"), systemImage: "arrow.down.circle") }
        footer: {
            let lastCheck = updater.lastUpdateCheckDate.map {
                L10n.text("上次检查：\($0.formatted(date: .abbreviated, time: .shortened))")
            }
            let summary = [updater.status, lastCheck].compactMap { $0 }.joined(separator: " · ")
            if !summary.isEmpty { Text(summary).textSelection(.enabled) }
        }
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("启动时及每隔 24 小时检查新版；自动下载的更新在退出时安装。"))
                Text(L10n.text("也可从更新提示立即安装并重新启动；文件操作完成前会等待。"))
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
