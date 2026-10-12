import SwiftUI
import AppKit
import BrowserCore

struct PreviewSettingsView: View {
    @EnvironmentObject private var store: BrowserStore
    var body: some View {
        Form {
            Section {
                Stepper(value: $store.previewBefore, in: PreviewPreferences.range) {
                    HStack { Text(L10n.text("向前预加载")); Spacer(); Text(L10n.text("\(store.previewBefore) 张")).monospacedDigit() }
                }
                Stepper(value: $store.previewAfter, in: PreviewPreferences.range) {
                    HStack { Text(L10n.text("向后预加载")); Spacer(); Text(L10n.text("\(store.previewAfter) 张")).monospacedDigit() }
                }
                Text(L10n.text("前后指当前浏览顺序；设为 0 可关闭该方向。修改立即生效，重开软件后保留。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("主窗口与全屏共用预加载范围，缓存受内存预算限制，当前照片优先。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("恢复默认（前 2 张，后 5 张）")) { store.previewBefore = 2; store.previewAfter = 5 }
            } header: { Label(L10n.text("预览缓存"), systemImage: "photo.stack") }
        }.formStyle(.grouped).padding(12).frame(width: 430)
            .background(SettingsWindowMarker())
    }
}

private struct SettingsWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsMarkerView { SettingsMarkerView() }
    func updateNSView(_ view: SettingsMarkerView, context: Context) {}
}
private final class SettingsMarkerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = NSUserInterfaceItemIdentifier("PhotoBrowser.Settings")
    }
}
