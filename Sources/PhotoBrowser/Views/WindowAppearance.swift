import SwiftUI
import AppKit

/// A restrained glass background keeps contrast stable against bright desktops.
struct GlassBackdrop: View {
    var body: some View {
        ZStack {
            GlassMaterial()
            Color(red: 0.08, green: 0.09, blue: 0.105).opacity(0.78)
        }
    }
}

struct GlassMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowGlassView {
        let view = WindowGlassView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: WindowGlassView, context: Context) {}
}

final class WindowGlassView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false
        window?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.92)
        window?.appearance = NSAppearance(named: .darkAqua)
        window?.titlebarAppearsTransparent = true
        window?.toolbarStyle = .unified
        if let window, window.frameAutosaveName.isEmpty {
            window.setFrameUsingName("PhotoBrowser.MainWindow")
            window.setFrameAutosaveName("PhotoBrowser.MainWindow")
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct GlassDivider: View {
    var inset: CGFloat = 15
    var body: some View {
        Capsule().fill(Color.white.opacity(0.07)).frame(height: 0.5)
            .padding(.horizontal, inset)
    }
}
