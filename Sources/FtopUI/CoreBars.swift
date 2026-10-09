import AppKit
import FtopCore

/// The core columns, drawn with Core Animation layers.
///
/// How a layer follows a reading. The new value is set at once and an animation plays
/// back the difference; animations that overlap add up, so a layer that is still moving
/// when the next reading lands keeps its speed instead of stopping and starting again.
/// They run in the system's render server at the display's refresh rate.
@MainActor
enum Follow {
    /// What is left of a move, from all of it to none, sampled evenly over its length.
    /// The curve leaves and arrives with no speed and no acceleration, which is what
    /// lets moves that overlap add up without a visible seam.
    private static let remaining: [Double] = {
        let last = 32
        return (0...last).map { step in
            guard step < last else { return 0 }
            let x = span * Double(step) / Double(last)
            return (1 + x + x * x / 2) * exp(-x)
        }
    }()
    /// Length of a move in time constants; what is left after this is under a thousandth.
    private static let span: Double = 12

    /// `least` is the smallest move worth animating, in the key path's own units.
    static func add(to layer: CALayer, _ keyPath: String, from old: CGFloat, to new: CGFloat, least: CGFloat = 0.25, delay: Double = 0, interval: Double) {
        let move = old - new
        guard abs(move) > least else { return }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = remaining.map { move * $0 }
        animation.calculationMode = .cubic
        animation.isAdditive = true
        animation.duration = span / PanelStyle.columnFollowRate * min(max(interval, 0.25), PanelStyle.columnFollowLongestInterval)
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        // Hold the old place until this layer's turn in the wave.
        animation.fillMode = .backwards
        layer.add(animation, forKey: nil)
    }
}

/// The arcs of the ring badges, one layer each.
final class ArcsView: NSView {
    private var layers: [CAShapeLayer] = []
    private var items: [ArcItem] = []
    private var style = PanelStyle()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ new: [ArcItem], style newStyle: PanelStyle) {
        let moved = new.map(\.rect) != items.map(\.rect) || newStyle.scale != style.scale
        let recolored = moved || new.map(\.paint) != items.map(\.paint) || newStyle.palette != style.palette
        items = new
        style = newStyle
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layers.count != new.count {
            layers.forEach { $0.removeFromSuperlayer() }
            layers = new.map { _ in
                let arc = CAShapeLayer()
                arc.fillColor = nil
                arc.lineCap = .round
                layer?.addSublayer(arc)
                return arc
            }
        }
        for (arc, item) in zip(layers, new) {
            if moved {
                arc.removeAllAnimations()
                arc.frame = item.rect
                arc.lineWidth = style.badgeRing
                let radius = (item.rect.width - style.badgeRing) / 2
                let path = CGMutablePath()
                // From the top, clockwise as seen on screen.
                path.addArc(
                    center: CGPoint(x: item.rect.width / 2, y: item.rect.height / 2), radius: radius, startAngle: -.pi / 2, endAngle: .pi * 1.5,
                    clockwise: false)
                arc.path = path
            }
            let fraction = CGFloat(min(1, max(0, item.fraction)))
            if style.motion && !moved {
                Follow.add(to: arc, "strokeEnd", from: arc.strokeEnd, to: fraction, least: 0.004, interval: style.interval)
            }
            arc.strokeEnd = fraction
        }
        CATransaction.commit()
        if recolored { applyColors() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (arc, item) in zip(layers, items) { arc.strokeColor = style.color(item.paint).cgColor }
            CATransaction.commit()
        }
    }
}

/// Each column is a capsule track with a capsule fill that slides up from below it.
/// A new reading moves the fill with `Follow`; the app does no per-frame work.
final class CoreBarsView: NSView {
    private struct Column {
        let track = CALayer()
        let fill = CALayer()
        let tick = CALayer()
    }

    private var columns: [Column] = []
    private var item: BarsItem?
    private var style = PanelStyle()
    private var highlighted: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The canvas handles the pointer for the whole panel.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ item: BarsItem, style: PanelStyle) {
        let old = self.item
        let structureChanged =
            old == nil || old!.cores.map(\.group) != item.cores.map(\.group) || old!.rect.size != item.rect.size || old!.gap != item.gap
            || old!.groupGap != item.groupGap || old!.showsFrequency != item.showsFrequency || old!.paint != item.paint || style.scale != self.style.scale
        let paletteChanged = style.palette != self.style.palette
        self.item = item
        self.style = style

        if columns.count != item.cores.count {
            columns.forEach { $0.track.removeFromSuperlayer() }
            columns = (0..<item.cores.count).map { _ in
                let column = Column()
                column.track.masksToBounds = true
                column.track.addSublayer(column.fill)
                column.track.addSublayer(column.tick)
                layer?.addSublayer(column.track)
                return column
            }
        }
        if structureChanged || paletteChanged {
            applyColors()
            layoutColumns()
        }
        applyValues(animated: style.motion && !structureChanged)
    }

    func highlight(_ index: Int?) {
        guard index != highlighted else { return }
        highlighted = index
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        for (position, column) in columns.enumerated() {
            column.track.opacity = index == nil || index == position ? 1 : 0.4
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutColumns()
        applyValues(animated: false)
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func layoutColumns() {
        guard let item else { return }
        let slots = CoreBarsGeometry.slots(
            groups: item.cores.map(\.group), width: item.rect.width, gap: item.gap, groupGap: item.groupGap)
        withoutAnimation {
            for (index, slot) in slots.enumerated() where index < columns.count {
                let column = columns[index]
                // Snap to device pixels so thin columns keep their gaps.
                let pixel = 1 / (window?.backingScaleFactor ?? 2)
                let left = (slot.x / pixel).rounded() * pixel
                let width = max(pixel, (slot.width / pixel).rounded() * pixel)
                let radius = min(style.coreRadiusLimit, width / 2)
                column.track.removeAllAnimations()
                column.fill.removeAllAnimations()
                column.tick.removeAllAnimations()
                column.track.frame = CGRect(x: left, y: 0, width: width, height: item.rect.height)
                column.track.cornerRadius = radius
                column.track.cornerCurve = .continuous
                // The fill is as tall as the track and slides; its rounded top is the reading.
                column.fill.bounds = CGRect(x: 0, y: 0, width: width, height: item.rect.height)
                column.fill.cornerRadius = radius
                column.fill.cornerCurve = .continuous
                let inset = (width * PanelStyle.coreTickInset / pixel).rounded() * pixel
                column.tick.bounds = CGRect(x: 0, y: 0, width: max(pixel, width - inset * 2), height: style.coreTickHeight)
                column.tick.cornerRadius = style.coreTickHeight / 2
            }
        }
    }

    private func applyColors() {
        guard let item else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            withoutAnimation {
                let count = (item.cores.map(\.group).max() ?? 0) + 1
                for (index, column) in columns.enumerated() {
                    let paint = item.paint ?? Paint.core(group: item.cores[index].group, of: count)
                    column.track.backgroundColor = PanelStyle.coreTrackColor.cgColor
                    column.fill.backgroundColor = style.color(paint).cgColor
                    column.tick.backgroundColor = style.color(.ink).withAlphaComponent(0.8).cgColor
                }
            }
        }
    }

    private func applyValues(animated: Bool) {
        guard let item else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, column) in columns.enumerated() {
            let size = column.track.bounds.size
            let usage = item.cores[index].usage
            let frequency = item.cores[index].frequencyFraction
            let delay = Double(index) * PanelStyle.columnStagger
            // Layers use a bottom-left origin here, so a column grows upward from y = 0.
            let height = max(size.height * min(1, max(0, usage)), min(size.width, style.coreRestHeight))
            let fill = CGPoint(x: size.width / 2, y: height - size.height / 2)
            if animated { Follow.add(to: column.fill, "position.y", from: column.fill.position.y, to: fill.y, delay: delay, interval: style.interval) }
            column.fill.position = fill
            if item.showsFrequency, let fraction = frequency {
                let tickHeight = column.tick.bounds.height
                let tick = CGPoint(x: size.width / 2, y: tickHeight / 2 + (size.height - tickHeight) * fraction)
                if animated && !column.tick.isHidden {
                    Follow.add(to: column.tick, "position.y", from: column.tick.position.y, to: tick.y, delay: delay, interval: style.interval)
                }
                column.tick.isHidden = false
                column.tick.position = tick
            } else {
                column.tick.isHidden = true
            }
        }
        CATransaction.commit()
    }
}
