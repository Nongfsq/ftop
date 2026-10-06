import AppKit
import FtopCore

/// The core columns, drawn with Core Animation layers.
///
/// Layer animations run in the system's render server, so columns ease to each new
/// reading without the app doing per-frame work.
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
            old == nil || old!.cores.map(\.kind) != item.cores.map(\.kind) || old!.rect.size != item.rect.size || old!.gap != item.gap
            || old!.groupGap != item.groupGap || old!.showsFrequency != item.showsFrequency || style.scale != self.style.scale
        let paletteChanged = style.palette != self.style.palette
        self.item = item
        self.style = style

        if columns.count != item.cores.count {
            columns.forEach { $0.track.removeFromSuperlayer() }
            columns = item.cores.map { _ in
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
        let slots = CoreBarsGeometry.slots(kinds: item.cores.map(\.kind), width: item.rect.width, gap: item.gap, groupGap: item.groupGap)
        withoutAnimation {
            for (index, slot) in slots.enumerated() where index < columns.count {
                // Efficiency cores are drawn slimmer inside the same slot.
                let width = item.cores[index].kind == .efficiency ? max(2, slot.width * 0.58) : slot.width
                // Snap to device pixels so thin columns keep their gaps.
                let pixel = 1 / (window?.backingScaleFactor ?? 2)
                let left = ((slot.x + slot.width / 2 - width / 2) / pixel).rounded() * pixel
                let frame = CGRect(x: left, y: 0, width: max(pixel, (width / pixel).rounded() * pixel), height: item.rect.height)
                columns[index].track.frame = frame
                columns[index].track.cornerRadius = min(4 * style.scale, frame.width / 2.5)
                columns[index].track.cornerCurve = .continuous
            }
        }
    }

    private func applyColors() {
        guard let item else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            withoutAnimation {
                for (index, column) in columns.enumerated() where index < item.cores.count {
                    column.track.backgroundColor = style.color(.track).cgColor
                    column.fill.backgroundColor = style.color(item.cores[index].kind == .performance ? .performance : .efficiency).cgColor
                    column.tick.backgroundColor = style.color(.ink).withAlphaComponent(0.8).cgColor
                }
            }
        }
    }

    private func applyValues(animated: Bool) {
        guard let item else { return }
        CATransaction.begin()
        if animated {
            // A soft start and a long settle, most of the way to the next reading, then rest.
            CATransaction.setAnimationDuration(min(0.7, style.interval * 0.7))
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 0, 0.15, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        let tickHeight = max(1.5, 2 * style.scale)
        for (index, column) in columns.enumerated() where index < item.cores.count {
            let size = column.track.bounds.size
            let core = item.cores[index]
            // Layers use a bottom-left origin here, so a column grows upward from y = 0.
            column.fill.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height * core.usage)
            if item.showsFrequency, let fraction = core.frequencyFraction {
                column.tick.isHidden = false
                column.tick.frame = CGRect(x: 0, y: (size.height - tickHeight) * fraction, width: size.width, height: tickHeight)
            } else {
                column.tick.isHidden = true
            }
        }
        CATransaction.commit()
    }
}
