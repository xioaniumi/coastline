import AppKit
import MetalKit
import SwiftUI

/// The interactive Metal view. Navigation (Mac trackpad first):
/// - drag: orbit · two-finger scroll: pan · pinch: zoom · double-click: frame all
/// - ⌥-drag or right-drag: pan · mouse wheel (non-trackpad): zoom
public final class ViewportNSView: MTKView {
    public let renderer: ViewportRenderer

    public init(renderer: ViewportRenderer) {
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        delegate = renderer
        colorPixelFormat = ViewportRenderer.colorFormat
        depthStencilPixelFormat = ViewportRenderer.depthFormat
        clearDepth = DepthConvention.clear
        sampleCount = ViewportRenderer.sampleCount
        preferredFramesPerSecond = 120
        clearColor = renderer.background
        // A see-through background (alpha 0) lets the view sit on a SwiftUI panel.
        if renderer.background.alpha < 1 {
            layer?.isOpaque = false
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    public override var acceptsFirstResponder: Bool { true }

    public override func mouseDragged(with event: NSEvent) {
        if handleDragging {  // a manipulator handle has the drag
            dragged = true
            onHandleDrag?(convert(event.locationInWindow, from: nil))
            return
        }
        renderer.cancelCameraAnimation()
        if let d = downLocation, hypot(convert(event.locationInWindow, from: nil).x - d.x, convert(event.locationInWindow, from: nil).y - d.y) > 3 {
            dragged = true
        }
        if event.modifierFlags.contains(.option) {
            renderer.camera.pan(dx: Float(event.deltaX), dy: Float(event.deltaY), viewHeight: Float(bounds.height))
        } else {
            renderer.camera.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
        }
    }

    public override func rightMouseDragged(with event: NSEvent) {
        renderer.cancelCameraAnimation()
        renderer.camera.pan(dx: Float(event.deltaX), dy: Float(event.deltaY), viewHeight: Float(bounds.height))
    }

    public override func otherMouseDragged(with event: NSEvent) { rightMouseDragged(with: event) }

    public override func scrollWheel(with event: NSEvent) {
        renderer.cancelCameraAnimation()
        if event.hasPreciseScrollingDeltas {
            // scrollingDelta already follows the user's natural-scrolling setting: the scene
            // moves with the fingers.
            renderer.camera.pan(dx: Float(event.scrollingDeltaX), dy: Float(event.scrollingDeltaY),
                                viewHeight: Float(bounds.height))
        } else {
            renderer.camera.zoom(by: event.scrollingDeltaY > 0 ? 0.9 : 1.1)
        }
    }

    public override func magnify(with event: NSEvent) {
        renderer.cancelCameraAnimation()
        renderer.camera.zoom(by: Float(1 / (1 + event.magnification)))
    }

    /// Called for a click that didn't turn into a drag (point in view coordinates, top-left origin).
    public var onClick: ((CGPoint) -> Void)?
    /// Manipulator handles (gumball): asked on mouse down whether a handle is under the point;
    /// if so the drag goes to `onHandleDrag` instead of the camera.
    public var onHandleBegin: ((CGPoint) -> Bool)?
    public var onHandleDrag: ((CGPoint) -> Void)?
    public var onHandleEnd: (() -> Void)?
    private var handleDragging = false
    private var downLocation: CGPoint?
    private var dragged = false

    public override var isFlipped: Bool { true }

    public override func mouseDown(with event: NSEvent) {
        downLocation = convert(event.locationInWindow, from: nil)
        dragged = false
        handleDragging = downLocation.map { onHandleBegin?($0) ?? false } ?? false
        if event.clickCount == 2 { renderer.frameAll() }
    }

    public override func mouseUp(with event: NSEvent) {
        defer { downLocation = nil }
        if handleDragging {
            handleDragging = false
            onHandleEnd?()
            return
        }
        guard !dragged, event.clickCount == 1, let p = downLocation else { return }
        onClick?(p)
    }
}

/// SwiftUI wrapper. Keep one `ViewportRenderer` per document and pass it in.
public struct ViewportContainer: NSViewRepresentable {
    public let renderer: ViewportRenderer
    public var onClick: ((CGPoint, CGSize) -> Void)?
    public var handles: Handles?
    /// Gumball-style handles: begin (is a handle here?), drag, end; points in view coordinates.
    public struct Handles {
        public var begin: (CGPoint, CGSize) -> Bool
        public var drag: (CGPoint, CGSize) -> Void
        public var end: () -> Void
        public init(begin: @escaping (CGPoint, CGSize) -> Bool, drag: @escaping (CGPoint, CGSize) -> Void, end: @escaping () -> Void) {
            self.begin = begin
            self.drag = drag
            self.end = end
        }
    }
    public init(renderer: ViewportRenderer, onClick: ((CGPoint, CGSize) -> Void)? = nil, handles: Handles? = nil) {
        self.renderer = renderer
        self.onClick = onClick
        self.handles = handles
    }
    public func makeNSView(context: Context) -> ViewportNSView {
        let v = ViewportNSView(renderer: renderer)
        updateNSView(v, context: context)
        return v
    }
    public func updateNSView(_ view: ViewportNSView, context: Context) {
        view.onClick = { [weak view] p in onClick?(p, view?.bounds.size ?? .zero) }
        let h = handles
        view.onHandleBegin = { [weak view] p in h?.begin(p, view?.bounds.size ?? .zero) ?? false }
        view.onHandleDrag = { [weak view] p in h?.drag(p, view?.bounds.size ?? .zero) }
        view.onHandleEnd = { h?.end() }
    }
}
