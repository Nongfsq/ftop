import AppKit

/// The edges of the panel a resize moves.
public struct PanelEdges: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let left = PanelEdges(rawValue: 1 << 0)
    public static let right = PanelEdges(rawValue: 1 << 1)
    public static let top = PanelEdges(rawValue: 1 << 2)
    public static let bottom = PanelEdges(rawValue: 1 << 3)

    /// One side and one end: a corner.
    var isCorner: Bool { !isDisjoint(with: [.left, .right]) && !isDisjoint(with: [.top, .bottom]) }

    /// The system's frame resize cursor for these edges; nil for none.
    @MainActor var cursor: NSCursor? {
        let position: NSCursor.FrameResizePosition? =
            switch self {
            case [.top, .left]: .topLeft
            case [.top, .right]: .topRight
            case [.bottom, .left]: .bottomLeft
            case [.bottom, .right]: .bottomRight
            case .top: .top
            case .bottom: .bottom
            case .left: .left
            case .right: .right
            default: nil
            }
        return position.map { NSCursor.frameResize(position: $0, directions: .all) }
    }
}

/// A clear ring around the panel where the pointer shows the resize cursor and a press
/// resizes, as the system's border does around other windows. With the resize edges on
/// the panel does not use the system's border, which reaches a little outside, so
/// without the ring an edge could be found only from inside. It also takes the corners'
/// rounded tips, where the panel itself lets the pointer through to what is behind.
///
/// It is a child window under the panel, as large as the panel and the ring.
@MainActor
public final class ResizeHalo {
    /// A press in the ring, which resizes the panel; it returns when the press ends.
    public var onEdgeDrag: (PanelEdges) -> Void = { _ in }

    private let window = HaloWindow()
    private let view = HaloView()
    private weak var parent: NSWindow?

    public init() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Set explicitly, so the clear window takes the pointer.
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.onEdgeDrag = { [weak self] edges in self?.onEdgeDrag(edges) }
    }

    /// Puts the ring around `panel`, which must be on screen.
    public func attach(to panel: NSWindow) {
        guard parent !== panel else { return fit(to: panel.frame) }
        detach()
        fit(to: panel.frame)
        panel.addChildWindow(window, ordered: .below)
        parent = panel
    }

    public func detach() {
        guard let parent else { return }
        parent.removeChildWindow(window)
        window.orderOut(nil)
        self.parent = nil
    }

    /// Follows the panel's frame; a child window moves with its parent but does not resize.
    public func fit(to frame: NSRect) {
        let reach = PanelStyle.resizeOutside
        let wanted = frame.insetBy(dx: -reach, dy: -reach)
        if window.frame != wanted { window.setFrame(wanted, display: false) }
    }
}

private final class HaloWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    }

    /// Exactly around the panel, even where that reaches under the menu bar: moved down
    /// to stay clear of it, the ring would be off by its width on both sides.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class HaloView: NSView {
    var onEdgeDrag: (PanelEdges) -> Void = { _ in }
    private var cursorEdges: PanelEdges = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The panel is this view inset by the ring. Near a panel corner, inside the ring or
    /// on the corner's rounded tip, both edges; elsewhere in the ring, the side it is on.
    private func edges(at point: CGPoint) -> PanelEdges {
        let panel = bounds.insetBy(dx: PanelStyle.resizeOutside, dy: PanelStyle.resizeOutside)
        guard bounds.contains(point), panel.width > 0, panel.height > 0 else { return [] }
        let reach = min(PanelStyle.resizeCorner, min(panel.width, panel.height) / 3)
        var corner: PanelEdges = []
        if point.x < panel.minX + reach { corner.insert(.left) } else if point.x > panel.maxX - reach { corner.insert(.right) }
        if point.y < panel.minY + reach { corner.insert(.top) } else if point.y > panel.maxY - reach { corner.insert(.bottom) }
        if corner.isCorner { return corner }
        var side: PanelEdges = []
        if point.x < panel.minX { side.insert(.left) } else if point.x > panel.maxX { side.insert(.right) }
        if point.y < panel.minY { side.insert(.top) } else if point.y > panel.maxY { side.insert(.bottom) }
        return side
    }

    private func showCursor(at point: CGPoint?) {
        let edges = point.map(edges(at:)) ?? []
        guard edges != cursorEdges else { return }
        cursorEdges = edges
        (edges.cursor ?? NSCursor.arrow).set()
    }

    override func mouseMoved(with event: NSEvent) { showCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { showCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { showCursor(at: nil) }

    override func mouseDown(with event: NSEvent) {
        let edges = edges(at: convert(event.locationInWindow, from: nil))
        guard !edges.isEmpty else { return }
        onEdgeDrag(edges)
        // The resize set its own cursor; this one is decided again where the pointer is now.
        cursorEdges = []
        showCursor(at: window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) })
    }
}
