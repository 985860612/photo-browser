import SwiftUI
import AppKit
import BrowserCore

struct PreviewSettingsView: View {
    @EnvironmentObject private var store: BrowserStore
    @State private var confirmClear = false
    @State private var windowHeight: CGFloat = 660
    var body: some View {
        Form {
            Section {
                Stepper(value: $store.previewBefore, in: PreviewPreferences.range) {
                    HStack { Text(L10n.text("向前预加载")); Spacer(); Text(L10n.text("\(store.previewBefore) 张")).monospacedDigit() }
                }
                Stepper(value: $store.previewAfter, in: PreviewPreferences.range) {
                    HStack { Text(L10n.text("向后预加载")); Spacer(); Text(L10n.text("\(store.previewAfter) 张")).monospacedDigit() }
                }
                Stepper(value: $store.previewDecodeConcurrency, in: PreviewPreferences.concurrencyRange) {
                    LabeledContent(L10n.text("后台解码并发"), value: L10n.text("\(store.previewDecodeConcurrency) 路"))
                }
                Text(L10n.text("默认 4 路，可配置 1–8 路。修改立即生效并保存，正在解码的任务会继续完成。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("前后指当前浏览顺序；设为 0 可关闭该方向。修改立即生效，重开软件后保留。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("主窗口与全屏共用预加载范围，缓存受内存预算限制，当前照片优先。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("恢复默认（前 2 张，后 5 张，4 路）")) {
                    store.previewBefore = 2; store.previewAfter = 5; store.previewDecodeConcurrency = PreviewPreferences.defaultConcurrency
                }
            } header: { Label(L10n.text("预览缓存"), systemImage: "photo.stack") }
            Section {
                if let usage = store.diskUsage {
                    LabeledContent(L10n.text("磁盘占用"), value: ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))
                    LabeledContent(L10n.text("缓存图片"), value: String(usage.entries))
                }
                Stepper(value: $store.diskLimitGB, in: 1...20) {
                    LabeledContent(L10n.text("容量上限"), value: "\(store.diskLimitGB) GB")
                }.disabled(store.cacheBusy)
                if let usage = store.livePhotoDiskUsage {
                    LabeledContent(L10n.text("实况原图与视频缓存"), value: ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))
                    Text(L10n.text("实况缓存上限 1 GB，视频仅在播放时解包。清理时保留正在使用的视频。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.text("缩略图与视频封面按最近访问清理。不会清理原文件、分组、移动记录或播放位置。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("清理预览缓存…")) { confirmClear = true }.disabled(store.cacheBusy)
                if store.cacheBusy { ProgressView().controlSize(.small) }
                if let failure = store.cacheFailure { Text(failure).foregroundStyle(.orange).font(.caption) }
            } header: { Label(L10n.text("缓存空间"), systemImage: "internaldrive") }
            Section {
                LabeledContent(L10n.text("相邻大图就绪"), value: "\(store.adjacentReady)/\(store.adjacentTotal)")
                LabeledContent(L10n.text("相邻视频信息就绪"), value: "\(store.adjacentVideoReady)/\(store.adjacentVideoTotal)")
                if let stats = store.previewStatistics {
                    LabeledContent(L10n.text("大图内存占用"), value: ByteCountFormatter.string(fromByteCount: Int64(stats.bytes), countStyle: .memory))
                }
                LabeledContent(L10n.text("缓存命中 / 请求"), value: "\(store.diagnostics.hits)/\(store.diagnostics.requests)")
                if let sample = store.diagnostics.samples.last(where: { $0.cached != nil || $0.failed }) {
                    Text(URL(fileURLWithPath: sample.path).lastPathComponent).lineLimit(1).font(.caption).help(sample.path)
                    if sample.failed { Text(L10n.text("预览加载失败")).foregroundStyle(.orange) }
                    else {
                        LabeledContent(L10n.text("来源"), value: sample.cached == true ? L10n.text("内存缓存") : L10n.text("原图解码"))
                        timingRow("排队", sample.timing?.queue)
                        timingRow("读取", sample.timing?.source)
                        timingRow("解码", sample.timing?.decode)
                        timingRow("绘制", sample.render)
                    }
                }
                Text(L10n.text("读取为打开图像源的耗时；解码包含后续文件读取。绘制包含提交至 GPU 完成。统计保留本次运行最近 100 次请求。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("重置诊断统计")) { PreviewDiagnostics.shared.reset(); store.diagnostics = PreviewDiagnostics.shared.snapshot() }
            } header: { Label(L10n.text("预览诊断"), systemImage: "chart.bar") }
        }.formStyle(.grouped).padding(12).frame(width: 430, height: windowHeight)
            .background(SettingsWindowMarker(contentHeight: $windowHeight))
            .task {
                while !Task.isCancelled {
                    await store.updateCacheStatus(); await store.updateAdjacentReadiness()
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
            .onChange(of: store.diskLimitGB) { _, _ in Task { await store.applyDiskLimit() } }
            .confirmationDialog(L10n.text("清理本机预览缓存？"), isPresented: $confirmClear) {
                Button(L10n.text("清理缓存"), role: .destructive) { Task { await store.clearPreviewCaches() } }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: { Text(L10n.text("清理后按需重新生成缩略图，当前画面和视频播放不受影响。")) }
    }
    private func timingRow(_ key: String, _ value: Double?) -> some View {
        LabeledContent(L10n.lookup(key), value: value.map { String(format: "%.1f ms", $0) } ?? "—")
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
            let height = min(660, max(1, available.height - chromeHeight))
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
