import SwiftUI
import AppKit
import BrowserCore

struct PreviewSettingsView: View {
    @EnvironmentObject private var store: BrowserStore
    @State private var selectedTab: SettingsTab = .browsing
    @State private var windowHeight: CGFloat = 540

    private enum SettingsTab { case browsing, cache, diagnostics, updates }

    var body: some View {
        TabView(selection: $selectedTab) {
            settingsForm { browsingSections }
                .tabItem { Label(L10n.text("浏览"), systemImage: "photo") }.tag(SettingsTab.browsing)
            settingsForm { CacheSettingsView() }
                .tabItem { Label(L10n.text("缓存"), systemImage: "internaldrive") }.tag(SettingsTab.cache)
            settingsForm { PreviewDiagnosticsSettingsView() }
                .tabItem { Label(L10n.text("诊断"), systemImage: "chart.bar") }.tag(SettingsTab.diagnostics)
            settingsForm { UpdateSettingsView() }
                .tabItem { Label(L10n.text("更新"), systemImage: "arrow.down.circle") }.tag(SettingsTab.updates)
        }
        .frame(width: 560, height: windowHeight)
        .background(SettingsWindowMarker(contentHeight: $windowHeight))
        .task(id: selectedTab) {
            guard selectedTab == .cache || selectedTab == .diagnostics else { return }
            while !Task.isCancelled {
                await store.updateCacheStatus()
                if selectedTab == .diagnostics { await store.updateAdjacentReadiness() }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onChange(of: store.diskLimitGB) { _, _ in Task { await store.applyDiskLimit() } }
    }

    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Form(content: content).formStyle(.grouped).scrollBounceBehavior(.basedOnSize)
            if selectedTab == .browsing || selectedTab == .cache {
                Text(L10n.text("更改立即生效并自动保存。"))
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder private var browsingSections: some View {
        Section {
            Picker(L10n.text("未识别时优先使用"), selection: $store.preferredCoordinateSystem) {
                ForEach(PhotoCoordinateSystem.allCases, id: \.self) { system in
                    Text(system.label).tag(system)
                }
            }
        } header: { Label(L10n.text("照片坐标系"), systemImage: "globe") }
        footer: { Text(L10n.text("照片中的坐标系标记优先；无法识别时使用此设置。")) }
        Section {
            Stepper(value: $store.previewBefore, in: PreviewPreferences.range) {
                HStack { Text(L10n.text("向前预加载")); Spacer(); Text(L10n.text("\(store.previewBefore) 张")).monospacedDigit() }
            }
            Stepper(value: $store.previewAfter, in: PreviewPreferences.range) {
                HStack { Text(L10n.text("向后预加载")); Spacer(); Text(L10n.text("\(store.previewAfter) 张")).monospacedDigit() }
            }
            Stepper(value: $store.previewDecodeConcurrency, in: PreviewPreferences.concurrencyRange) {
                HStack { Text(L10n.text("后台解码并发")); Spacer(); Text(L10n.text("\(store.previewDecodeConcurrency) 路")).monospacedDigit() }
            }
            Button(L10n.text("恢复默认（前 2 张，后 5 张，4 路）")) {
                store.previewBefore = 2; store.previewAfter = 5; store.previewDecodeConcurrency = PreviewPreferences.defaultConcurrency
            }
        } header: { Label(L10n.text("预览缓存"), systemImage: "photo.stack") }
        footer: { Text(L10n.text("按当前浏览顺序预加载；设为 0 可关闭该方向。")) }
        Section {
            DisclosureGroup(L10n.text("了解更多")) {
                Text(L10n.text("主窗口与全屏共用预加载范围，缓存受内存预算限制，当前照片优先。"))
                Text(L10n.text("解码默认 4 路，范围 1–8 路；调整后，正在解码的任务会继续完成。"))
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SettingsWindowMarker: NSViewRepresentable {
    @Binding var contentHeight: CGFloat
    func makeNSView(context: Context) -> SettingsMarkerView {
        let view = SettingsMarkerView()
        view.contentHeight = $contentHeight
        return view
    }
    func updateNSView(_ view: SettingsMarkerView, context: Context) { view.contentHeight = $contentHeight }
}
private final class SettingsMarkerView: NSView {
    var contentHeight: Binding<CGFloat>?
    private var needsPlacement = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier("PhotoBrowser.Settings")
        needsPlacement = true
        NotificationCenter.default.addObserver(self, selector: #selector(placeOnOpen),
            name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(prepareForNextOpen),
            name: NSWindow.willCloseNotification, object: window)
        placeOnOpen()
    }

    @objc private func prepareForNextOpen() { needsPlacement = true }

    @objc private func placeOnOpen() {
        // SwiftUI finishes restoring and sizing its Settings window after attachment.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible, self.needsPlacement else { return }
            self.needsPlacement = false
            let browser = NSApp.orderedWindows.first {
                $0 !== window && $0.isVisible && $0.frameAutosaveName == "PhotoBrowser.MainWindow"
            }
            guard let screen = browser?.screen ?? window.screen ?? NSScreen.main else { return }
            let available = screen.visibleFrame.insetBy(dx: 16, dy: 16)
            let chromeHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
            let height = min(540, max(1, available.height - chromeHeight))
            self.contentHeight?.wrappedValue = height
            let size = NSSize(width: window.frame.width, height: height + chromeHeight)
            let anchor = browser?.frame ?? available
            let frame = NSRect(
                x: min(max(anchor.midX - size.width / 2, available.minX), available.maxX - size.width),
                y: min(max(anchor.midY - size.height / 2, available.minY), available.maxY - size.height),
                width: size.width, height: size.height)
            // Apply after the new SwiftUI content height has reached the hosting view.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, window.isVisible else { return }
                window.setFrame(frame, display: true)
            }
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
