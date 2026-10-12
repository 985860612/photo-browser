import AppKit
import SwiftUI
import MetalKit
import CoreImage
import BrowserCore

struct PhotoCanvas: NSViewRepresentable {
    let photo: DisplayPhoto
    let identity: String
    let hdr: Bool
    @Binding var zoom: Double
    @Binding var fitScale: Double
    var report: (String) -> Void

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView()
        configure(view)
        return view
    }
    func updateNSView(_ view: CanvasView, context: Context) { configure(view) }
    private func configure(_ view: CanvasView) {
        view.onZoom = { zoom = $0 }
        view.onFitScale = { fitScale = $0 }
        view.onFailure = report
        view.configure(photo: photo, identity: identity, hdr: hdr, zoom: zoom)
    }
}

@MainActor final class CanvasView: MTKView, MTKViewDelegate {
    private var ciContext: CIContext?
    private var queue: MTLCommandQueue?
    private let outputSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    private var photo: DisplayPhoto?
    private var identity = ""
    private var hdr = true
    private var zoom: Double = 1
    private var pan = CGPoint.zero
    private var dragPoint: CGPoint?
    private var screenObserver: NSObjectProtocol?
    private var lastReportedFit: Double = 0
    var onZoom: ((Double) -> Void)?
    var onFitScale: ((Double) -> Void)?
    var onFailure: ((String) -> Void)?

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .rgba16Float; framebufferOnly = false
        isPaused = true; enableSetNeedsDisplay = true; autoResizeDrawable = true
        delegate = self
        if let device {
            ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: outputSpace, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
            queue = device.makeCommandQueue()
        }
        (layer as? CAMetalLayer)?.colorspace = outputSpace
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.needsDisplay = true }
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsDisplay = true }

    func configure(photo: DisplayPhoto, identity: String, hdr: Bool, zoom: Double) {
        if self.identity != identity { pan = .zero; self.identity = identity }
        self.photo = photo; self.hdr = hdr; self.zoom = zoom
        reportFit()
        if zoom == 1 { pan = .zero }
        (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = hdr && photo.isHDR
        if device == nil { DispatchQueue.main.async { [weak self] in self?.onFailure?("当前 Mac 无法建立 Metal 预览，请检查图形设备。") } }
        needsDisplay = true
    }
    private var fit: Double {
        guard let photo, photo.size.width > 0, photo.size.height > 0 else { return 1 }
        return max(0.0001, min(bounds.width / photo.size.width, bounds.height / photo.size.height))
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        reportFit()
    }
    private func reportFit() {
        let value = fit
        guard abs(value - lastReportedFit) > 0.000001 else { return }
        lastReportedFit = value
        DispatchQueue.main.async { [weak self] in self?.onFitScale?(value) }
    }
    func draw(in view: MTKView) {
        guard bounds.width > 0, bounds.height > 0, let photo, let ciContext,
              let drawable = currentDrawable, let command = queue?.makeCommandBuffer() else { return }
        var image = photo.image
        if #available(macOS 15, *), photo.isHDR {
            let target = hdr ? max(1, window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1) : 1
            if let mapped = CIFilter(name: "CIToneMapHeadroom", parameters: [kCIInputImageKey: image, "inputSourceHeadroom": photo.headroom, "inputTargetHeadroom": Float(target)])?.outputImage { image = mapped }
        }
        let backing = drawableSize.width / bounds.width
        let scale = fit * zoom * backing
        let x = (drawableSize.width - photo.size.width * scale) / 2 + pan.x * backing
        let y = (drawableSize.height - photo.size.height * scale) / 2 + pan.y * backing
        let viewport = CGRect(origin: .zero, size: drawableSize)
        let placed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
        let background = CIImage(color: .black).cropped(to: viewport)
        let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: command)
        destination.colorSpace = outputSpace
        destination.isFlipped = true
        do { _ = try ciContext.startTask(toRender: placed.composited(over: background), to: destination) }
        catch { DispatchQueue.main.async { [weak self] in self?.onFailure?(error.localizedDescription) }; return }
        command.present(drawable); command.commit()
    }
    private func changeZoom(_ value: Double, at anchor: CGPoint) {
        let new = min(10, max(0.1, value)), ratio = new / zoom
        let centered = CGPoint(x: anchor.x - bounds.midX, y: anchor.y - bounds.midY)
        pan = CGPoint(x: centered.x - (centered.x - pan.x) * ratio, y: centered.y - (centered.y - pan.y) * ratio)
        zoom = new; onZoom?(new); needsDisplay = true
    }
    override func magnify(with event: NSEvent) { changeZoom(zoom * max(0.1, 1 + event.magnification), at: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            changeZoom(zoom * exp(event.scrollingDeltaY * 0.015), at: convert(event.locationInWindow, from: nil))
        } else {
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 14
            pan.x += event.scrollingDeltaX * multiplier; pan.y += event.scrollingDeltaY * multiplier
            needsDisplay = true
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            let pixelZoom = min(10, max(0.1, 1 / (fit * (window?.backingScaleFactor ?? 2))))
            changeZoom(abs(zoom - 1) < 0.001 ? pixelZoom : 1, at: convert(event.locationInWindow, from: nil))
            if zoom == 1 { pan = .zero }; return
        }
        dragPoint = convert(event.locationInWindow, from: nil); NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let previous = dragPoint { pan.x += point.x - previous.x; pan.y += point.y - previous.y; needsDisplay = true }
        dragPoint = point
    }
    override func mouseUp(with event: NSEvent) { if dragPoint != nil { NSCursor.pop() }; dragPoint = nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
