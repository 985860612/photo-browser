import AppKit
import SwiftUI
import MetalKit
import CoreImage
import BrowserCore

struct PhotoCanvas: NSViewRepresentable {
    let photo: DisplayPhoto?
    let identity: String
    let hdr: Bool
    @Binding var zoom: Double
    @Binding var fitScale: Double
    var normalizedPan: Binding<CGPoint>? = nil
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
        view.onPan = { normalizedPan?.wrappedValue = $0 }
        view.configure(photo: photo, identity: identity, hdr: hdr, zoom: zoom, normalizedPan: normalizedPan?.wrappedValue)
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
    private var frameRevision: UInt64 = 0
    private var retriedFrame = false
    var onZoom: ((Double) -> Void)?
    var onFitScale: ((Double) -> Void)?
    var onFailure: ((String) -> Void)?
    var onPan: ((CGPoint) -> Void)?

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .rgba16Float; framebufferOnly = false
        isPaused = true; enableSetNeedsDisplay = true; autoResizeDrawable = true
        delegate = self
        if let device, let queue = device.makeCommandQueue() {
            self.queue = queue
            ciContext = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: outputSpace, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
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
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); reportFit(); needsDisplay = true
    }

    func configure(photo: DisplayPhoto?, identity: String, hdr: Bool, zoom: Double, normalizedPan: CGPoint? = nil) {
        let panChanged = normalizedPan.map { abs($0.x - normalizedOffset.x) > 0.000001 || abs($0.y - normalizedOffset.y) > 0.000001 } ?? false
        guard self.photo?.image !== photo?.image || self.identity != identity || self.hdr != hdr || self.zoom != zoom || panChanged else { return }
        if self.identity != identity { pan = .zero; self.identity = identity }
        self.photo = photo; self.hdr = hdr; self.zoom = zoom
        frameRevision &+= 1; retriedFrame = false
        reportFit()
        if let normalizedPan, let photo {
            pan = CGPoint(x: normalizedPan.x * photo.size.width * fit * zoom, y: normalizedPan.y * photo.size.height * fit * zoom)
        } else if zoom == 1 { pan = .zero }
        (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = hdr && photo?.isHDR == true
        if ciContext == nil, photo != nil { DispatchQueue.main.async { [weak self] in self?.onFailure?(L10n.text("当前 Mac 无法建立 Metal 预览，请检查图形设备。")) } }
        needsDisplay = true
    }
    private var fit: Double {
        guard let photo, photo.size.width > 0, photo.size.height > 0 else { return 1 }
        return max(0.0001, min(bounds.width / photo.size.width, bounds.height / photo.size.height))
    }
    private var normalizedOffset: CGPoint {
        guard let photo else { return .zero }
        return CGPoint(x: pan.x / max(1, photo.size.width * fit * zoom), y: pan.y / max(1, photo.size.height * fit * zoom))
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        reportFit(); needsDisplay = true
    }
    private func reportFit() {
        let value = fit
        guard abs(value - lastReportedFit) > 0.000001 else { return }
        lastReportedFit = value
        DispatchQueue.main.async { [weak self] in self?.onFitScale?(value) }
    }
    func draw(in view: MTKView) {
        guard bounds.width > 0, bounds.height > 0,
              let drawable = currentDrawable, let command = makeFrameCommandBuffer() else { return }
        let drawStarted = ProcessInfo.processInfo.systemUptime
        do { try encodeFrame(to: drawable.texture, command: command) }
        catch { DispatchQueue.main.async { [weak self] in self?.onFailure?(error.localizedDescription) }; return }
        frameRevision &+= 1
        let revision = frameRevision, retainedImage = photo?.image
        trackFrameMetrics(command, started: drawStarted)
        command.addCompletedHandler { [weak self, retainedImage] buffer in
            withExtendedLifetime(retainedImage) {}
            let message = buffer.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.frameRevision == revision else { return }
                if let message {
                    if self.retriedFrame { self.onFailure?(message) }
                    else { self.retriedFrame = true; self.needsDisplay = true }
                } else { self.retriedFrame = false }
            }
        }
        command.present(drawable); command.commit()
    }

    /// Shared by the onscreen canvas and pixel-level render checks.
    func makeFrameCommandBuffer() -> MTLCommandBuffer? { queue?.makeCommandBuffer() }
    func trackFrameMetrics(_ command: MTLCommandBuffer, started: TimeInterval) {
        guard photo != nil, let sample = PreviewDiagnostics.shared.currentSample(path: identity) else { return }
        command.addCompletedHandler { buffer in
            if buffer.error == nil { PreviewDiagnostics.shared.rendered(sample, milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000) }
            else { PreviewDiagnostics.shared.failed(sample) }
        }
    }

    func encodeFrame(to texture: MTLTexture, command: MTLCommandBuffer) throws {
        guard bounds.width > 0, bounds.height > 0, let ciContext else { return }
        let viewport = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        let background = CIImage(color: .black).cropped(to: viewport)
        var frame = background
        if let photo {
            var image = photo.image
            if #available(macOS 15, *), photo.isHDR {
                let target = hdr ? max(1, window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1) : 1
                if let mapped = CIFilter(name: "CIToneMapHeadroom", parameters: [kCIInputImageKey: image, "inputSourceHeadroom": photo.headroom, "inputTargetHeadroom": Float(target)])?.outputImage { image = mapped }
            }
            let scale = min(viewport.width / photo.size.width, viewport.height / photo.size.height) * zoom
            let x = (viewport.width - photo.size.width * scale) / 2 + pan.x * viewport.width / bounds.width
            let y = (viewport.height - photo.size.height * scale) / 2 + pan.y * viewport.height / bounds.height
            let placed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: x, y: y))
            frame = placed.composited(over: background).cropped(to: viewport)
        }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
        destination.colorSpace = outputSpace
        destination.isFlipped = true
        destination.alphaMode = .none
        _ = try ciContext.startTask(toRender: frame, from: viewport, to: destination, at: .zero)
    }
    private func changeZoom(_ value: Double, at anchor: CGPoint) {
        let new = min(10, max(0.1, value)), ratio = new / zoom
        let centered = CGPoint(x: anchor.x - bounds.midX, y: anchor.y - bounds.midY)
        pan = CGPoint(x: centered.x - (centered.x - pan.x) * ratio, y: centered.y - (centered.y - pan.y) * ratio)
        zoom = new; onZoom?(new); onPan?(normalizedOffset); needsDisplay = true
    }
    override func magnify(with event: NSEvent) { changeZoom(zoom * max(0.1, 1 + event.magnification), at: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            changeZoom(zoom * exp(event.scrollingDeltaY * 0.015), at: convert(event.locationInWindow, from: nil))
        } else {
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 14
            // Precise touch gestures grab the photo, independent of the system scroll preference.
            let direction: CGFloat = event.hasPreciseScrollingDeltas && !event.isDirectionInvertedFromDevice ? -1 : 1
            pan.x += event.scrollingDeltaX * multiplier * direction
            // AppKit's vertical scroll axis is opposite to the Core Image canvas Y axis.
            pan.y -= event.scrollingDeltaY * multiplier * direction
            onPan?(normalizedOffset)
            needsDisplay = true
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            let pixelZoom = min(10, max(0.1, 1 / (fit * (window?.backingScaleFactor ?? 2))))
            changeZoom(abs(zoom - 1) < 0.001 ? pixelZoom : 1, at: convert(event.locationInWindow, from: nil))
            if zoom == 1 { pan = .zero; onPan?(.zero) }; return
        }
        dragPoint = convert(event.locationInWindow, from: nil); NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let previous = dragPoint { pan.x += point.x - previous.x; pan.y += point.y - previous.y; onPan?(normalizedOffset); needsDisplay = true }
        dragPoint = point
    }
    override func mouseUp(with event: NSEvent) { if dragPoint != nil { NSCursor.pop() }; dragPoint = nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
