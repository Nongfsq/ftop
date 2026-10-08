import AppKit
import FtopCore

/// The one place every setting lives: a small floating block of round switches that a
/// right-click on the panel or on the menu bar number brings up. "More" opens the few
/// settings that have a value instead of a switch. A change is written to the settings
/// file and applied at once.
@MainActor
public final class ControlPanel: NSObject {
    /// What the block shows besides the settings themselves.
    public struct State: Equatable {
        public var config: Config
        public var panelVisible: Bool
        /// Modules that are on but that this machine gives no reading for.
        public var unreadable: Set<ModuleID>
        /// The installed version and what the last check found.
        public var updateStatus: String
        /// What the update action does now: check, or install what was found.
        public var updateAction: String

        public init(config: Config, panelVisible: Bool = true, unreadable: Set<ModuleID> = [], updateStatus: String = "", updateAction: String = "") {
            self.config = config
            self.panelVisible = panelVisible
            self.unreadable = unreadable
            self.updateStatus = updateStatus
            self.updateAction = updateAction
        }
    }

    /// Called with the new settings and the one `key: value` line that changed.
    public var onChange: ((Config, String, String) -> Void)?
    public var onTogglePanel: (() -> Void)?
    public var onQuit: (() -> Void)?
    public var onOpenFile: (() -> Void)?
    public var onUpdate: (() -> Void)?

    private let window = ControlWindow()
    private let face: ControlFace
    private var monitors: [Any] = []

    public init(state: State) {
        face = ControlFace(state: state)
        super.init()
        let glass = NSVisualEffectView()
        glass.material = .menu
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = PanelStyle.controlCorner
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        face.autoresizingMask = [.width, .height]
        glass.addSubview(face)
        window.contentView = glass
        face.onChange = { [weak self] config, key, value in self?.onChange?(config, key, value) }
        face.onResize = { [weak self] in self?.fit(keepingTop: true) }
        face.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .togglePanel:
                dismiss()
                onTogglePanel?()
            case .quit: onQuit?()
            case .openFile:
                dismiss()
                onOpenFile?()
            case .update: onUpdate?()
            }
        }
    }

    public var isShown: Bool { window.isVisible }

    /// Shows the block with its top-left corner at `point`, in screen coordinates, moved as needed to stay on screen.
    public func show(_ state: State, at point: NSPoint) {
        face.collapse()
        face.apply(state)
        window.appearance = NSApp.effectiveAppearance
        window.setFrame(NSRect(origin: point, size: face.fittingSize), display: false)
        window.setFrameTopLeftPoint(point)
        fit(keepingTop: true)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelStyle.controlAppear
            window.animator().alphaValue = 1
        }
        watch()
    }

    /// Reflects a change made elsewhere: the pin button, the file, an update check.
    public func refresh(_ state: State) {
        guard window.isVisible else { return }
        face.apply(state)
        fit(keepingTop: true)
    }

    public func dismiss() {
        guard window.isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelStyle.controlLeave
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Shown again in the meantime: leave it.
                if self?.monitors.isEmpty == true { self?.window.orderOut(nil) }
            }
        }
    }

    private func fit(keepingTop: Bool) {
        let size = face.fittingSize
        var frame = window.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        if let visible = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.maxY - 1)) } ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 6), visible.maxX - frame.width - 6)
            frame.origin.y = min(max(frame.minY, visible.minY + 6), visible.maxY - frame.height - 6)
        }
        if frame != window.frame { window.setFrame(frame, display: true) }
        face.frame = NSRect(origin: .zero, size: size)
    }

    /// A click anywhere else, or Escape, puts the block away.
    private func watch() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissUnlessChoosing() }
        }
        let inside = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let escape = event.type == .keyDown && event.keyCode == 53
            let key = event.type == .keyDown
            let number = event.windowNumber
            return MainActor.assumeIsolated { self?.handled(key: key, escape: escape, windowNumber: number) ?? false } ? nil : event
        }
        monitors = [outside, inside].compactMap { $0 }
    }

    /// True when the event was Escape and is used up.
    private func handled(key: Bool, escape: Bool, windowNumber: Int) -> Bool {
        if key {
            if escape { dismiss() }
            return escape
        }
        if windowNumber != window.windowNumber { dismissUnlessChoosing() }
        return false
    }

    private func dismissUnlessChoosing() {
        // A value's menu is open over the block; picking from it is not a click elsewhere.
        if !face.choosing { dismiss() }
    }

    public static func name(of module: ModuleID) -> String {
        switch module {
        case .cpu: "CPU"
        case .memory: Strings.pick("Memory", "内存")
        case .network: Strings.pick("Network", "网络")
        case .processes: Strings.pick("Processes", "进程")
        case .gpu: "GPU"
        case .power: Strings.pick("Power", "功耗")
        }
    }

    /// The block's contents on their own, for the reference pictures.
    public static func picture(_ state: State, expanded: Bool) -> NSView {
        let face = ControlFace(state: state)
        if expanded { face.expand() }
        face.frame = NSRect(origin: .zero, size: face.fittingSize)
        return face
    }
}

private final class ControlWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
    }

    // Key without bringing the app forward, so Escape reaches it.
    override var canBecomeKey: Bool { true }
}

/// The switches and rows of the control block, as layers.
@MainActor
final class ControlFace: NSView {
    enum Action { case togglePanel, quit, openFile, update }

    private enum Item: Hashable {
        case module(ModuleID), floating, menuBar, motion, panel, quit, palette(PaletteID), more
        case interval, rows, language, updates, file
    }

    private final class Disc {
        let item: Item
        let layer = CALayer()
        let base = CALayer()
        let fill = CALayer()
        let glyph = CALayer()
        let label = CATextLayer()
        var cell = CGRect.zero
        init(_ item: Item) { self.item = item }
    }

    private final class Row {
        let item: Item
        let highlight = CALayer()
        let title = CATextLayer()
        let value = CATextLayer()
        var frame = CGRect.zero
        init(_ item: Item) { self.item = item }
    }

    var onChange: ((Config, String, String) -> Void)?
    var onAction: ((Action) -> Void)?
    var onResize: (() -> Void)?
    /// True while a value's menu is open.
    private(set) var choosing = false

    private var state: ControlPanel.State
    private var expanded = false
    private var discs: [Disc] = []
    private var rows: [Row] = []
    private let ring = CAShapeLayer()
    private var hovered: Item?
    private var pressed: Item?
    private var tracking: NSTrackingArea?

    private static let intervals: [Double] = [0.5, 1, 2, 5, 10]
    private static let rowCounts = [3, 5, 7, 9, 12, 16, 24]
    private static let languages: [Language] = [.auto, .en, .zh]

    private var config: Config { state.config }
    private var style: PanelStyle { PanelStyle(palette: config.palette) }
    private var calm: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(state: ControlPanel.State) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Contents

    private var grid: [[Item]] {
        [
            Config.optional.map { .module($0) },
            [.floating, .menuBar, .motion, .panel, .quit],
            PaletteID.allCases.map { .palette($0) },
        ]
    }

    private static let listed: [Item] = [.interval, .rows, .language, .updates, .file]

    override var fittingSize: NSSize {
        let width = PanelStyle.controlPadding * 2 + PanelStyle.controlPitchX * 4 + PanelStyle.controlDisc
        let cellHeight = PanelStyle.controlDisc + PanelStyle.controlLabelGap + PanelStyle.controlLabelHeight
        var height = PanelStyle.controlPadding + PanelStyle.controlRowPitch * 2 + cellHeight + PanelStyle.controlPadding - 4
        if expanded { height += PanelStyle.controlListRow * CGFloat(Self.listed.count) + PanelStyle.controlListGap }
        return NSSize(width: width, height: height)
    }

    func apply(_ new: ControlPanel.State) {
        guard new != state else { return }
        state = new
        build()
    }

    func collapse() {
        guard expanded else { return }
        expanded = false
        build()
    }

    func expand() {
        guard !expanded else { return }
        expanded = true
        build()
    }

    private func isOn(_ item: Item) -> Bool {
        switch item {
        case .module(let module): config.shown.contains(module)
        case .floating: config.floating
        case .menuBar: config.menuBar
        case .motion: config.motion
        default: false
        }
    }

    private func isSwitch(_ item: Item) -> Bool {
        switch item {
        case .module, .floating, .menuBar, .motion: true
        default: false
        }
    }

    private func label(_ item: Item) -> String {
        switch item {
        case .module(let module): ControlPanel.name(of: module)
        case .floating: Strings.pick("On Top", "置顶")
        case .menuBar: Strings.pick("Menu Bar", "菜单栏")
        case .motion: Strings.pick("Smooth", "平滑")
        case .panel: state.panelVisible ? Strings.pick("Hide", "收起") : Strings.pick("Show", "显示")
        case .quit: Strings.pick("Quit", "退出")
        case .palette(let palette): palette.displayName
        case .more: Strings.pick("More", "更多")
        case .interval: Strings.pick("Update every", "刷新间隔")
        case .rows: Strings.pick("Process rows, up to", "进程行数上限")
        case .language: Strings.pick("Language", "语言")
        case .updates: Strings.pick("Updates", "更新")
        case .file: Strings.pick("Open settings file", "打开设置文件")
        }
    }

    private func symbol(_ item: Item) -> String? {
        switch item {
        case .module(.network): "arrow.up.arrow.down"
        case .module(.power): "bolt.fill"
        case .module(.processes): "list.bullet"
        case .floating: "pin"
        case .menuBar: "menubar.rectangle"
        case .motion: "alternatingcurrent"
        case .panel: state.panelVisible ? "eye.slash" : "eye"
        case .quit: "power"
        case .more: expanded ? "chevron.up" : "chevron.down"
        default: nil
        }
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func seconds(_ value: Double) -> String { Strings.pick("\(trim(value)) s", "\(trim(value)) 秒") }

    private static func name(of language: Language) -> String {
        switch language {
        case .auto: Strings.pick("System", "跟随系统")
        case .en: "English"
        case .zh: "中文"
        }
    }

    private static func name(of mode: UpdateMode) -> String {
        switch mode {
        case .install: Strings.pick("Install automatically", "自动安装")
        case .check: Strings.pick("Tell me", "仅提示")
        case .off: Strings.pick("Never check", "不检查")
        }
    }

    private func value(_ item: Item) -> String {
        switch item {
        case .interval: Self.seconds(config.interval) + "  ›"
        case .rows: "\(config.maxProcesses)  ›"
        case .language: Self.name(of: config.language) + "  ›"
        case .updates: updatesValue + "  ›"
        case .file: "↗"
        default: ""
        }
    }

    /// The mode and what the last check found; the mode alone gives way when both do not fit.
    private var updatesValue: String {
        let mode = Self.name(of: config.updates)
        guard !state.updateStatus.isEmpty else { return mode }
        let both = mode + " · " + state.updateStatus
        func width(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
        }
        let room = fittingSize.width - PanelStyle.controlPadding * 2 - width(label(.updates), PanelStyle.controlTitleSize, .medium) - 12
        return width(both + "  ›", PanelStyle.controlValueSize, .regular) <= room ? both : state.updateStatus
    }

    // MARK: Layers

    private func build() {
        guard let host = layer else { return }
        host.sublayers?.forEach { $0.removeFromSuperlayer() }
        discs = []
        rows = []
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let disc = PanelStyle.controlDisc
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.fillColor = nil
            ring.lineWidth = PanelStyle.controlRingLine
            ring.strokeColor = PanelStyle.inkColor.cgColor
            let reach = disc / 2 + PanelStyle.controlRingGap + PanelStyle.controlRingLine / 2
            ring.bounds = CGRect(x: 0, y: 0, width: reach * 2, height: reach * 2)
            ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
            host.addSublayer(ring)

            var layout = grid
            layout[2].append(.more)
            for (rowIndex, items) in layout.enumerated() {
                for (index, item) in items.enumerated() {
                    // "More" sits in the last column, under Quit.
                    let column = item == .more ? 4 : index
                    let origin = CGPoint(
                        x: PanelStyle.controlPadding + CGFloat(column) * PanelStyle.controlPitchX,
                        y: PanelStyle.controlPadding + CGFloat(rowIndex) * PanelStyle.controlRowPitch)
                    let entry = Disc(item)
                    entry.layer.frame = CGRect(origin: origin, size: CGSize(width: disc, height: disc))
                    entry.cell = CGRect(
                        x: origin.x - (PanelStyle.controlPitchX - disc) / 2, y: origin.y - 6, width: PanelStyle.controlPitchX,
                        height: disc + PanelStyle.controlLabelGap + PanelStyle.controlLabelHeight + 10)
                    for part in [entry.base, entry.fill] {
                        part.frame = entry.layer.bounds
                        part.cornerRadius = disc / 2
                        entry.layer.addSublayer(part)
                    }
                    if case .palette(let palette) = item {
                        let colors = PanelStyle(palette: palette)
                        let wash = CAGradientLayer()
                        wash.frame = entry.layer.bounds
                        wash.cornerRadius = disc / 2
                        wash.startPoint = CGPoint(x: 0.15, y: 0.15)
                        wash.endPoint = CGPoint(x: 0.85, y: 0.85)
                        wash.colors = [colors.performanceColor.cgColor, colors.performanceColor.cgColor, colors.efficiencyColor.cgColor, colors.efficiencyColor.cgColor]
                        wash.locations = [0, 0.5, 0.5, 1]
                        entry.layer.addSublayer(wash)
                        if palette == config.palette { ring.position = CGPoint(x: origin.x + disc / 2, y: origin.y + disc / 2) }
                    } else {
                        let side = PanelStyle.controlGlyph
                        let box = CGRect(x: (disc - side) / 2, y: (disc - side) / 2, width: side, height: side)
                        let mask = CALayer()
                        mask.frame = CGRect(origin: .zero, size: box.size)
                        mask.contents = glyphImage(item, side: side, scale: scale)
                        mask.contentsScale = scale
                        entry.glyph.frame = box
                        entry.glyph.mask = mask
                        entry.layer.addSublayer(entry.glyph)
                    }
                    entry.label.string = label(item)
                    entry.label.font = NSFont.systemFont(ofSize: PanelStyle.controlLabelSize, weight: .medium)
                    entry.label.fontSize = PanelStyle.controlLabelSize
                    entry.label.alignmentMode = .center
                    entry.label.contentsScale = scale
                    entry.label.frame = CGRect(
                        x: entry.cell.minX - 4, y: origin.y + disc + PanelStyle.controlLabelGap, width: entry.cell.width + 8, height: PanelStyle.controlLabelHeight)
                    host.addSublayer(entry.layer)
                    host.addSublayer(entry.label)
                    discs.append(entry)
                }
            }

            guard expanded else { return }
            let top =
                PanelStyle.controlPadding + PanelStyle.controlRowPitch * 2 + disc + PanelStyle.controlLabelGap + PanelStyle.controlLabelHeight + PanelStyle.controlListGap
            let width = fittingSize.width
            for (index, item) in Self.listed.enumerated() {
                let row = Row(item)
                row.frame = CGRect(x: 0, y: top + CGFloat(index) * PanelStyle.controlListRow, width: width, height: PanelStyle.controlListRow)
                row.highlight.frame = row.frame.insetBy(dx: PanelStyle.controlPadding - 10, dy: 1)
                row.highlight.cornerRadius = 8
                row.highlight.cornerCurve = .continuous
                row.highlight.backgroundColor = PanelStyle.controlDiscColor.cgColor
                row.highlight.opacity = 0
                host.addSublayer(row.highlight)
                let inner = row.frame.insetBy(dx: PanelStyle.controlPadding, dy: 0)
                for (text, string, size, weight, paint) in [
                    (row.title, label(item), PanelStyle.controlTitleSize, NSFont.Weight.medium, PanelStyle.inkColor),
                    (row.value, value(item), PanelStyle.controlValueSize, NSFont.Weight.regular, PanelStyle.secondaryColor),
                ] {
                    let font = NSFont.systemFont(ofSize: size, weight: weight)
                    text.string = string
                    text.font = font
                    text.fontSize = size
                    text.foregroundColor = paint.cgColor
                    text.contentsScale = scale
                    text.truncationMode = .middle
                    let height = ceil(font.ascender - font.descender)
                    text.frame = CGRect(x: inner.minX, y: inner.midY - height / 2, width: inner.width, height: height)
                    host.addSublayer(text)
                }
                // The value takes what the title leaves.
                let titleWidth = ceil(
                    (label(item) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: PanelStyle.controlTitleSize, weight: .medium)]).width)
                row.value.alignmentMode = .right
                row.value.frame.origin.x = inner.minX + titleWidth + 12
                row.value.frame.size.width = inner.width - titleWidth - 12
                rows.append(row)
            }
        }
        CATransaction.commit()
        paint(animated: false)
        if expanded, !calm {
            for row in rows {
                for part in [row.title, row.value] {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.duration = PanelStyle.controlAppear
                    part.add(fade, forKey: "open")
                }
            }
        }
    }

    /// The glyph as a mask: its color is the layer's, so it can change smoothly.
    private func glyphImage(_ item: Item, side: CGFloat, scale: CGFloat) -> CGImage? {
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        return drawnImage(size: box.size, scale: scale) { context in
            let black = CGColor(gray: 0, alpha: 1)
            switch item {
            case .module(.memory): GlyphArt.draw(.memory, in: box, color: black, context: context)
            case .module(.gpu): GlyphArt.draw(.gpu, in: box, color: black, context: context)
            default:
                guard let name = symbol(item) else { return }
                let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .semibold)
                let image =
                    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
                    ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
                guard let image else { return }
                var proposed = CGRect(origin: .zero, size: CGSize(width: image.size.width * 4, height: image.size.height * 4))
                guard let whole = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil), let inked = GlyphArt.trimmed(whole) else { return }
                let fit = side / CGFloat(max(inked.width, inked.height))
                let size = CGSize(width: CGFloat(inked.width) * fit, height: CGFloat(inked.height) * fit)
                context.translateBy(x: (side - size.width) / 2, y: (side + size.height) / 2)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(inked, in: CGRect(origin: .zero, size: size))
            }
        }
    }

    /// Colors and fills for what is on, under the pointer, or unreadable.
    private func paint(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? PanelStyle.controlTint : 0)
        if !animated { CATransaction.setDisableActions(true) }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for entry in discs {
                let on = isOn(entry.item)
                let over = hovered == entry.item
                var dim = false
                if case .module(let module) = entry.item { dim = state.unreadable.contains(module) }
                entry.base.backgroundColor = (over ? PanelStyle.controlDiscHoverColor : PanelStyle.controlDiscColor).cgColor
                entry.fill.backgroundColor = style.performanceColor.cgColor
                let filled = on && !dim
                entry.fill.setValue(filled ? 1 : 0, forKeyPath: "transform.scale")
                entry.fill.opacity = filled ? 1 : 0
                entry.glyph.backgroundColor = (filled ? PanelStyle.toggleInkColor : over ? PanelStyle.inkColor : PanelStyle.secondaryColor).cgColor
                entry.glyph.opacity = dim ? PanelStyle.controlDimOpacity : 1
                var strong = on || over
                if case .palette(let palette) = entry.item { strong = palette == config.palette || over }
                entry.label.foregroundColor = (strong ? PanelStyle.inkColor : PanelStyle.secondaryColor).cgColor
            }
            for row in rows { row.highlight.opacity = hovered == row.item ? 1 : 0 }
        }
        CATransaction.commit()
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func item(at point: CGPoint) -> Item? {
        discs.first { $0.cell.contains(point) }?.item ?? rows.first { $0.frame.contains(point) }?.item
    }

    private func hover(_ item: Item?) {
        guard item != hovered else { return }
        hovered = item
        paint(animated: true)
    }

    override func mouseMoved(with event: NSEvent) { hover(item(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { hover(nil) }

    override func mouseDown(with event: NSEvent) {
        pressed = item(at: convert(event.locationInWindow, from: nil))
        if let entry = discs.first(where: { $0.item == pressed }) { squeeze(entry, down: true) }
    }

    override func mouseUp(with event: NSEvent) {
        let item = pressed
        pressed = nil
        if let entry = discs.first(where: { $0.item == item }) { squeeze(entry, down: false) }
        guard let item, self.item(at: convert(event.locationInWindow, from: nil)) == item else { return }
        activate(item)
    }

    /// A disc gives under the pointer and comes back when let go.
    private func squeeze(_ entry: Disc, down: Bool) {
        guard !calm else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(down ? PanelStyle.rowPressDown : PanelStyle.controlTint)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        entry.layer.setValue(down ? PanelStyle.controlPressScale : 1, forKeyPath: "transform.scale")
        CATransaction.commit()
    }

    // MARK: Changes

    private func activate(_ item: Item) {
        switch item {
        case .module(let module):
            let line = state.config.setShown(module, !config.shown.contains(module))
            flipped(item, line.key, line.value)
        case .floating:
            state.config.floating.toggle()
            flipped(item, "floating", config.floating ? "true" : "false")
        case .menuBar:
            state.config.menuBar.toggle()
            flipped(item, "menuBar", config.menuBar ? "true" : "false")
        case .motion:
            state.config.motion.toggle()
            flipped(item, "motion", config.motion ? "true" : "false")
        case .palette(let palette):
            guard palette != config.palette else { return }
            state.config.palette = palette
            if let entry = discs.first(where: { $0.item == item }) {
                // The ring slides from the old palette to the new one.
                CATransaction.begin()
                CATransaction.setAnimationDuration(calm ? 0 : PanelStyle.controlRingSlide)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
                ring.position = CGPoint(x: entry.layer.frame.midX, y: entry.layer.frame.midY)
                CATransaction.commit()
            }
            paint(animated: true)
            onChange?(config, "palette", "\"\(palette.rawValue)\"")
        case .panel: onAction?(.togglePanel)
        case .quit: onAction?(.quit)
        case .more:
            expanded.toggle()
            build()
            onResize?()
        case .file: onAction?(.openFile)
        case .interval, .rows, .language, .updates: choose(item)
        }
    }

    /// A switch changed: color spreads from the disc's center, or draws back into it.
    private func flipped(_ item: Item, _ key: String, _ value: String) {
        if let entry = discs.first(where: { $0.item == item }), !calm {
            let on = isOn(item)
            let from = entry.fill.presentation()?.value(forKeyPath: "transform.scale") ?? (on ? 0 : 1)
            let spread: CAAnimation
            if on {
                // Turning on overshoots once and settles; turning off does not.
                let spring = CASpringAnimation(keyPath: "transform.scale")
                spring.fromValue = from
                spring.toValue = 1
                spring.stiffness = PanelStyle.controlSpringStiffness
                spring.damping = PanelStyle.controlSpringDamping
                spring.duration = spring.settlingDuration
                spread = spring
            } else {
                let ease = CABasicAnimation(keyPath: "transform.scale")
                ease.fromValue = from
                ease.toValue = 0
                ease.duration = PanelStyle.controlTint
                ease.timingFunction = CAMediaTimingFunction(name: .easeIn)
                spread = ease
            }
            // The fill stays opaque while it shrinks; `paint` clears it after.
            paint(animated: true)
            entry.fill.add(spread, forKey: "spread")
            if !on {
                let hold = CABasicAnimation(keyPath: "opacity")
                hold.fromValue = 1
                hold.toValue = 1
                hold.duration = PanelStyle.controlTint
                entry.fill.add(hold, forKey: "hold")
            }
        } else {
            paint(animated: true)
        }
        onChange?(config, key, value)
    }

    private func choose(_ item: Item) {
        guard let row = rows.first(where: { $0.item == item }) else { return }
        let menu = NSMenu()
        func add(_ title: String, checked: Bool, _ pick: @escaping (inout Config) -> (String, String)) {
            let entry = ChoiceItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
            entry.target = self
            entry.state = checked ? .on : .off
            entry.pick = pick
            menu.addItem(entry)
        }
        switch item {
        case .interval:
            for option in Self.intervals {
                add(Self.seconds(option), checked: option == config.interval) {
                    $0.interval = option
                    return ("interval", Self.trim(option))
                }
            }
        case .rows:
            for option in Self.rowCounts {
                add(String(option), checked: option == config.maxProcesses) {
                    $0.maxProcesses = option
                    return ("maxProcesses", String(option))
                }
            }
        case .language:
            for option in Self.languages {
                add(Self.name(of: option), checked: option == config.language) {
                    $0.language = option
                    return ("language", "\"\(option.rawValue)\"")
                }
            }
        case .updates:
            for option in UpdateMode.allCases {
                add(Self.name(of: option), checked: option == config.updates) {
                    $0.updates = option
                    return ("updates", "\"\(option.rawValue)\"")
                }
            }
            menu.addItem(.separator())
            if !state.updateStatus.isEmpty {
                let status = NSMenuItem(title: state.updateStatus, action: nil, keyEquivalent: "")
                status.isEnabled = false
                menu.addItem(status)
            }
            let action = NSMenuItem(title: state.updateAction, action: #selector(updateNow), keyEquivalent: "")
            action.target = self
            menu.addItem(action)
        default: return
        }
        choosing = true
        menu.popUp(positioning: nil, at: NSPoint(x: row.frame.maxX - PanelStyle.controlPadding - 40, y: row.frame.maxY - 4), in: self)
        choosing = false
    }

    @objc private func picked(_ sender: ChoiceItem) {
        guard let pick = sender.pick else { return }
        let line = pick(&state.config)
        // The labels here are in the old language until rebuilt.
        if line.0 == "language" { Strings.language = config.language }
        build()
        onChange?(config, line.0, line.1)
    }

    @objc private func updateNow() { onAction?(.update) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        build()
    }

    /// The window gives the pixel scale the glyphs and labels are drawn for.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { build() }
    }
}

private final class ChoiceItem: NSMenuItem {
    var pick: ((inout Config) -> (String, String))?
}
