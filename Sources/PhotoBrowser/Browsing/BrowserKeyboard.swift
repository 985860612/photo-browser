import AppKit
import SwiftUI
import BrowserCore

extension BrowserStore {
    func handleKeyDown(_ event: NSEvent, in window: NSWindow?) -> NSEvent? {
        guard !isMoving else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if isFullscreenPreview, event.keyCode == 53, modifiers.intersection([.command, .control, .option]).isEmpty { closeFullscreenPreview(); return nil }
        guard let window, !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
              window.identifier?.rawValue != "PhotoBrowser.Settings",
              !isLoading, window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
        if event.keyCode == 8, modifiers == .command, canCopyFiles {
            copyFilesToClipboard(); return nil
        }
        if event.keyCode == 8, modifiers == [.command, .shift], selectedFolderID == nil, focusedFile != nil, focusedFile?.kind != .video {
            if !event.isARepeat { copyImageToClipboard() }
            return nil
        }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return event }
        if event.keyCode == 51 || event.keyCode == 117 {
            // Holding Delete must not remove the next automatically selected photo.
            if !event.isARepeat { deleteSelection() }
            return nil
        }
        if event.keyCode == 123 || event.keyCode == 124 {
            step(event.keyCode == 123 ? -1 : 1, extendingSelection: event.modifierFlags.contains(.shift))
            return nil
        }
        if (event.keyCode == 36 || event.keyCode == 76), selectedFolderID != nil {
            openSelectedFolder(); return nil
        }
        if event.keyCode == 49, focusedFile != nil, selectedFolderID == nil {
            if focusedFile?.kind == .video { if !event.isARepeat { toggleVideoPlayback() }; return nil }
            toggleFullscreenPreview(); return nil
        }
        return event
    }

}
