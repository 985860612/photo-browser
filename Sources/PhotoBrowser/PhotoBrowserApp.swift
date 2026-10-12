import BrowserCore
import SwiftUI
import AppKit

@main struct PhotoBrowserApp: App {
    @StateObject private var store = BrowserStore()
    @NSApplicationDelegateAdaptor(BrowserDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(Text(L10n.text("照片浏览器"))) {
            Group {
                if store.isFullscreenPreview { FullscreenPreview() }
                else { BrowserView() }
            }.environmentObject(store)
                .frame(minWidth: 1080, minHeight: 700)
                .preferredColorScheme(.dark)
                .task { store.start(); delegate.store = store }
        }
        .defaultSize(width: 1440, height: 940)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("打开照片目录…")) { store.chooseDirectory() }.keyboardShortcut("o")
                Button(L10n.text("刷新目录")) { if let directory = store.directory { store.load(directory) } }.keyboardShortcut("r")
                    .disabled(store.isMoving || store.isLoading)
                Button(L10n.text("输入文件夹路径…")) { store.editPath() }.keyboardShortcut("l").disabled(store.isMoving || store.isFullscreenPreview)
                Button(L10n.text("后退")) { store.navigateHistory(-1) }.keyboardShortcut("[").disabled(!store.canGoBack)
                Button(L10n.text("前进")) { store.navigateHistory(1) }.keyboardShortcut("]").disabled(!store.canGoForward)
                Button(L10n.text("上一级")) { if let url = store.directory { store.load(url.deletingLastPathComponent()) } }
                    .keyboardShortcut(.upArrow).disabled(store.directory == nil || store.isMoving || store.isLoading)
            }
            CommandMenu(L10n.text("照片")) {
                Button(L10n.text("上一项")) { store.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button(L10n.text("下一项")) { store.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button(L10n.text("向左扩展选择")) { store.step(-1, extendingSelection: true) }.keyboardShortcut(.leftArrow, modifiers: [.shift])
                    .disabled(store.isMoving || store.isLoading || store.visibleAssets.isEmpty)
                Button(L10n.text("向右扩展选择")) { store.step(1, extendingSelection: true) }.keyboardShortcut(.rightArrow, modifiers: [.shift])
                    .disabled(store.isMoving || store.isLoading || store.visibleAssets.isEmpty)
                Button(L10n.text("选择全部")) { store.selectAll() }.keyboardShortcut("a")
                Button(L10n.text("移到 _del 待删除目录")) { store.deleteSelection() }
                    .disabled(!store.canDeleteSelection).help(L10n.text("⌫ / Delete：将所选照片及配套文件移到 _del，可撤销"))
                Divider()
                Button(L10n.text("全屏高清预览")) { store.toggleFullscreenPreview() }.keyboardShortcut(.space, modifiers: [])
                    .disabled(store.focusedFile == nil || store.selectedFolderID != nil || store.isMoving || store.isLoading)
                Button(L10n.text("切换网格 / 大图")) { store.showGroupOverview.toggle() }.keyboardShortcut("j")
                Button(L10n.text("在 Camera Raw 中打开")) { if let asset = store.focusedAsset { store.openInCameraRaw(asset) } }
                    .disabled(store.focusedAsset == nil || store.isMoving)
                Button(L10n.text("将所选照片组成一组")) { store.createGroup() }.keyboardShortcut("g")
                    .disabled(store.selection.count < 2 || store.isMoving || store.isReadingMetadata)
                Button(L10n.text("在 Finder 显示")) { store.revealFocused() }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor final class BrowserDelegate: NSObject, NSApplicationDelegate {
    weak var store: BrowserStore?
    private var keyMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let store = self?.store else { return event }
            return store.handleKeyDown(event, in: NSApp.keyWindow)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.isMoving == true {
            let alert = NSAlert()
            alert.messageText = L10n.text("文件正在移动，请等待完成")
            alert.informativeText = L10n.text("移动完成后即可退出。"); alert.addButton(withTitle: L10n.text("继续等待")); alert.runModal()
            return .terminateCancel
        }
        store?.cancelMetadata()
        store?.cancelPreviewGeneration()
        return .terminateNow
    }
}
