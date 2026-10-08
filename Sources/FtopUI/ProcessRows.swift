import AppKit
import FtopCore

/// App icons by bundle path, cut to their artwork and cached.
@MainActor
enum AppIcons {
    private static var images: [String: CGImage?] = [:]

    /// The icon of the app at `path`, without the transparent margin app icons carry,
    /// or nil when there is no app there.
    static func image(for path: String) -> CGImage? {
        if let known = images[path] { return known }
        var image: CGImage?
        if FileManager.default.fileExists(atPath: path) {
            let icon = NSWorkspace.shared.icon(forFile: path)
            var proposed = CGRect(x: 0, y: 0, width: 96, height: 96)
            image = icon.cgImage(forProposedRect: &proposed, context: nil, hints: nil).flatMap(GlyphArt.trimmed)
        }
        if images.count > 300 {
            images.removeAll()
            fitted.removeAll()
        }
        images[path] = image
        return image
    }

    private struct Fit: Hashable {
        var path: String
        var pixels: Int
    }
    private static var fitted: [Fit: CGImage] = [:]

    /// The icon scaled to `pixels` on a side, in the color space rows are drawn in. Rows are
    /// redrawn whenever their figure changes; scaling and color-matching the artwork each
    /// time was most of the panel's cost.
    private static func image(for path: String, pixels: Int) -> CGImage? {
        let key = Fit(path: path, pixels: pixels)
        if let known = fitted[key] { return known }
        guard let source = image(for: path) else { return nil }
        let side = CGFloat(pixels)
        let image = drawnImage(size: CGSize(width: side, height: side), scale: 1) { context in
            context.translateBy(x: 0, y: side)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        if fitted.count > 600 { fitted.removeAll() }
        fitted[key] = image
        return image
    }

    /// Draws the app's icon, or the plain-process glyph, centered in `rect` in a top-down context.
    static func draw(_ path: String?, in rect: CGRect, style: PanelStyle, fallback: CGColor, context: CGContext) {
        let side = rect.width * PanelStyle.badgeIconShare
        // The context's scale gives the pixels the icon will cover.
        let pixels = max(1, Int((side * abs(context.ctm.a)).rounded()))
        guard let path, let image = image(for: path, pixels: pixels) else {
            let side = style.badgeGlyph
            GlyphArt.draw(.process, in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side), color: fallback, context: context)
            return
        }
        // On whole pixels, so the scaled icon is copied as it is.
        let scale = abs(context.ctm.a)
        let fit = CGFloat(pixels) / scale
        let box = CGRect(
            x: ((rect.midX - fit / 2) * scale).rounded() / scale, y: ((rect.midY - fit / 2) * scale).rounded() / scale, width: fit, height: fit)
        context.saveGState()
        context.translateBy(x: box.minX, y: box.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(origin: .zero, size: box.size))
        context.restoreGState()
    }
}

/// A bitmap drawn with its origin at the top left, in points, like the canvas.
@MainActor
func drawnImage(size: CGSize, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
    let width = max(1, Int((size.width * scale).rounded(.up)))
    let height = max(1, Int((size.height * scale).rounded(.up)))
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    context.setShouldSmoothFonts(false)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    body(context)
    return context.makeImage()
}

/// The rows of the process list, one layer each, so a row slides to its new rank,
/// lights under the pointer, and gives under a press. A row is redrawn only when what
/// it says changes; between samples everything here is Core Animation.
final class ProcessRowsView: NSView {
    private final class Row {
        let layer = CALayer()
        let highlight = CALayer()
        /// The icon and the name, which stay as they are while the row lives.
        let content = CALayer()
        /// The figure, the only part redrawn as readings change.
        let figure = CALayer()
        let arc = CAShapeLayer()
        var drawn: ProcessRow?
        var width: CGFloat = 0

        init() {
            highlight.opacity = 0
            arc.fillColor = nil
            arc.lineCap = .round
            layer.addSublayer(highlight)
            layer.addSublayer(content)
            layer.addSublayer(figure)
            layer.addSublayer(arc)
        }
    }

    private var rows: [String: Row] = [:]
    private var item: ProcessRowsItem?
    private var style = PanelStyle()
    private var lit: String?
    private var pressed: String?
    private var held: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ new: ProcessRowsItem?, style newStyle: PanelStyle) {
        let old = item
        let restyled = newStyle.scale != style.scale || newStyle.palette != style.palette
        item = new
        style = newStyle
        guard let new else {
            rows.values.forEach { $0.layer.removeFromSuperlayer() }
            rows = [:]
            return
        }
        // A change of layout places rows at once; a change of rank moves them.
        let moves = style.motion && old != nil && !restyled && old!.rect.size == new.rect.size && old!.perColumn == new.perColumn
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scale = window?.backingScaleFactor ?? 2
        var kept = Set<String>()
        for (index, row) in new.rows.enumerated() {
            kept.insert(row.key)
            let frame = new.frame(at: index)
            let entry: Row
            if let known = rows[row.key] {
                entry = known
                place(entry, at: frame, pitch: new.pitch, animated: moves, calm: calm)
            } else {
                entry = Row()
                rows[row.key] = entry
                layer?.addSublayer(entry.layer)
                place(entry, at: frame, pitch: new.pitch, animated: false, calm: calm)
                if moves { enter(entry, shift: 0, after: 0) }
            }
            draw(row, in: entry, size: frame.size, scale: scale, paint: new.paint, restyled: restyled, animated: moves)
        }
        for (key, entry) in rows where !kept.contains(key) {
            rows[key] = nil
            if moves { leave(entry, shift: 0, duration: PanelStyle.rowDepart) }
            entry.layer.removeFromSuperlayer()
        }
        if let lit, !kept.contains(lit) { self.lit = nil }
        applyStates(animated: false)
    }

    /// Moves a row to `frame`. A row trading places with its neighbor slides past it; a row
    /// going further, or to the other column, would cross the rows between, so it turns over
    /// where it stands instead: what it showed leaves upward and it comes in at its new place.
    private func place(_ entry: Row, at frame: CGRect, pitch: CGFloat, animated: Bool, calm: Bool) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let from = entry.layer.position
        let moved = abs(from.x - center.x) > 0.5 || abs(from.y - center.y) > 0.5
        let near = abs(from.x - center.x) <= 0.5 && abs(from.y - center.y) < pitch * 1.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated, moved, near, !calm {
            // From wherever the row is on screen now, so a row caught mid-slide carries on from there.
            let slide = CASpringAnimation(keyPath: "position")
            slide.fromValue = NSValue(point: entry.layer.presentation()?.position ?? from)
            slide.toValue = NSValue(point: center)
            slide.damping = PanelStyle.rowSlideDamping
            slide.stiffness = PanelStyle.rowSlideStiffness
            slide.duration = slide.settlingDuration
            entry.layer.add(slide, forKey: "slide")
        } else if animated, moved {
            entry.layer.removeAnimation(forKey: "slide")
            let shift = calm ? 0 : style.rowTurnShift
            leave(entry, shift: shift, duration: PanelStyle.rowLeave)
            enter(entry, shift: shift, after: PanelStyle.rowLeave)
        }
        entry.layer.bounds = CGRect(origin: .zero, size: frame.size)
        entry.layer.position = center
        let inset = style.processRowGap / 2
        entry.highlight.frame = entry.layer.bounds.insetBy(dx: -style.points(6), dy: -inset)
        entry.highlight.cornerRadius = style.points(8)
        entry.highlight.cornerCurve = .continuous
        CATransaction.commit()
    }

    /// Leaves a picture of the row where it stands, which rises by `shift` and fades away.
    private func leave(_ entry: Row, shift: CGFloat, duration: Double) {
        guard let host = layer, entry.content.contents != nil else { return }
        let ghost = CALayer()
        ghost.frame = entry.layer.frame
        let picture = CALayer()
        picture.frame = entry.content.frame
        picture.contents = entry.content.contents
        picture.contentsScale = entry.content.contentsScale
        let figure = CALayer()
        figure.frame = entry.figure.frame
        figure.contents = entry.figure.contents
        figure.contentsScale = entry.figure.contentsScale
        ghost.addSublayer(figure)
        let arc = CAShapeLayer()
        arc.frame = entry.arc.frame
        arc.path = entry.arc.path
        arc.fillColor = nil
        arc.lineCap = .round
        arc.lineWidth = entry.arc.lineWidth
        arc.strokeColor = entry.arc.strokeColor
        arc.strokeEnd = entry.arc.presentation()?.strokeEnd ?? entry.arc.strokeEnd
        ghost.addSublayer(picture)
        ghost.addSublayer(arc)
        ghost.opacity = 0
        host.addSublayer(ghost)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = entry.content.opacity
        fade.toValue = 0
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 0
        rise.toValue = -shift
        let group = CAAnimationGroup()
        group.animations = [fade, rise]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        ghost.add(group, forKey: "leave")
        CATransaction.commit()
    }

    /// Brings the row in where it now is, from `shift` below, once what was there has had `after` seconds to leave.
    private func enter(_ entry: Row, shift: CGFloat, after: Double) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = shift
        rise.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, rise]
        group.duration = PanelStyle.rowEnter
        group.beginTime = entry.layer.convertTime(CACurrentMediaTime(), from: nil) + after
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        entry.layer.add(group, forKey: "arrive")
    }

    private func draw(_ row: ProcessRow, in entry: Row, size: CGSize, scale: CGFloat, paint: Paint, restyled: Bool, animated: Bool) {
        let badge = CGRect(x: 0, y: (size.height - style.badge) / 2, width: style.badge, height: style.badge)
        let baseline = size.height / 2 + ceil(Typesetter.metrics(style.body).capHeight) / 2
        // The figure has the room of the widest one, so the name never moves and is drawn once.
        let unitGap = style.points(2)
        let room = ceil(
            Typesetter.line("8888", style.bodyStrong).width + unitGap + max(Typesetter.line("%", style.caption).width, Typesetter.line("M", style.caption).width))
        let stale = restyled || entry.width != size.width || entry.content.contents == nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if stale || entry.drawn?.name != row.name || entry.drawn?.appPath != row.appPath {
            let nameSize = CGSize(width: size.width - room - style.rowGap, height: size.height)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                entry.content.contents = drawnImage(size: nameSize, scale: scale) { context in
                    context.setFillColor(style.color(.badge).cgColor)
                    context.fillEllipse(in: badge)
                    AppIcons.draw(row.appPath, in: badge, style: style, fallback: style.color(.secondary).cgColor, context: context)
                    let nameLeft = badge.maxX + style.badgeLeadGap
                    let name = Typesetter.truncated(row.name, style.body, to: nameSize.width - nameLeft)
                    context.setFillColor(style.color(.ink).cgColor)
                    context.textPosition = CGPoint(x: nameLeft, y: baseline)
                    CTLineDraw(Typesetter.line(name, style.body).line, context)
                }
                entry.arc.strokeColor = style.color(paint).cgColor
                entry.highlight.backgroundColor = style.color(.badge).cgColor
            }
            entry.content.frame = CGRect(origin: .zero, size: nameSize)
            entry.content.contentsScale = scale
            entry.arc.frame = badge
            entry.arc.lineWidth = style.badgeRing
            let path = CGMutablePath()
            path.addArc(
                center: CGPoint(x: badge.width / 2, y: badge.height / 2), radius: (badge.width - style.badgeRing) / 2, startAngle: -.pi / 2,
                endAngle: .pi * 1.5, clockwise: false)
            entry.arc.path = path
        } else if entry.drawn?.share == nil {
            effectiveAppearance.performAsCurrentDrawingAppearance { entry.arc.strokeColor = style.color(paint).cgColor }
        }
        if stale || entry.drawn?.value != row.value || entry.drawn?.unit != row.unit {
            let figureSize = CGSize(width: room, height: size.height)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                entry.figure.contents = drawnImage(size: figureSize, scale: scale) { context in
                    let unit = Typesetter.line(row.unit, style.caption)
                    let value = Typesetter.line(row.value, style.bodyStrong)
                    let unitLeft = room - unit.width
                    context.setFillColor(style.color(.secondary).cgColor)
                    context.textPosition = CGPoint(x: unitLeft, y: baseline)
                    CTLineDraw(unit.line, context)
                    context.setFillColor(style.color(.ink).cgColor)
                    context.textPosition = CGPoint(x: unitLeft - unitGap - value.width, y: baseline)
                    CTLineDraw(value.line, context)
                }
            }
            entry.figure.frame = CGRect(x: size.width - room, y: 0, width: room, height: size.height)
            entry.figure.contentsScale = scale
        }
        entry.width = size.width
        let share = CGFloat(min(1, max(0, row.share)))
        if animated, entry.drawn != nil { Follow.add(to: entry.arc, "strokeEnd", from: entry.arc.strokeEnd, to: share, least: 0.004, interval: style.interval) }
        entry.arc.strokeEnd = share
        entry.drawn = row
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let current = item
        rows.values.forEach { $0.drawn = nil }
        update(current, style: style)
    }

    /// The row's frame in this view, for anchoring its card.
    func frame(of key: String) -> CGRect? { rows[key]?.layer.frame }

    /// Lights the row under the pointer and lets the others recede.
    func light(_ key: String?) {
        guard key != lit else { return }
        lit = key
        applyStates(animated: true)
    }

    /// `held` keeps a row lit while its card is open.
    func hold(_ key: String?) {
        guard key != held else { return }
        held = key
        applyStates(animated: true)
    }

    /// A row gives under the pointer and springs back when let go.
    func press(_ key: String?) {
        guard key != pressed else { return }
        if let released = pressed, let entry = rows[released] {
            let back = CASpringAnimation(keyPath: "transform.scale")
            back.fromValue = entry.layer.presentation()?.value(forKeyPath: "transform.scale") ?? PanelStyle.rowPressScale
            back.toValue = 1
            back.damping = PanelStyle.rowSpringDamping
            back.stiffness = PanelStyle.rowSpringStiffness
            back.initialVelocity = 4
            back.duration = back.settlingDuration
            if style.motion { entry.layer.add(back, forKey: "press") }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            entry.layer.setValue(1, forKeyPath: "transform.scale")
            CATransaction.commit()
        }
        pressed = key
        if let key, let entry = rows[key], style.motion {
            CATransaction.begin()
            CATransaction.setAnimationDuration(PanelStyle.rowPressDown)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            entry.layer.setValue(PanelStyle.rowPressScale, forKeyPath: "transform.scale")
            CATransaction.commit()
        }
        applyStates(animated: true)
    }

    private func applyStates(animated: Bool) {
        let focus = pressed ?? lit ?? held
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated && style.motion ? 0.16 : 0)
        if !animated || !style.motion { CATransaction.setDisableActions(true) }
        for (key, entry) in rows {
            let on = key == pressed || key == lit || key == held
            entry.highlight.opacity = key == pressed ? 1 : on ? PanelStyle.rowLitOpacity : 0
            entry.content.opacity = focus == nil || on ? 1 : PanelStyle.rowDimOpacity
            entry.figure.opacity = entry.content.opacity
            entry.arc.opacity = entry.content.opacity
        }
        CATransaction.commit()
    }
}

/// The card a click on a process row brings up: the app, its two figures, and the
/// processes folded into it. A window of its own, so the panel keeps its size and
/// nothing in it moves.
@MainActor
final class ProcessCardWindow: NSPanel {
    private let face = CardFace()
    /// Counts showings, so a card that is fading out does not put away the one shown after it.
    private var showing = 0

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = face
    }

    /// Shows `card` beside `anchor` (the row, on screen), growing out of it.
    func show(_ card: ProcessCard, style: PanelStyle, anchor: NSRect, parent: NSWindow) {
        let fresh = !isVisible || alphaValue < 1
        showing += 1
        appearance = parent.effectiveAppearance
        face.set(card, style: style)
        let size = face.fittingCardSize
        var origin = NSPoint(x: anchor.minX + style.badge + style.badgeLeadGap, y: anchor.minY - size.height - 6)
        var below = true
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            if origin.y < visible.minY + 4 {
                origin.y = anchor.maxY + 6
                below = false
            }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        }
        let frame = NSRect(origin: origin, size: size)
        if frame != self.frame { setFrame(frame, display: true) }
        if parent.childWindows?.contains(self) != true {
            level = parent.level
            parent.addChildWindow(self, ordered: .above)
        }
        guard fresh else { return }
        alphaValue = 1
        guard style.motion, let layer = face.layer else { return }
        // Grows from the corner nearest the row it belongs to.
        layer.anchorPoint = CGPoint(x: 0.1, y: below ? 1 : 0)
        layer.position = CGPoint(x: size.width * 0.1, y: below ? size.height : 0)
        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.fromValue = PanelStyle.cardStartScale
        grow.toValue = 1
        grow.damping = PanelStyle.rowSpringDamping
        grow.stiffness = PanelStyle.rowSpringStiffness
        grow.duration = grow.settlingDuration
        layer.add(grow, forKey: "grow")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = 0.12
        layer.add(fade, forKey: "fade")
    }

    func dismiss(animated: Bool) {
        guard isVisible else { return }
        guard animated else { return putAway() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelStyle.cardLeave
            animator().alphaValue = 0
        } completionHandler: { [weak self, showing] in
            MainActor.assumeIsolated {
                if self?.showing == showing { self?.putAway() }
            }
        }
    }

    private func putAway() {
        parent?.removeChildWindow(self)
        orderOut(nil)
        alphaValue = 1
    }
}

@MainActor
/// The card's contents on their own, for pictures made from the panel's drawing code.
public enum ProcessCardPicture {
    public static func view(_ card: ProcessCard, palette: PaletteID = .sea) -> NSView {
        let face = CardFace()
        face.set(card, style: PanelStyle(palette: palette))
        face.frame = NSRect(origin: .zero, size: face.fittingCardSize)
        return face
    }
}

@MainActor
private final class CardFace: NSView {
    private var card: ProcessCard?
    private var style = PanelStyle()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var pad: CGFloat { 14 }
    private var icon: CGFloat { 30 }
    private var rowPitch: CGFloat { 19 }
    /// The card is drawn at the panel's base sizes whatever the panel's scale: it is read up close.
    private var base: PanelStyle { PanelStyle(scale: 1, palette: style.palette, motion: style.motion, interval: style.interval) }

    func set(_ new: ProcessCard, style newStyle: PanelStyle) {
        guard new != card || newStyle.palette != style.palette else { return }
        card = new
        style = newStyle
        needsDisplay = true
    }

    var fittingCardSize: NSSize {
        guard let card else { return .zero }
        let style = base
        let title = Typesetter.width(card.name, style.bodyStrong)
        let figures = (style.badge + style.badgeGap) * 2 + Typesetter.width("888.8 %", style.bodyStrong) * 2 + 18
        let members = card.members.map { Typesetter.width($0.name, style.caption) + 70 }.max() ?? 0
        let width = min(280, max(190, pad * 2 + max(icon + 10 + title, figures, members)))
        let height = pad * 2 + icon + 12 + style.badge + (card.members.isEmpty ? 0 : 12 + CGFloat(card.members.count) * rowPitch - 6)
        return NSSize(width: ceil(width), height: ceil(height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let card, let context = NSGraphicsContext.current?.cgContext else { return }
        let style = base
        let bounds = self.bounds
        let shape = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 14, cornerHeight: 14, transform: nil)
        context.addPath(shape)
        context.setFillColor(PanelStyle.cardColor.cgColor)
        context.fillPath()
        context.addPath(shape)
        context.setStrokeColor(PanelStyle.cardEdgeColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        func text(_ string: String, _ font: FontSpec, _ paint: Paint, x: CGFloat, baseline: CGFloat, trailing: Bool = false) -> CGFloat {
            let line = Typesetter.line(string, font)
            context.setFillColor(style.color(paint).cgColor)
            context.textPosition = CGPoint(x: trailing ? x - line.width : x, y: baseline)
            CTLineDraw(line.line, context)
            return line.width
        }
        func cap(_ font: FontSpec) -> CGFloat { ceil(Typesetter.metrics(font).capHeight) }

        let iconBox = CGRect(x: pad, y: pad, width: icon, height: icon)
        if let path = card.appPath, let image = AppIcons.image(for: path) {
            context.saveGState()
            context.translateBy(x: iconBox.minX, y: iconBox.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: iconBox.size))
            context.restoreGState()
        } else {
            context.setFillColor(style.color(.badge).cgColor)
            context.fillEllipse(in: iconBox)
            GlyphArt.draw(.process, in: iconBox.insetBy(dx: 8, dy: 8), color: style.color(.secondary).cgColor, context: context)
        }
        let room = bounds.width - pad - iconBox.maxX - 10
        _ = text(
            Typesetter.truncated(card.name, style.bodyStrong, to: room), style.bodyStrong, .ink, x: iconBox.maxX + 10, baseline: iconBox.midY + cap(style.bodyStrong) / 2)

        // The same two badges as in the panel: processor, then memory.
        let middle = iconBox.maxY + 12 + style.badge / 2
        var x = pad
        for (glyph, paint, value, unit, share) in [
            (Glyph.cpu, Paint.performance, card.cpu, "%", card.cpuShare),
            (.memory, PanelStyle.pressurePaint(.normal), card.memory, card.memoryUnit + "B", card.memoryShare),
        ] {
            let badge = CGRect(x: x, y: middle - style.badge / 2, width: style.badge, height: style.badge)
            context.setFillColor(style.color(.badge).cgColor)
            context.fillEllipse(in: badge)
            let side = style.badgeGlyph
            GlyphArt.draw(
                glyph, in: CGRect(x: badge.midX - side / 2, y: badge.midY - side / 2, width: side, height: side), color: style.color(paint).cgColor, context: context)
            let line = style.badgeRing
            let arc = CGMutablePath()
            let turn = CGFloat(min(1, max(0, share))) * 2 * .pi
            arc.addArc(center: CGPoint(x: badge.midX, y: badge.midY), radius: (badge.width - line) / 2, startAngle: -.pi / 2, endAngle: -.pi / 2 + turn, clockwise: false)
            context.addPath(arc)
            context.setStrokeColor(style.color(paint).cgColor)
            context.setLineWidth(line)
            context.setLineCap(.round)
            context.strokePath()
            let baseline = middle + cap(style.bodyStrong) / 2
            let left = badge.maxX + style.badgeGap
            let width = text(value, style.bodyStrong, .ink, x: left, baseline: baseline)
            let unitWidth = text(unit, style.caption, .secondary, x: left + width + 3, baseline: baseline)
            x = left + width + 3 + unitWidth + 18
        }

        var baseline = middle + style.badge / 2 + 12 + cap(style.caption)
        for member in card.members {
            let unitWidth = text(member.unit, style.caption, .secondary, x: bounds.width - pad, baseline: baseline, trailing: true)
            let valueWidth = text(member.value, style.captionStrong, .ink, x: bounds.width - pad - unitWidth - 2, baseline: baseline, trailing: true)
            let nameRoom = bounds.width - pad * 2 - unitWidth - valueWidth - 12
            _ = text(Typesetter.truncated(member.name, style.caption, to: nameRoom), style.caption, .secondary, x: pad, baseline: baseline)
            baseline += rowPitch
        }
    }
}
