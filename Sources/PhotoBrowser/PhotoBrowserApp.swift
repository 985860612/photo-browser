import SwiftUI
import AppKit

@main struct PhotoBrowserApp: App {
    @StateObject private var store = BrowserStore()
    @NSApplicationDelegateAdaptor(BrowserDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("照片组浏览器") {
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
                Button("打开照片目录…") { store.chooseDirectory() }.keyboardShortcut("o")
                Button("刷新目录") { if let directory = store.directory { store.load(directory) } }.keyboardShortcut("r")
                    .disabled(store.isMoving || store.isLoading)
                Button("输入文件夹路径…") { store.editPath() }.keyboardShortcut("l").disabled(store.isMoving || store.isFullscreenPreview)
                Button("后退") { store.navigateHistory(-1) }.keyboardShortcut("[").disabled(!store.canGoBack)
                Button("前进") { store.navigateHistory(1) }.keyboardShortcut("]").disabled(!store.canGoForward)
                Button("上一级") { if let url = store.directory { store.load(url.deletingLastPathComponent()) } }
                    .keyboardShortcut(.upArrow).disabled(store.directory == nil || store.isMoving || store.isLoading)
            }
            CommandMenu("照片") {
                Button("上一张") { store.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("下一张") { store.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("向左扩展选择") { store.step(-1, extendingSelection: true) }.keyboardShortcut(.leftArrow, modifiers: [.shift])
                    .disabled(store.isMoving || store.isLoading || store.visibleAssets.isEmpty)
                Button("向右扩展选择") { store.step(1, extendingSelection: true) }.keyboardShortcut(.rightArrow, modifiers: [.shift])
                    .disabled(store.isMoving || store.isLoading || store.visibleAssets.isEmpty)
                Button("选择全部") { store.selectAll() }.keyboardShortcut("a")
                Divider()
                Button("全屏高清预览") { store.toggleFullscreenPreview() }.keyboardShortcut(.space, modifiers: [])
                    .disabled(store.focusedFile == nil || store.isMoving || store.isLoading)
                Button("切换网格 / 大图") { store.showGroupOverview.toggle() }.keyboardShortcut("j")
                Button("在 Camera Raw 中打开") { if let asset = store.focusedAsset { store.openInCameraRaw(asset) } }
                    .disabled(store.focusedAsset == nil || store.isMoving)
                Button("将所选照片组成一组") { store.createGroup() }.keyboardShortcut("g")
                    .disabled(store.selection.count < 2 || store.isMoving || store.isReadingMetadata)
                Button("在 Finder 显示") { store.revealFocused() }.keyboardShortcut("f", modifiers: [.command, .shift])
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
            guard let store = self?.store, !store.isMoving,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            if store.isFullscreenPreview, event.keyCode == 53 {
                store.closeFullscreenPreview(); return nil
            }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            if event.modifierFlags.contains(.shift), event.keyCode == 123 || event.keyCode == 124,
               !store.isLoading, !store.visibleAssets.isEmpty,
               NSApp.keyWindow?.attachedSheet == nil, NSApp.modalWindow == nil {
                store.step(event.keyCode == 123 ? -1 : 1, extendingSelection: true)
                return nil
            }
            if event.keyCode == 49, !store.isLoading, store.focusedFile != nil,
               NSApp.keyWindow?.attachedSheet == nil {
                store.toggleFullscreenPreview(); return nil
            }
            return event
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.isMoving == true {
            let alert = NSAlert()
            alert.messageText = "文件正在移动，请等待完成"
            alert.informativeText = "移动完成后即可退出。"; alert.addButton(withTitle: "继续等待"); alert.runModal()
            return .terminateCancel
        }
        store?.cancelMetadata()
        store?.cancelPreviewGeneration()
        return .terminateNow
    }
}
