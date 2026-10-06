import AppKit
import CoreText
import IOSurface
import FtopCore

/// Draws a scene. Text and shapes are drawn into a surface the layer shows directly,
/// only where something changed; the core columns are layers in a subview. Nothing here runs
/// between samples.
///
/// The surface is the view's own rather than the bitmap AppKit gives `draw(_:)`: drawing
/// text there kept a glyph cache of several megabytes for every type size the panel
/// had ever used. It is a surface rather than an image made from a bitmap because an
/// image is a copy: every sample the system copied each memory page that had changed,
/// which in a large window cost more than the drawing.
@MainActor
public final class PanelCanvasView: NSView {
    public var onTogglePin: () -> Void = {}
    public var onHide: () -> Void = {}

    private var scene = Scene()
    private var style = PanelStyle()
    private var origin: CGPoint = .zero
    private let content = NSView()
    private let barsView = CoreBarsView()
    private let controls = ControlsView()
    private let chip = ChipWindow()
    private var pointer: CGPoint?
    private var hoverText: String?
    private struct Buffer {
        let surface: IOSurface
        let context: CGContext
        /// Areas changed on the other surface since this one was last drawn.
        var stale: [CGRect]
    }

    private var buffers: [Buffer] = []
    private var front = 0
    private var bitmapScale: CGFloat = 0
    private lazy var controlsSize = controls.fittingSize

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        content.wantsLayer = true
        // Its layer shows a surface drawn here; AppKit must not draw into it.
        content.layerContentsRedrawPolicy = .never
        content.layer?.contentsGravity = .resize
        addSubview(content)
        addSubview(barsView)
        addSubview(controls)
        controls.alphaValue = 0
        controls.pin.target = self
        controls.pin.action = #selector(pinPressed)
        controls.hide.target = self
        controls.hide.action = #selector(hidePressed)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override var acceptsFirstResponder: Bool { false }

    /// Dragging anywhere moves the window. Done here instead of
    /// `isMovableByWindowBackground`, which makes AppKit recompute drag regions on every frame.
    public override func mouseDown(with event: NSEvent) {
        hideChip()
        window?.performDrag(with: event)
    }

    // MARK: Showing a scene

    /// `fade` cross-fades the whole canvas, for a change of layout rather than of values.
    public func show(_ new: Scene, style newStyle: PanelStyle, pinned: Bool, fade: Bool = false) {
        let old = scene
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let wholeRedraw = old.size != new.size || newStyle != style || buffers.isEmpty || backing != bitmapScale
        scene = new
        style = newStyle
        if wholeRedraw {
            makeBitmap(scale: backing)
            paint([CGRect(origin: .zero, size: new.size)])
        } else {
            paint(changedRects(from: old, to: new))
        }
        if fade, newStyle.motion, let layer = content.layer {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.14
            layer.add(transition, forKey: "layout")
        }
        controls.setPinned(pinned)
        placeContent()
        refreshHover()
    }

    private func changedRects(from old: Scene, to new: Scene) -> [CGRect] {
        var rects: [CGRect] = []
        for item in Set(old.texts).symmetricDifference(new.texts) { rects.append(item.frame.insetBy(dx: -2, dy: -2)) }
        for item in Set(old.shapes).symmetricDifference(new.shapes) { rects.append(item.rect.insetBy(dx: -1, dy: -1)) }
        return rects
    }

    /// Two surfaces drawn in turn: the layer always shows a finished one, and giving it
    /// the other surface is what makes it show the new pixels.
    private func makeBitmap(scale: CGFloat) {
        bitmapScale = scale
        let width = max(1, Int((scene.size.width * scale).rounded(.up)))
        let height = max(1, Int((scene.size.height * scale).rounded(.up)))
        // The screen's own color space, so the system does not convert the pixels every time they change.
        let space = (window?.screen ?? NSScreen.main)?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        buffers = []
        for _ in 0..<2 {
            guard let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA]),
                let context = CGContext(
                    data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else {
                buffers = []
                return
            }
            if let profile = space.copyPropertyList() {
                IOSurfaceSetValue(unsafeBitCast(surface, to: IOSurfaceRef.self), kIOSurfaceColorSpace, profile)
            }
            // Top-left origin in points, matching scene coordinates.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setAllowsFontSubpixelQuantization(false)
            // The bitmap is flipped; flip glyphs back.
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            buffers.append(Buffer(surface: surface, context: context, stale: []))
        }
        front = 0
    }

    /// Redraws the given parts of the scene and shows the result.
    private func paint(_ rects: [CGRect]) {
        guard buffers.count == 2, !rects.isEmpty else { return }
        // The surface drawn now missed what the previous pass changed; redraw that too.
        let back = 1 - front
        // Most numbers change in place every sample, so the two lists largely repeat each other.
        var seen = Set<[CGFloat]>()
        let areas = (buffers[back].stale + rects).filter { seen.insert([$0.minX, $0.minY, $0.width, $0.height]).inserted }
        buffers[back].stale = []
        buffers[front].stale = rects
        let surface = buffers[back].surface
        let context = buffers[back].context
        surface.lock(options: [], seed: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Resolve each color once per pass, not once per piece of text.
            var colors: [Paint: CGColor] = [:]
            let style = style
            func color(_ paint: Paint) -> CGColor {
                if let known = colors[paint] { return known }
                let resolved = style.color(paint).cgColor
                colors[paint] = resolved
                return resolved
            }
            for rect in areas {
                // Whole pixels, so neighbors of the cleared area are not left half erased.
                guard let area = erase(rect, in: context) else { continue }
                context.saveGState()
                context.clip(to: area)
                for shape in scene.shapes where shape.rect.insetBy(dx: -1, dy: -1).intersects(area) { draw(shape, in: context, color: color) }
                for item in scene.texts where item.frame.insetBy(dx: -2, dy: -2).intersects(area) {
                    context.setFillColor(color(item.paint))
                    context.textPosition = CGPoint(x: item.x, y: item.baseline)
                    CTLineDraw(Typesetter.line(item.string, item.font).line, context)
                }
                context.restoreGState()
            }
        }
        surface.unlock(options: [], seed: nil)
        front = back
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.layer?.contents = surface
        CATransaction.commit()
    }

    /// Zeroes the pixels under `rect` and returns the area cleared, in points. Written
    /// to the bitmap's memory directly: clearing through the context cost more than
    /// drawing the text that replaced it.
    private func erase(_ rect: CGRect, in context: CGContext) -> CGRect? {
        guard let data = context.data else { return nil }
        let scale = bitmapScale
        let left = max(0, Int((rect.minX * scale).rounded(.down)))
        let top = max(0, Int((rect.minY * scale).rounded(.down)))
        let right = min(context.width, Int((rect.maxX * scale).rounded(.up)))
        let bottom = min(context.height, Int((rect.maxY * scale).rounded(.up)))
        guard right > left, bottom > top else { return nil }
        // Row 0 of the bitmap's memory is the top row, as in scene coordinates.
        for row in top..<bottom {
            memset(data + row * context.bytesPerRow + left * 4, 0, (right - left) * 4)
        }
        return CGRect(x: CGFloat(left) / scale, y: CGFloat(top) / scale, width: CGFloat(right - left) / scale, height: CGFloat(bottom - top) / scale)
    }

    public override func layout() {
        super.layout()
        placeContent()
    }

    /// Moved to a screen with another pixel density or color space: draw again for it.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        buffers = []
        show(scene, style: style, pinned: controls.pinned)
    }

    /// Centers the scene; while the window is being dragged it is briefly larger than the scene.
    private func placeContent() {
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let x = ((bounds.width - scene.size.width) / 2 / pixel).rounded() * pixel
        let y = ((bounds.height - scene.size.height) / 2 / pixel).rounded() * pixel
        origin = CGPoint(x: x, y: y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = CGRect(origin: origin, size: scene.size)
        if content.frame != frame { content.frame = frame }
        if let item = scene.bars {
            barsView.isHidden = false
            let frame = item.rect.offsetBy(dx: origin.x, dy: origin.y)
            if barsView.frame != frame { barsView.frame = frame }
            barsView.update(item, style: style)
        } else {
            barsView.isHidden = true
        }
        CATransaction.commit()
        // The buttons need room; small layouts use the right-click menu instead.
        let roomy = bounds.width >= 150 && bounds.height >= 96
        controls.isHidden = !roomy
        let size = controlsSize
        controls.frame = CGRect(x: bounds.width - size.width - 7, y: 7, width: size.width, height: size.height)
    }

    private func draw(_ shape: ShapeItem, in context: CGContext, color: (Paint) -> CGColor) {
        switch shape.kind {
        case .circle:
            context.setFillColor(color(shape.paint))
            context.fillEllipse(in: shape.rect)
        case .meter(let track, let segments, let outline):
            let capsule = CGPath(roundedRect: shape.rect, cornerWidth: shape.rect.height / 2, cornerHeight: shape.rect.height / 2, transform: nil)
            context.saveGState()
            context.addPath(capsule)
            context.clip()
            if let track {
                context.setFillColor(color(track))
                context.fill(shape.rect)
            }
            var x = shape.rect.minX
            for segment in segments {
                let width = shape.rect.width * min(1, max(0, segment.fraction))
                context.setFillColor(color(segment.paint))
                context.fill(CGRect(x: x, y: shape.rect.minY, width: width, height: shape.rect.height))
                x += width
            }
            context.restoreGState()
            if let outline {
                let inset = shape.rect.insetBy(dx: 0.5, dy: 0.5)
                context.addPath(CGPath(roundedRect: inset, cornerWidth: inset.height / 2, cornerHeight: inset.height / 2, transform: nil))
                context.setStrokeColor(color(outline))
                context.setLineWidth(1)
                context.strokePath()
            }
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint([CGRect(origin: .zero, size: scene.size)])
    }

    // MARK: Hover

    public override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        refreshHover()
    }

    public override func mouseEntered(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        refreshHover()
    }

    public override func mouseExited(with event: NSEvent) {
        pointer = nil
        refreshHover()
    }

    private func refreshHover() {
        // The buttons appear while the pointer is along the top edge, where a title bar would be.
        let overControls = pointer.map { $0.y < 38 || controls.frame.insetBy(dx: -8, dy: -8).contains($0) } ?? false
        controls.setVisible(overControls && !controls.isHidden)

        let onButtons = pointer.map { controls.alphaValue > 0 && controls.frame.contains($0) } ?? false
        let region = onButtons ? nil : pointer.flatMap { scene.hover(at: CGPoint(x: $0.x - origin.x, y: $0.y - origin.y)) }
        barsView.highlight(region?.coreIndex)
        var text = region?.text
        if text?.isEmpty == true, let index = region?.coreIndex, let cores = scene.bars?.cores, index < cores.count { text = Strings.core(cores[index]) }
        if text?.isEmpty == true { text = nil }
        guard let text, let pointer, let window else {
            hideChip()
            return
        }
        hoverText = text
        let onScreen = window.convertPoint(toScreen: convert(pointer, to: nil))
        chip.show(text, above: onScreen, parent: window)
    }

    private func hideChip() {
        guard hoverText != nil else { return }
        hoverText = nil
        chip.dismiss()
    }

    public func dismissHover() {
        pointer = nil
        refreshHover()
    }

    @objc private func pinPressed() { onTogglePin() }
    @objc private func hidePressed() { onHide() }
}

/// The pin and hide buttons that appear along the top edge.
@MainActor
final class ControlsView: NSView {
    let pin = ControlsView.button("pin")
    let hide = ControlsView.button("minus")
    private var shown = false
    private(set) var pinned = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        let stack = NSStackView(views: [pin, hide])
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hide.toolTip = Strings.pick("Hide (the menu bar number brings it back)", "收起（点菜单栏的数字可再显示）")
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static func button(_ symbol: String) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = image(symbol)
        button.contentTintColor = PanelStyle.inkColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    private static func image(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
    }

    func setPinned(_ pinned: Bool) {
        guard pinned != self.pinned || pin.toolTip == nil else { return }
        self.pinned = pinned
        pin.image = Self.image(pinned ? "pin.fill" : "pin")
        pin.toolTip = pinned ? Strings.pick("Stop keeping on top", "取消置顶") : Strings.pick("Keep on top", "置顶")
    }

    func setVisible(_ visible: Bool) {
        guard visible != shown else { return }
        shown = visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            animator().alphaValue = visible ? 1 : 0
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = PanelStyle.controlColor.cgColor
        }
    }
}

/// The detail line shown while the pointer rests on something. It is its own small
/// window so it is never cut off by the panel's edge, however small the panel is.
@MainActor
final class ChipWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var placedAt = NSPoint.zero
    private var placedText = ""
    private static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 11, weight: .medium)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 11) ?? base
    }()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.cornerCurve = .continuous
        label.font = Self.font
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        contentView = background
    }

    func show(_ text: String, above point: NSPoint, parent: NSWindow) {
        guard let background = contentView else { return }
        if appearance?.name != parent.effectiveAppearance.name || !isVisible {
            appearance = parent.effectiveAppearance
            background.effectiveAppearance.performAsCurrentDrawingAppearance {
                background.layer?.backgroundColor = PanelStyle.chipColor.cgColor
            }
            label.textColor = PanelStyle.chipTextColor
        }
        if label.stringValue != text { label.stringValue = text }
        // Moving a window is costly; follow the pointer in steps, not on every event.
        let moved = abs(point.x - placedAt.x) > 14 || abs(point.y - placedAt.y) > 14
        guard moved || text != placedText || !isVisible else { return }
        let size = NSSize(width: ceil(label.intrinsicContentSize.width) + 16, height: 20)
        let anchor = moved || !isVisible ? point : placedAt
        placedAt = anchor
        placedText = text
        var frame = NSRect(x: anchor.x - size.width / 2, y: anchor.y + 12, width: size.width, height: size.height)
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 4), visible.maxX - size.width - 4)
            // No room above the pointer: go below it.
            if frame.maxY > visible.maxY - 2 { frame.origin.y = anchor.y - size.height - 16 }
        }
        if frame != self.frame { setFrame(frame, display: true) }
        if parent.childWindows?.contains(self) != true {
            level = parent.level
            parent.addChildWindow(self, ordered: .above)
        }
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}
