import BrowserCore
import SwiftUI
import AppKit

@main struct PhotoBrowserApp: App {
    @StateObject private var store = BrowserStore()
    @StateObject private var updater = AppUpdater()
    @StateObject private var ai = AIBrowseStore()
    @NSApplicationDelegateAdaptor(BrowserDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(Text(L10n.text("照片浏览器"))) {
            BrowsingWorkspaceView().environmentObject(store).environmentObject(ai)
                .frame(minWidth: 1080, minHeight: 700)
                .preferredColorScheme(.dark)
                .task {
                    store.start(); delegate.store = store; delegate.ai = ai
                    if CommandLine.arguments.contains("--ai-categories") { ai.activate(directory: store.directory) }
                    updater.start { [weak store] in store?.isMoving == true || store?.isExportingLivePhotoVideo == true || store?.isOperatingDiskImage == true }
                }
        }
        .defaultSize(width: 1440, height: 940)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.text("检查更新…")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Group {
                Button(L10n.text("打开照片目录…")) { if ai.active { ai.chooseRoot() } else { store.chooseDirectory() } }.keyboardShortcut("o")
                Button(L10n.text("刷新目录")) { if ai.active { ai.synchronize() } else { store.refreshDirectory() } }.keyboardShortcut("r")
                    .disabled(ai.active ? ai.syncing : (store.isMoving || store.isLoading))
                Button(L10n.text("输入文件夹路径…")) { store.editPath() }.keyboardShortcut("l").disabled(ai.active || store.isMoving || store.isFullscreenPreview)
                Button(L10n.text("后退")) { store.navigateHistory(-1) }.keyboardShortcut("[").disabled(ai.active || !store.canGoBack)
                Button(L10n.text("前进")) { store.navigateHistory(1) }.keyboardShortcut("]").disabled(ai.active || !store.canGoForward)
                Button(L10n.text("上一级")) { store.goUp() }
                    .keyboardShortcut(.upArrow).disabled(ai.active || store.directory == nil || store.isMoving || store.isLoading)
                }.disabled(ai.similarityPresented)
            }
            CommandMenu(L10n.text("照片")) {
                Group {
                Button(L10n.text("上一项")) { if ai.active { ai.step(-1) } else { store.step(-1) } }.keyboardShortcut(.leftArrow, modifiers: [])
                Button(L10n.text("下一项")) { if ai.active { ai.step(1) } else { store.step(1) } }.keyboardShortcut(.rightArrow, modifiers: [])
                Button(L10n.text("向左扩展选择")) { if ai.active { ai.step(-1, extending: true) } else { store.step(-1, extendingSelection: true) } }.keyboardShortcut(.leftArrow, modifiers: [.shift])
                    .disabled(ai.active ? ai.items.isEmpty : (store.isMoving || store.isLoading || store.visibleAssets.isEmpty))
                Button(L10n.text("向右扩展选择")) { if ai.active { ai.step(1, extending: true) } else { store.step(1, extendingSelection: true) } }.keyboardShortcut(.rightArrow, modifiers: [.shift])
                    .disabled(ai.active ? ai.items.isEmpty : (store.isMoving || store.isLoading || store.visibleAssets.isEmpty))
                Button(L10n.text(ai.active ? "选择已载入照片" : "选择全部")) { if ai.active { ai.selection = Set(ai.items.map(\.id)) } else { store.selectAll() } }.keyboardShortcut("a")
                Button(L10n.text("移到 _del 待删除目录")) { store.deleteSelection() }
                    .disabled(ai.active || !store.canDeleteSelection).help(L10n.text("⌫ / Delete：将所选照片及配套文件移到 _del，可撤销"))
                Divider()
                if !ai.active && store.playbackFile != nil {
                    Button(L10n.text("播放 / 暂停")) { store.toggleVideoPlayback() }.keyboardShortcut(.space, modifiers: [])
                        .disabled(store.selectedFolderID != nil || store.isMoving || store.isLoading)
                    Button(L10n.text("全屏播放")) { store.toggleFullscreenPreview() }.keyboardShortcut("f", modifiers: [.command, .control])
                        .disabled(store.selectedFolderID != nil || store.isMoving || store.isLoading)
                } else { Button(L10n.text("全屏高清预览")) { if ai.active { ai.fullscreen.toggle() } else { store.toggleFullscreenPreview() } }.keyboardShortcut(.space, modifiers: [])
                    .disabled(ai.active ? ai.selected == nil : (store.focusedFile == nil || store.selectedFolderID != nil || store.isMoving || store.isLoading))
                }
                Button(L10n.text("切换网格 / 大图")) { if ai.active { ai.large.toggle() } else { store.showGroupOverview.toggle() } }.keyboardShortcut("j")
                Button(L10n.text("在 Camera Raw 中打开")) { if let asset = store.focusedAsset { store.openInCameraRaw(asset) } }
                    .disabled(ai.active || store.focusedAsset == nil || store.focusedAsset?.isVideo == true || store.focusedAsset?.isLivePhoto == true || store.isMoving || store.isReadOnlyDirectory)
                Button(L10n.text("将所选照片组成一组")) { store.createGroup() }.keyboardShortcut("g")
                    .disabled(ai.active || store.selection.count < 2 || store.isMoving || store.isReadingMetadata)
                Button(L10n.text("在 Finder 显示")) { if ai.active { ai.reveal() } else { store.revealFocused() } }.keyboardShortcut("f", modifiers: [.command, .shift])
                }.disabled(ai.similarityPresented)
            }
        }
        Settings {
            PreviewSettingsView().environmentObject(store).environmentObject(updater)
        }
    }
}

@MainActor final class BrowserDelegate: NSObject, NSApplicationDelegate {
    weak var store: BrowserStore?
    weak var ai: AIBrowseStore?
    private var keyMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let store = self?.store else { return event }
            if let ai = self?.ai, ai.active { return ai.handleKeyDown(event, in: NSApp.keyWindow) }
            return store.handleKeyDown(event, in: NSApp.keyWindow)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidBecomeActive(_ notification: Notification) { store?.scheduleAutomaticRefresh(full: true) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.isMoving == true || store?.isExportingLivePhotoVideo == true || store?.isOperatingDiskImage == true || store?.isCopyingImage == true {
            let alert = NSAlert()
            alert.messageText = L10n.text("文件操作正在进行，请等待完成")
            alert.informativeText = L10n.text("文件操作完成后即可退出。"); alert.addButton(withTitle: L10n.text("继续等待")); alert.runModal()
            return .terminateCancel
        }
        ai?.persist()
        store?.cancelMetadata()
        store?.stopDirectoryObservation()
        store?.cancelPreviewGeneration()
        store?.video.stop()
        do { try store?.thumbnails.persistAccesses() }
        catch {
            let alert = NSAlert(); alert.messageText = L10n.text("缓存更新失败：\(error.localizedDescription)")
            alert.addButton(withTitle: L10n.text("知道了")); alert.runModal()
        }
        guard let store, !store.mountedDiskImages.isEmpty else { return .terminateNow }
        let fallback = store.activeDiskImage?.source.deletingLastPathComponent()
        Task {
            do {
                try await store.ejectDiskImagesForTermination()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = L10n.text("镜像推出失败，请关闭正在使用镜像的程序后重试。")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L10n.text("知道了")); alert.runModal()
                if let fallback, store.activeDiskImage == nil { store.load(fallback) }
                else if let directory = store.directory { store.load(directory, recordNavigation: false) }
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
