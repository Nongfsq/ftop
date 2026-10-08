import AppKit
import FtopCore

/// The core counts a layout is sized for. Kept apart from the live reading so the
/// layout stays the same while a reading is briefly unavailable.
public struct MachineShape: Equatable, Sendable, Codable {
    public var performance: Int
    public var efficiency: Int

    public init(performance: Int = 8, efficiency: Int = 4) {
        self.performance = performance
        self.efficiency = efficiency
    }

    var kinds: [CoreKind] {
        Array(repeating: .performance, count: performance) + Array(repeating: .efficiency, count: efficiency)
    }
}

/// Slot positions shared by the scene (numbers, hover) and `CoreBarsView` (columns),
/// so a number always sits under its column.
enum CoreBarsGeometry {
    /// Equal-width slots with `gap` between them and `groupGap` extra between the two kinds.
    static func slots(kinds: [CoreKind], width: CGFloat, gap: CGFloat, groupGap: CGFloat) -> [(x: CGFloat, width: CGFloat)] {
        guard !kinds.isEmpty else { return [] }
        let count = CGFloat(kinds.count)
        let split = splitWidth(kinds: kinds, gap: gap, groupGap: groupGap)
        let slot = max(1, (width - gap * (count - 1) - split) / count)
        var x: CGFloat = 0
        var result: [(CGFloat, CGFloat)] = []
        for (index, kind) in kinds.enumerated() {
            if index > 0 {
                x += gap
                if kind != kinds[index - 1] { x += split }
            }
            result.append((x, slot))
            x += slot
        }
        return result
    }

    static func splitWidth(kinds: [CoreKind], gap: CGFloat, groupGap: CGFloat) -> CGFloat {
        Set(kinds).count > 1 ? groupGap + gap : 0
    }

    static func minimumWidth(kinds: [CoreKind], column: CGFloat, gap: CGFloat, groupGap: CGFloat) -> CGFloat {
        let count = CGFloat(kinds.count)
        return count * column + max(0, count - 1) * gap + splitWidth(kinds: kinds, gap: gap, groupGap: groupGap)
    }
}

/// Builds the scene for one layout candidate. Positions come from the widest text each
/// field can show, never from the current reading, so nothing moves as numbers change
/// and a candidate's size depends only on the machine, the settings, and the scale.
@MainActor
public struct SceneBuilder {
    public var snapshot: Snapshot?
    public var machine: MachineShape
    public var modules: [ModuleID]
    public var style: PanelStyle
    /// What the process list is ranked by.
    public var processSort: ProcessSort = .cpu

    public init(snapshot: Snapshot?, machine: MachineShape, modules: [ModuleID] = ModuleID.allCases, style: PanelStyle = PanelStyle()) {
        self.snapshot = snapshot
        self.machine = machine
        self.modules = modules
        self.style = style
    }

    /// `extra` is room beyond the candidate's natural size, in points at scale 1, that
    /// goes to the parts that can grow. It is clamped to `stretchLimit`.
    public func build(_ candidate: LayoutCandidate, extraWidth: Double = 0, extraHeight: Double = 0) -> Scene {
        let limit = Self.stretchLimit(candidate, modules: modules)
        let extra = CGSize(
            width: style.points(min(max(0, extraWidth), limit.width)), height: style.points(min(max(0, extraHeight), limit.height)))
        var scene: Scene
        switch candidate.tier {
        case .micro: scene = micro()
        case .strip: scene = candidate.strip == .vertical ? verticalStrip(extra: extra) : horizontalStrip(rich: candidate.strip == .rich)
        case .corner: scene = corner(extra: extra)
        case .detailed, .full, .compact: scene = columns(candidate, extra: extra)
        }
        // Whole points, so the window that hugs the scene has whole-point edges.
        scene.size = CGSize(width: ceil(scene.size.width), height: ceil(scene.size.height))
        return scene
    }

    public func build(_ choice: LayoutChoice) -> Scene {
        build(choice.candidate, extraWidth: choice.extraWidth, extraHeight: choice.extraHeight)
    }

    /// How much wider and taller than its natural size a candidate may be drawn, at
    /// scale 1. Width goes to the core columns and the name column; height to the core
    /// columns, and only where they have a column's full height to themselves.
    public static func stretchLimit(_ candidate: LayoutCandidate, modules: [ModuleID]) -> Extent {
        switch candidate.tier {
        case .micro: return Extent(width: 0, height: 0)
        case .strip: return Extent(width: 0, height: candidate.strip == .vertical && modules.contains(.cpu) ? 150 : 0)
        case .corner: return Extent(width: 90, height: modules.contains(.cpu) ? 50 : 0)
        case .detailed, .full, .compact:
            let visible = stack(candidate, modules: modules)
            let columns = min(candidate.columns, visible.count)
            if candidate.memoryList, candidate.processCount > 0 { return Extent(width: 70 * Double(min(2, visible.count) + 1), height: 0) }
            if columns <= 1 { return Extent(width: 110, height: visible.contains(.cpu) ? 150 : 0) }
            return Extent(width: 70 * Double(columns), height: 0)
        }
    }

    /// The blocks a column layout stacks, in order. `.gpu` stands for the rows of the added
    /// readings (GPU, power): they follow the last of CPU, memory, and network, and are left
    /// out of the compact layout, which has no labeled rows at all.
    static func stack(_ candidate: LayoutCandidate, modules: [ModuleID]) -> [ModuleID] {
        var blocks = modules.filter { ModuleID.stacked.contains($0) && ($0 != .processes || candidate.processCount > 0) }
        guard candidate.tier != .compact, modules.contains(where: ModuleID.added.contains) else { return blocks }
        let position = blocks.lastIndex { $0 != .processes }.map { $0 + 1 } ?? blocks.count
        blocks.insert(.gpu, at: position)
        return blocks
    }

    // MARK: Pieces

    private enum Anchor { case leading, center, trailing }

    /// What a badge is: a ring whose arc is a share of something, or a plain disc.
    private enum Dial {
        /// `nil` while the reading is unavailable: the ring is drawn empty.
        case ring(Double?, Paint)
        case disc(Paint)
    }

    private func width(_ string: String, _ font: FontSpec) -> CGFloat { Typesetter.width(string, font) }
    private func cap(_ font: FontSpec) -> CGFloat { ceil(Typesetter.metrics(font).capHeight) }

    private func text(_ string: String, _ font: FontSpec, _ paint: Paint, x: CGFloat, baseline: CGFloat, anchor: Anchor = .leading) -> TextItem {
        let measured = width(string, font)
        let left: CGFloat
        switch anchor {
        case .leading: left = x
        case .center: left = x - measured / 2
        case .trailing: left = x - measured
        }
        return TextItem(string: string, x: left, baseline: baseline, width: measured, font: font, paint: paint)
    }

    private var cpu: CPUSample? { snapshot?.cpu.value }
    private var memory: MemorySample? { snapshot?.memory.value }

    /// Live cores when they match the shape the layout was sized for.
    private var cores: [CoreSample] {
        if let cpu, cpu.performance.count == machine.performance, cpu.efficiency.count == machine.efficiency {
            return cpu.performance + cpu.efficiency
        }
        return machine.kinds.enumerated().map { index, kind in
            CoreSample(id: index, kind: kind, number: index + 1, usage: 0, frequencyMHz: .unavailable(cpuReason), maxFrequencyMHz: nil)
        }
    }

    private var cpuReason: String { snapshot?.cpu.reason ?? Strings.noReading }
    private var gpu: GPUSample? { snapshot?.gpu.value }
    private var power: PowerSample? { snapshot?.power.value }
    private var showsGPU: Bool { modules.contains(.gpu) }
    private var showsPower: Bool { modules.contains(.power) }
    private var ane: ANESample? { snapshot?.ane.value }
    private var showsANE: Bool { modules.contains(.ane) }
    private var cpuHover: String { cpu.map { Strings.pick("CPU usage", "处理器总占用") + " \(Format.percent($0.usage))%" } ?? cpuReason }
    private var gpuHover: String { gpu.map { Strings.gpu($0, watts: power?.gpuWatts.value) } ?? snapshot?.gpu.reason ?? Strings.noReading }
    private var powerHover: String { power.map(Strings.power) ?? snapshot?.power.reason ?? Strings.noReading }
    private var aneHover: String { ane.map(Strings.ane) ?? snapshot?.ane.reason ?? Strings.noReading }
    private var temperatureHover: String {
        let temperature = cpu?.temperature
        return temperature?.value.map(Strings.temperature) ?? temperature?.reason ?? cpuReason
    }
    private var totalText: String { memory.map { Format.gigabytesCompact($0.total) } ?? "—" }

    private var memoryHover: String {
        guard let memory else { return snapshot?.memory.reason ?? "" }
        let pressure = memory.pressure.value.map { " · " + Strings.pick("pressure", "压力") + " " + Strings.pressure($0) } ?? ""
        return Strings.pick("Memory used", "内存已用") + " \(Format.gigabytes(memory.used)) / \(Format.gigabytesCompact(memory.total)) GB" + pressure
    }

    private var cpuDial: Dial { .ring(cpu?.usage, .performance) }
    private var gpuDial: Dial { .ring(gpu?.usage, .gpu) }
    /// The memory ring is how much is used; its color is the pressure.
    private var memoryDial: Dial { .ring(memory?.usedFraction, PanelStyle.pressurePaint(memory?.pressure.value)) }

    /// A badge of the one size every badge has, with its top left at `origin`.
    private func badge(_ glyph: Glyph, _ dial: Dial, at origin: CGPoint) -> Scene {
        var scene = Scene()
        let rect = CGRect(x: origin.x, y: origin.y, width: style.badge, height: style.badge)
        switch dial {
        case .ring(let fraction, let paint):
            scene.shapes.append(ShapeItem(rect: rect, paint: paint, kind: .badge(glyph: glyph, tint: paint)))
            if let fraction { scene.arcs.append(ArcItem(rect: rect, fraction: fraction, paint: paint)) }
        case .disc(let paint):
            scene.shapes.append(ShapeItem(rect: rect, paint: paint, kind: .badge(glyph: glyph, tint: paint)))
        }
        return scene
    }

    /// Room for a badge and the widest figure after it.
    private func figureWidth(_ widest: String, unit: String = "", font: FontSpec? = nil) -> CGFloat {
        style.badge + style.badgeGap + width(widest, font ?? style.bodyStrong) + (unit.isEmpty ? 0 : style.points(3) + width(unit, style.caption))
    }

    /// A badge and its figure, centered on the line `middle`, from the left edge `x`.
    /// Room is kept for the widest value, so nothing beside it moves as the number changes.
    private func figure(
        _ glyph: Glyph, _ dial: Dial, _ value: String, unit: String = "", font: FontSpec? = nil, hover: String, x: CGFloat, middle: CGFloat
    ) -> Scene {
        let font = font ?? style.bodyStrong
        let baseline = middle + cap(font) / 2
        var scene = badge(glyph, dial, at: CGPoint(x: x, y: middle - style.badge / 2))
        let number = text(value, font, .ink, x: x + style.badge + style.badgeGap, baseline: baseline)
        scene.texts.append(number)
        var area = CGRect(x: x, y: middle - style.badge / 2, width: style.badge, height: style.badge).union(number.frame)
        if !unit.isEmpty {
            let mark = text(unit, style.caption, .secondary, x: number.x + number.width + style.points(3), baseline: baseline)
            scene.texts.append(mark)
            area = area.union(mark.frame)
        }
        scene.hovers.append(HoverRegion(rect: area, text: hover))
        return scene
    }

    /// Whose the temperature is. Some chips report sensors on the processor's own
    /// clusters; others only sensors across the whole chip, which the GPU shares.
    private var temperatureIsProcessors: Bool { cpu?.temperature.value?.source == .cpuCluster }

    /// The badge is the processor's color when the reading is the processor's, and plain when it is the whole chip's.
    private func temperatureFigure(x: CGFloat, middle: CGFloat, font: FontSpec? = nil) -> Scene {
        let value = cpu?.temperature.value.map { Format.degrees($0.celsius) } ?? "—"
        let paint: Paint = temperatureIsProcessors ? .performance : .secondary
        return figure(.temperature, .disc(paint), value, font: font, hover: temperatureHover, x: x, middle: middle)
    }

    /// Where the temperature goes in the title row.
    private enum TemperaturePlace {
        /// Right after the processor's figure: it is the processor's.
        case beside
        /// On the row's last column.
        case last
        /// Not in the title row: it is in the machine's pair below.
        case below
    }

    /// The whole chip's temperature belongs with the whole machine's watts where that pair is shown.
    private func temperaturePlace(pairs: Bool) -> TemperaturePlace {
        if temperatureIsProcessors { return .beside }
        return pairs && showsPower ? .below : .last
    }

    private func cpuFigure(x: CGFloat, middle: CGFloat) -> Scene {
        figure(.cpu, cpuDial, (cpu.map { Format.percent($0.usage) } ?? "—") + "%", hover: cpuHover, x: x, middle: middle)
    }

    private func gpuFigure(x: CGFloat, middle: CGFloat) -> Scene {
        let value = gpu.map { "\(Format.percent($0.usage))%" } ?? "—"
        return figure(.gpu, gpuDial, value, hover: gpuHover, x: x, middle: middle)
    }

    /// Memory as "21.5 / 36G" or "60%".
    private func memoryFigure(full: Bool, x: CGFloat, middle: CGFloat) -> (scene: Scene, width: CGFloat) {
        let value: String
        let widest: String
        if full {
            value = memory.map { "\(Format.gigabytes($0.used)) / \(Format.gigabytesCompact($0.total))G" } ?? "—"
            widest = "88.8 / 888G"
        } else {
            value = memory.map { "\(Format.percent($0.usedFraction))%" } ?? "—"
            widest = "100%"
        }
        return (figure(.memory, memoryDial, value, hover: memoryHover, x: x, middle: middle), figureWidth(widest))
    }

    private var shortRateWidth: CGFloat { figureWidth("888.8M") }

    private func shortRate(_ glyph: Glyph, _ keyPath: KeyPath<NetworkSample, Double>, x: CGFloat, middle: CGFloat) -> Scene {
        let network = snapshot?.network.value
        let value = network.map { Format.rate($0[keyPath: keyPath]).shortText } ?? "—"
        // An arrow and a rate say everything; a chip would only repeat them. It speaks only when there is no reading.
        let hover = network == nil ? snapshot?.network.reason ?? "" : ""
        return figure(glyph, .disc(.secondary), value, hover: hover, x: x, middle: middle)
    }

    /// Right-hand column shared by memory, network, the added rows, and processes; wide enough for each.
    private var side: CGFloat {
        let added = max(showsGPU ? figureWidth("88.8", unit: "GB") : 0, showsPower ? figureWidth("888.8", unit: "W") : 0)
        return max(
            style.sideColumn, labeledWidth(Strings.swap), figureWidth("888.8", unit: "MB/s"), added,
            style.processCPUWidth + style.innerGap + style.processMemoryWidth)
    }

    private func labeledWidth(_ label: String, number: String = "88.8", unit: String = "GB") -> CGFloat {
        width(label, style.caption) + style.points(4) + width(number, style.captionStrong) + style.points(4) + width(unit, style.caption)
    }

    private func bars(in rect: CGRect, mini: Bool, hoverHeight: CGFloat? = nil) -> Scene {
        var scene = Scene()
        let gap = mini ? style.miniCoreGap : style.coreGap
        let groupGap = mini ? style.miniCoreGroupGap : style.coreGroupGap
        let list = cores
        scene.bars = BarsItem(rect: rect, cores: list, showsFrequency: !mini, gap: gap, groupGap: groupGap)
        let slots = CoreBarsGeometry.slots(kinds: list.map(\.kind), width: rect.width, gap: gap, groupGap: groupGap)
        for (index, slot) in slots.enumerated() {
            let region = CGRect(x: rect.minX + slot.x - gap / 2, y: rect.minY, width: slot.width + gap, height: hoverHeight ?? rect.height)
            // The canvas writes a core's detail line when the pointer is on it; no need to compose all of them every sample.
            scene.hovers.append(HoverRegion(rect: region, text: cpu == nil ? cpuReason : "", coreIndex: index))
        }
        return scene
    }

    private var miniBarsWidth: CGFloat {
        CoreBarsGeometry.minimumWidth(kinds: machine.kinds, column: style.miniCoreWidth, gap: style.miniCoreGap, groupGap: style.miniCoreGroupGap)
    }

    private func unavailable(_ reason: String, width: CGFloat, height: CGFloat) -> Scene {
        var scene = Scene()
        scene.size = CGSize(width: width, height: height)
        scene.texts.append(text("—", style.body, .secondary, x: 0, baseline: cap(style.body)))
        scene.hovers.append(HoverRegion(rect: CGRect(x: 0, y: 0, width: width, height: max(height, cap(style.body))), text: reason))
        return scene
    }

    // MARK: Modules

    /// The title row, in one type size: the processor, the temperature where `place`
    /// puts it, and the GPU where it has no row of its own. `tail` is the width of the
    /// row's last column, which in a column layout is the side column the pairs below it
    /// use; `columns` fixes each figure to a column instead. Returns the row's height.
    private func cpuHeader(
        _ scene: inout Scene, origin: CGPoint, width total: CGFloat, tail: CGFloat, gpu: Bool, ane: Bool = false, place: TemperaturePlace, columns: Bool = false
    ) -> CGFloat {
        let font = style.emphasis
        let middle = origin.y + style.badge / 2
        let room = figureWidth("100", unit: "%", font: font)
        let last = total - tail
        let usage = cpu.map { Format.percent($0.usage) } ?? "—"
        scene.append(figure(.cpu, cpuDial, usage, unit: "%", font: font, hover: cpuHover, x: origin.x, middle: middle), at: .zero)
        let beside = place == .beside && !columns
        if place != .below {
            let x = beside ? room + style.points(12) : last
            scene.append(temperatureFigure(x: origin.x + x, middle: middle, font: font), at: .zero)
        }
        // Added readings with no row of their own in this tier share the title row.
        // They pack left to right (or onto the grid in a column layout), each taking
        // the width cpuHeaderWidth reserved for it, so neighbours never overlap.
        var extras: [(glyph: Glyph, dial: Dial, value: String, unit: String, width: CGFloat, hover: String)] = []
        if gpu { extras.append((.gpu, gpuDial, self.gpu.map { Format.percent($0.usage) } ?? "—", "%", room, gpuHover)) }
        if ane { extras.append((.ane, .disc(.gpu), self.ane.map { Format.watts($0.watts) } ?? "—", "W", figureWidth("88.8", unit: "W", font: font), aneHover)) }
        var next = beside || place == .below ? last - CGFloat(max(0, extras.count - 1)) * (room + style.points(12)) : room + style.points(12)
        for (index, extra) in extras.enumerated() {
            let x = columns ? last * CGFloat(index + 1) / CGFloat(extras.count + 1) : next
            next += extra.width + style.points(12)
            scene.append(figure(extra.glyph, extra.dial, extra.value, unit: extra.unit, font: font, hover: extra.hover, x: origin.x + x, middle: middle), at: .zero)
        }
        return style.badge
    }

    private func cpuHeaderWidth(tail: CGFloat, gpu: Bool, ane: Bool = false) -> CGFloat {
        let room = figureWidth("100", unit: "%", font: style.emphasis) + style.points(12)
        let watts = figureWidth("88.8", unit: "W", font: style.emphasis) + style.points(12)
        return room * (gpu ? 2 : 1) + (ane ? watts : 0) + tail
    }

    private var temperatureRoom: CGFloat { figureWidth("100°", font: style.emphasis) }

    private func cpuModule(width fixedWidth: CGFloat?, height fixedHeight: CGFloat?, numbers: Bool, minimumBars: CGFloat, compact: Bool) -> Scene {
        var scene = Scene()
        let kinds = machine.kinds
        let column = numbers ? style.coreNumberedWidth : style.coreSlimWidth
        let barsMinimum = CoreBarsGeometry.minimumWidth(kinds: kinds, column: column, gap: style.coreGap, groupGap: style.coreGroupGap)
        // The compact layout has no pairs, so the GPU and the ANE join the title row.
        let gpuInHeader = showsGPU && compact
        let aneInHeader = showsANE && compact
        let tail = max(side, temperatureRoom)
        let total = fixedWidth ?? max(barsMinimum, cpuHeaderWidth(tail: tail, gpu: gpuInHeader, ane: aneInHeader))
        let header = cpuHeader(&scene, origin: .zero, width: total, tail: tail, gpu: gpuInHeader, ane: aneInHeader, place: temperaturePlace(pairs: !compact))

        let barsTop = header + style.innerGap
        let usageBaseline = style.points(5) + cap(style.coreNumber)
        let frequencyBaseline = usageBaseline + style.points(4) + cap(style.tiny)
        let numbersHeight = numbers ? frequencyBaseline : 0
        let barsHeight = max(minimumBars, (fixedHeight ?? 0) - barsTop - numbersHeight)
        let rect = CGRect(x: 0, y: barsTop, width: total, height: barsHeight)
        scene.append(bars(in: rect, mini: false, hoverHeight: barsHeight + numbersHeight), at: .zero)

        if numbers {
            let list = cores
            let slots = CoreBarsGeometry.slots(kinds: kinds, width: total, gap: style.coreGap, groupGap: style.coreGroupGap)
            for (index, slot) in slots.enumerated() {
                let middle = slot.x + slot.width / 2
                let usage = cpu == nil ? "—" : Format.percent(list[index].usage)
                scene.texts.append(text(usage, style.coreNumber, .ink, x: middle, baseline: rect.maxY + usageBaseline, anchor: .center))
                let frequency = list[index].frequencyMHz.value.map(Format.gigahertz) ?? "—"
                scene.texts.append(text(frequency, style.tiny, .secondary, x: middle, baseline: rect.maxY + frequencyBaseline, anchor: .center))
            }
        }
        scene.size = CGSize(width: total, height: rect.maxY + numbersHeight)
        return scene
    }

    private func memoryModule(width fixed: CGFloat?, detail: Bool) -> Scene {
        var scene = Scene()
        let pressureWidth = detail ? (Strings.pressureWords.map { width($0, style.caption) }.max() ?? 0) + style.points(8) : 0
        let totalLabel = "/ \(totalText) GB"
        let headerMinimum =
            style.badge + style.badgeLeadGap + width("88.8", style.emphasis) + style.points(5) + width("/ 888 GB", style.caption) + pressureWidth
        let barMinimum = style.points(56) + style.rowGap + side
        let detailMinimum = detail ? labeledWidth(Strings.compressed) + style.rowGap + side : 0
        let total = fixed ?? max(headerMinimum, barMinimum, detailMinimum)
        let header = style.badge
        let middle = header / 2
        let baseline = middle + cap(style.emphasis) / 2
        let barTop = header + style.innerGap
        let barHeight = style.points(6)
        let detailBaseline = barTop + barHeight + style.points(9) + cap(style.caption)
        scene.size = CGSize(width: total, height: detail ? detailBaseline : barTop + barHeight)

        scene.append(badge(.memory, memoryDial, at: .zero), at: .zero)
        guard let memory else {
            let reason = snapshot?.memory.reason ?? Strings.noReading
            scene.texts.append(text("—", style.emphasis, .secondary, x: style.badge + style.badgeLeadGap, baseline: baseline))
            scene.hovers.append(HoverRegion(rect: CGRect(x: 0, y: 0, width: total, height: scene.size.height), text: reason))
            return scene
        }
        let used = text(Format.gigabytes(memory.used), style.emphasis, .ink, x: style.badge + style.badgeLeadGap, baseline: baseline)
        scene.texts.append(used)
        scene.texts.append(text(totalLabel, style.caption, .secondary, x: used.x + used.width + style.points(5), baseline: baseline))
        scene.hovers.append(HoverRegion(rect: CGRect(x: 0, y: 0, width: total, height: header), text: memoryHover))
        if detail, let level = memory.pressure.value {
            // The ring carries the pressure as its color; the word says it once more where there is room.
            scene.texts.append(text(Strings.pressure(level), style.caption, .secondary, x: total, baseline: baseline, anchor: .trailing))
        }

        let sideLeft = total - side
        let barRect = CGRect(x: 0, y: barTop, width: sideLeft - style.rowGap, height: barHeight)
        let paint = PanelStyle.pressurePaint(memory.pressure.value ?? .normal)
        scene.shapes.append(
            ShapeItem(
                rect: barRect, paint: .track,
                kind: .meter(
                    track: .track,
                    segments: [.init(fraction: memory.appFraction, paint: paint), .init(fraction: memory.compressedFraction, paint: .faded(paint))],
                    outline: nil)))
        scene.hovers.append(HoverRegion(rect: barRect.insetBy(dx: 0, dy: -style.points(4)), text: memoryHover))
        let swapRect = CGRect(x: sideLeft, y: barTop, width: side, height: barHeight)
        scene.shapes.append(
            ShapeItem(
                rect: swapRect, paint: .secondary,
                kind: .meter(track: nil, segments: [.init(fraction: memory.swapFraction, paint: .secondary)], outline: .faded(.secondary))))
        let swapHover = Strings.swap + " \(Format.gigabytes(memory.swapUsed)) GB"
        scene.hovers.append(HoverRegion(rect: swapRect.insetBy(dx: 0, dy: -style.points(4)), text: swapHover))

        if detail {
            let compressed = labeled(Strings.compressed, Format.gigabytes(memory.compressed), x: 0, baseline: detailBaseline)
            scene.append(compressed, at: .zero)
            scene.append(labeled(Strings.swap, Format.gigabytes(memory.swapUsed), x: sideLeft, baseline: detailBaseline), at: .zero)
        }
        return scene
    }

    /// "label 8.0 GB" with the number stronger than its label and unit.
    private func labeled(_ label: String, _ value: String, unit unitText: String = "GB", x: CGFloat, baseline: CGFloat) -> Scene {
        var scene = Scene()
        let name = text(label, style.caption, .secondary, x: x, baseline: baseline)
        let number = text(value, style.captionStrong, .ink, x: name.x + name.width + style.points(4), baseline: baseline)
        let unit = text(unitText, style.caption, .secondary, x: number.x + number.width + style.points(4), baseline: baseline)
        scene.texts += [name, number, unit]
        scene.hovers.append(HoverRegion(rect: name.frame.union(unit.frame), text: "\(label) \(value) \(unitText)"))
        return scene
    }

    /// The rows of the added readings. Every row is a pair: one figure on the left edge and
    /// one on the side column, each behind its badge. The GPU's pair is in the GPU's color;
    /// the whole machine's is plain.
    private func detailRows(width fixed: CGFloat?) -> Scene? {
        typealias Cell = (glyph: Glyph, dial: Dial, value: String, unit: String, widest: String, hover: String)
        var rows: [(left: Cell, right: Cell?)] = []
        if showsGPU {
            let usage: Cell = (.gpu, gpuDial, gpu.map { Format.percent($0.usage) } ?? "—", "%", "100", gpuHover)
            let memory: Cell = (.memory, .disc(.gpu), gpu?.memoryBytes.value.map(Format.gigabytes) ?? "—", "GB", "88.8", gpuHover)
            // One pair for the GPU. Its watts and its own temperature are in the hover: on the
            // panel a second temperature a few degrees from the chip's only raised the question of which was which.
            rows.append((usage, memory))
        }
        if showsANE {
            // Watts are all the Neural Engine reports; it rows alone, beside the GPU's pair.
            let neural: Cell = (.ane, .disc(.gpu), ane.map { Format.watts($0.watts) } ?? "—", "W", "88.8", aneHover)
            rows.append((neural, nil))
        }
        if showsPower {
            let system: Cell = (.machine, .disc(.secondary), power.map { Format.watts($0.systemWatts) } ?? "—", "W", "888.8", powerHover)
            if temperaturePlace(pairs: true) == .below {
                // The machine's pair: what it draws and how hot the chip is. What the adapter delivers is in the hover.
                let heat: Cell = (.temperature, .disc(.secondary), cpu?.temperature.value.map { Format.degrees($0.celsius) } ?? "—", "", "100°", temperatureHover)
                rows.append((system, heat))
            } else {
                let adapter: Cell = (.adapter, .disc(.secondary), power?.inputWatts.value.map(Format.watts) ?? "—", "W", "888.8", powerHover)
                rows.append((system, adapter))
            }
        }
        guard !rows.isEmpty else { return nil }
        let total = fixed ?? figureWidth("888.8", unit: "W") + style.rowGap + side
        let pitch = style.badge + style.innerGap
        var scene = Scene()
        var middle = style.badge / 2
        for row in rows {
            for (cell, x) in [(row.left, CGFloat(0)), (row.right, total - side)] {
                guard let cell else { continue }
                scene.append(
                    figure(cell.glyph, cell.dial, cell.value, unit: cell.unit, hover: cell.hover, x: x, middle: middle), at: .zero)
            }
            middle += pitch
        }
        scene.size = CGSize(width: total, height: CGFloat(rows.count) * pitch - style.innerGap)
        return scene
    }

    private func networkModule(width fixed: CGFloat?, longUnits: Bool) -> Scene {
        let total = fixed ?? figureWidth("888.8", unit: longUnits ? "MB/s" : "M") + style.rowGap + side
        var scene = Scene()
        scene.size = CGSize(width: total, height: style.badge)
        let middle = style.badge / 2
        let network = snapshot?.network.value
        for (glyph, keyPath, x) in [
            (Glyph.download, \NetworkSample.downBytesPerSecond, CGFloat(0)), (Glyph.upload, \NetworkSample.upBytesPerSecond, total - side),
        ] {
            let quantity = network.map { Format.rate($0[keyPath: keyPath]) }
            let unit = quantity.map { longUnits ? $0.unit : $0.shortUnit } ?? ""
            // No chip over a rate: it would repeat what the arrow and the number already say.
            let hover = quantity == nil ? snapshot?.network.reason ?? Strings.noReading : ""
            scene.append(
                figure(glyph, .disc(.secondary), quantity?.number ?? "—", unit: unit, hover: hover, x: x, middle: middle), at: .zero)
        }
        return scene
    }

    /// The process list: one entry a row, behind the app's icon in a badge whose arc is
    /// the entry's share of what is in use, with the one figure the list is ranked by.
    /// `wide` is the large window's form: two badges above the list switch what it is
    /// ranked by, and the ranking continues in a second column.
    private func processModule(width fixed: CGFloat?, count: Int, roomy: Bool, wide: Bool) -> Scene {
        let nameWidth = roomy ? style.processNameWideWidth : style.processNameWidth
        let valueRoom = width("888.8", style.bodyStrong) + style.points(3) + width("%", style.caption)
        let single = style.badge + style.badgeLeadGap + nameWidth + style.rowGap + valueRoom
        let total = fixed ?? (wide ? single * 2 + style.columnGap : single)
        let columnWidth = wide ? (total - style.columnGap) / 2 : total
        let pitch = style.badge + style.processRowGap
        let header = wide ? style.badge + style.innerGap : 0
        let rowsHeight = style.badge + CGFloat(max(0, count - 1)) * pitch
        var scene = Scene()
        scene.size = CGSize(width: total, height: header + rowsHeight)

        // The memory ranking needs a helper that provides it; without one the list stays by processor.
        let list = snapshot?.processes.value
        let sort: ProcessSort = processSort == .memory && list?.byMemory.isEmpty == false ? .memory : .cpu
        if wide {
            for (index, option) in ProcessSort.allCases.enumerated() {
                let rect = CGRect(x: CGFloat(index) * (style.badge + style.badgeGap), y: 0, width: style.badge, height: style.badge)
                let paint: Paint = option == .cpu ? .performance : PanelStyle.pressurePaint(.normal)
                scene.shapes.append(ShapeItem(rect: rect, paint: paint, kind: .toggle(glyph: option == .cpu ? .cpu : .memory, on: option == sort, paint: paint)))
                let hover =
                    option == .cpu
                    ? Strings.pick("Rank processes by processor", "按处理器占用排列进程") : Strings.pick("Rank processes by memory", "按内存占用排列进程")
                scene.hovers.append(HoverRegion(rect: rect.insetBy(dx: -style.badgeGap / 2, dy: 0), text: hover))
                scene.clicks.append(ClickRegion(rect: rect.insetBy(dx: -style.badgeGap / 2, dy: -style.points(3)), action: .sort(option)))
            }
        }
        guard let list else {
            scene.texts.append(text("—", style.body, .secondary, x: 0, baseline: header + style.badge / 2 + cap(style.body) / 2))
            scene.hovers.append(
                HoverRegion(rect: CGRect(x: 0, y: header, width: total, height: rowsHeight), text: snapshot?.processes.reason ?? Strings.noReading))
            return scene
        }

        // Shares are of what is in use right now, so the arcs of a busy list add up to about a full turn.
        let cpuInUse = max(cpu.map { $0.usage * Double(machine.kinds.count) * 100 } ?? 0, list.top.reduce(0) { $0 + $1.cpuPercent }, 1)
        let memoryInUse = Double(max(memory?.used ?? 0, list.byMemory.reduce(0) { $0 + $1.memoryBytes }, 1))
        func memoryParts(_ bytes: UInt64) -> (number: String, unit: String) {
            let text = Format.processMemory(bytes)
            return (String(text.dropLast()), String(text.suffix(1)))
        }
        let other = Dictionary((sort == .cpu ? list.byMemory : list.top).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = (sort == .cpu ? list.top : list.byMemory).prefix(count * (wide ? 2 : 1))
        var rows: [ProcessRow] = []
        for entry in entries {
            // The other figure comes from the other ranking when the entry is in it: that list sums the app's processes for that measure.
            let cpuPercent = sort == .cpu ? entry.cpuPercent : (other[entry.id]?.cpuPercent ?? entry.cpuPercent)
            let bytes = sort == .memory ? entry.memoryBytes : (other[entry.id]?.memoryBytes ?? entry.memoryBytes)
            let percent = String(Int(cpuPercent.rounded()))
            let held = memoryParts(bytes)
            let members = entry.members.prefix(4).map { member -> ProcessCard.Member in
                if sort == .cpu { return .init(name: member.name, value: String(Int(member.cpuPercent.rounded())), unit: "%") }
                let parts = memoryParts(member.memoryBytes)
                return .init(name: member.name, value: parts.number, unit: parts.unit)
            }
            let card = ProcessCard(
                name: entry.name, appPath: entry.appPath, cpu: percent, cpuShare: cpuPercent / cpuInUse, memory: held.number, memoryUnit: held.unit,
                memoryShare: Double(bytes) / memoryInUse, members: Array(members))
            rows.append(
                ProcessRow(
                    key: entry.id, name: entry.name, appPath: entry.appPath, value: sort == .cpu ? percent : held.number,
                    unit: sort == .cpu ? "%" : held.unit, share: sort == .cpu ? card.cpuShare : card.memoryShare, card: card))
        }
        // A list too short to fill both columns is split evenly between them, not left as one full column and a stub.
        let perColumn = wide ? max(1, min(count, (rows.count + 1) / 2)) : count
        let item = ProcessRowsItem(
            rect: CGRect(x: 0, y: header, width: total, height: rowsHeight), rows: rows, perColumn: perColumn, rowHeight: style.badge,
            columnWidth: columnWidth,
            columnGap: style.columnGap, pitch: pitch, paint: sort == .cpu ? .performance : PanelStyle.pressurePaint(.normal))
        scene.processes = item
        for (index, row) in rows.enumerated() {
            let frame = item.frame(at: index).offsetBy(dx: 0, dy: header)
            let region = frame.insetBy(dx: 0, dy: -style.processRowGap / 2)
            // The pointer lights the row; the detail is in the card a click brings up, so no chip here.
            scene.hovers.append(HoverRegion(rect: region, text: "", processKey: row.key))
            scene.clicks.append(ClickRegion(rect: region, action: .process(row.key)))
        }
        return scene
    }

    // MARK: Column layouts

    private func module(_ id: ModuleID, candidate: LayoutCandidate, width: CGFloat?, height: CGFloat? = nil, roomy: Bool) -> Scene {
        switch id {
        case .cpu:
            let numbers = candidate.tier == .detailed
            let minimum = style.points(numbers || candidate.processCount > 3 ? 84 : 44)
            return cpuModule(width: width, height: height, numbers: numbers, minimumBars: minimum, compact: candidate.tier == .compact)
        case .memory: return memoryModule(width: width, detail: candidate.tier != .compact)
        case .network: return networkModule(width: width, longUnits: candidate.tier != .compact)
        case .processes: return processModule(width: width, count: candidate.processCount, roomy: roomy, wide: candidate.memoryList)
        // `.gpu` stands for the rows of every added reading; see `stack`.
        case .gpu: return detailRows(width: width) ?? Scene()
        case .power, .ane: return Scene()
        }
    }

    /// First module alone on the left, last alone on the right when there are three columns.
    private func split(_ list: [ModuleID], into count: Int) -> [[ModuleID]] {
        guard count >= 2, list.count >= count else { return [list] }
        if count == 2 { return [[list[0]], Array(list.dropFirst())] }
        return [[list[0]], Array(list.dropFirst().dropLast()), [list[list.count - 1]]]
    }

    private func columns(_ candidate: LayoutCandidate, extra: CGSize) -> Scene {
        let visible = Self.stack(candidate, modules: modules)
        let memoryList = candidate.memoryList && candidate.processCount > 0 && modules.contains(.processes)
        // The wide process list is a column group of its own, twice a list's width,
        // and everything else stacks in the first column.
        let groups: [[ModuleID]]
        if memoryList, visible.count > 1 {
            groups = [visible.filter { $0 != .processes }, [.processes]]
        } else {
            groups = split(visible, into: min(candidate.columns, visible.count))
        }
        let roomy = groups.count > 1 || memoryList

        // The network pair and the pairs of the added readings are one grid of badges:
        // the same distance between all of its rows.
        func gap(after position: Int, in group: [ModuleID]) -> CGFloat {
            group[position] == .network && group.indices.contains(position + 1) && group[position + 1] == .gpu ? style.innerGap : style.moduleGap
        }

        let share = extra.width / CGFloat(groups.count + (memoryList ? 1 : 0))
        let widths = groups.map { group in
            // The wide list holds two columns, so it takes two shares.
            (group.map { module($0, candidate: candidate, width: nil, roomy: roomy).size.width }.max() ?? 0)
                + share * (memoryList && group == [.processes] ? 2 : 1)
        }
        var natural: [[Scene]] = []
        var heights: [CGFloat] = []
        for (index, group) in groups.enumerated() {
            var built = group.map { module($0, candidate: candidate, width: widths[index], roomy: roomy) }
            // In a single column the core columns take the extra height.
            if !roomy, extra.height > 0, let position = group.firstIndex(of: .cpu) {
                let taller = built[position].size.height + extra.height
                built[position] = module(.cpu, candidate: candidate, width: widths[index], height: taller, roomy: roomy)
            }
            natural.append(built)
            heights.append(built.reduce(0) { $0 + $1.size.height } + group.indices.dropLast().reduce(0) { $0 + gap(after: $1, in: group) })
        }
        let tallest = heights.max() ?? 0

        var scene = Scene()
        var x = style.paddingX
        for (index, group) in groups.enumerated() {
            var blocks = natural[index]
            // The core columns take whatever height their column has left, so every column ends level.
            if roomy, let position = group.firstIndex(of: .cpu), heights[index] < tallest || group.count == 1 {
                let taller = blocks[position].size.height + tallest - heights[index]
                blocks[position] = module(.cpu, candidate: candidate, width: widths[index], height: taller, roomy: roomy)
            }
            var y = style.paddingY
            for (position, block) in blocks.enumerated() {
                // A shorter middle column ends level with its neighbors: its last module sits at the bottom.
                if groups.count == 3, index == 1, blocks.count > 1, position == blocks.count - 1 {
                    y = max(y, style.paddingY + tallest - block.size.height)
                }
                scene.append(block, at: CGPoint(x: x, y: y))
                y += block.size.height + gap(after: position, in: group)
            }
            x += widths[index] + style.columnGap
        }
        scene.size = CGSize(width: x - style.columnGap + style.paddingX, height: tallest + style.paddingY * 2)
        return scene
    }

    // MARK: Corner

    private func corner(extra: CGSize) -> Scene {
        var scene = Scene()
        let padX = style.points(13)
        let padY = style.points(11)
        let gap = style.innerGap
        let barsMinimum = CoreBarsGeometry.minimumWidth(
            kinds: machine.kinds, column: style.coreSlimWidth, gap: style.coreGap, groupGap: style.coreGroupGap)
        // The title row and the row under the memory bar share their columns, so the
        // figures line up: processor, GPU, ANE, temperature over download, upload, watts.
        let top = modules.contains(.cpu) ? 2 + (showsGPU ? 1 : 0) + (showsANE ? 1 : 0) : 0
        let bottom = (modules.contains(.network) ? 2 : 0) + (showsPower ? 1 : 0)
        let count = max(top, bottom, 2)
        let cell = max(figureWidth("100", unit: "%", font: style.emphasis), temperatureRoom, shortRateWidth, figureWidth("888.8W"))
        let total = max(barsMinimum, cell * CGFloat(count) + style.points(10) * CGFloat(count - 1)) + extra.width
        func column(_ index: Int) -> CGFloat { CGFloat(index) * (total - cell) / CGFloat(count - 1) }
        var y = padY

        if modules.contains(.cpu) {
            let header = cpuHeader(&scene, origin: CGPoint(x: padX, y: y), width: total, tail: cell, gpu: showsGPU, ane: showsANE, place: .last, columns: true)
            y += header + gap
            let rect = CGRect(x: padX, y: y, width: total, height: style.points(34) + extra.height)
            scene.append(bars(in: rect, mini: false), at: .zero)
            y = rect.maxY + gap
        }
        if modules.contains(.memory) {
            let rect = CGRect(x: padX, y: y, width: total, height: style.points(5))
            if let memory {
                let paint = PanelStyle.pressurePaint(memory.pressure.value ?? .normal)
                scene.shapes.append(
                    ShapeItem(
                        rect: rect, paint: .track,
                        kind: .meter(
                            track: .track,
                            segments: [.init(fraction: memory.appFraction, paint: paint), .init(fraction: memory.compressedFraction, paint: .faded(paint))],
                            outline: nil)))
            }
            scene.hovers.append(HoverRegion(rect: rect.insetBy(dx: 0, dy: -style.points(4)), text: memoryHover))
            y = rect.maxY + gap
        }
        if bottom > 0 {
            let middle = y + style.badge / 2
            var lower: [Scene] = []
            if modules.contains(.network) {
                lower.append(shortRate(.download, \.downBytesPerSecond, x: 0, middle: middle))
                lower.append(shortRate(.upload, \.upBytesPerSecond, x: 0, middle: middle))
            }
            if showsPower {
                // The whole machine's watts: the only power figure a layout this small has room for.
                let watts = power.map { Format.watts($0.systemWatts) + "W" } ?? "—"
                lower.append(figure(.machine, .disc(.secondary), watts, hover: powerHover, x: 0, middle: middle))
            }
            for (index, block) in lower.enumerated() { scene.append(block, at: CGPoint(x: padX + column(index), y: 0)) }
            y += style.badge + gap
        }
        scene.size = CGSize(width: total + padX * 2, height: y - gap + padY)
        return scene
    }

    // MARK: Strips

    private func horizontalStrip(rich: Bool) -> Scene {
        var scene = Scene()
        let padX = style.points(10)
        let padY = style.points(5)
        let gap = style.points(12)
        let middle = padY + style.badge / 2
        let barsHeight = style.points(14)
        var x = padX

        if modules.contains(.cpu) {
            let rect = CGRect(x: x, y: middle - barsHeight / 2, width: miniBarsWidth, height: barsHeight)
            scene.append(bars(in: rect, mini: true), at: .zero)
            x = rect.maxX + gap
            scene.append(cpuFigure(x: x, middle: middle), at: .zero)
            x += figureWidth("100%") + gap
            if rich {
                scene.append(temperatureFigure(x: x, middle: middle), at: .zero)
                x += figureWidth("100°") + gap
            }
        }
        // The plain strip has no room for the GPU; it is the first figure to go.
        if rich, showsGPU {
            scene.append(gpuFigure(x: x, middle: middle), at: .zero)
            x += figureWidth("100%") + gap
        }
        if modules.contains(.memory) {
            let block = memoryFigure(full: rich, x: x, middle: middle)
            scene.append(block.scene, at: .zero)
            x += block.width + gap
        }
        if modules.contains(.network) {
            scene.append(shortRate(.download, \.downBytesPerSecond, x: x, middle: middle), at: .zero)
            x += shortRateWidth + style.points(8)
            scene.append(shortRate(.upload, \.upBytesPerSecond, x: x, middle: middle), at: .zero)
            x += shortRateWidth + gap
        }
        if rich, modules.contains(.processes) {
            let nameRoom = style.points(104)
            let percentWidth = width("888%", style.body)
            let baseline = middle + cap(style.body) / 2
            if let top = snapshot?.processes.value?.top.first {
                let name = text(Typesetter.truncated(top.name, style.body, to: nameRoom), style.body, .ink, x: x, baseline: baseline)
                let percent = "\(Int(top.cpuPercent.rounded()))%"
                let number = text(percent, style.body, .secondary, x: name.x + name.width + style.points(4), baseline: baseline)
                scene.texts += [name, number]
                scene.hovers.append(
                    HoverRegion(
                        rect: name.frame.union(number.frame),
                        text: "\(top.name) · CPU \(percent) · " + Strings.pick("memory", "内存") + " \(Format.processMemory(top.memoryBytes))"))
            }
            x += nameRoom + style.points(4) + percentWidth + gap
        }
        scene.size = CGSize(width: x - gap + padX, height: style.badge + padY * 2)
        return scene
    }

    /// One figure a row, badges in one column and numbers in the next.
    private func verticalStrip(extra: CGSize) -> Scene {
        var scene = Scene()
        let padX = style.points(8)
        let padY = style.points(10)
        let gap = style.points(8)
        let total = max(miniBarsWidth, shortRateWidth)
        var y = padY
        func row(_ block: Scene) {
            scene.append(block, at: .zero)
            y += style.badge + gap
        }

        if modules.contains(.cpu) {
            // The columns come first, so the figures under them are one list with one rhythm.
            let rect = CGRect(x: padX, y: y, width: total, height: style.points(48) + extra.height)
            scene.append(bars(in: rect, mini: true), at: .zero)
            y = rect.maxY + gap
            row(cpuFigure(x: padX, middle: y + style.badge / 2))
            row(temperatureFigure(x: padX, middle: y + style.badge / 2))
        }
        if showsGPU { row(gpuFigure(x: padX, middle: y + style.badge / 2)) }
        if modules.contains(.memory) { row(memoryFigure(full: false, x: padX, middle: y + style.badge / 2).scene) }
        if modules.contains(.network) {
            row(shortRate(.download, \.downBytesPerSecond, x: padX, middle: y + style.badge / 2))
            row(shortRate(.upload, \.upBytesPerSecond, x: padX, middle: y + style.badge / 2))
        }
        scene.size = CGSize(width: total + padX * 2, height: y - gap + padY)
        return scene
    }

    /// Rings alone: how busy the processor, the GPU, and memory are, with no numbers.
    private func micro() -> Scene {
        var scene = Scene()
        let padX = style.points(7)
        let padY = style.points(5)
        let gap = style.points(6)
        var x = padX
        var rings: [(Glyph, Dial, String)] = [(.cpu, cpuDial, cpuHover)]
        if showsGPU { rings.append((.gpu, gpuDial, gpuHover)) }
        rings.append((.memory, memoryDial, memoryHover))
        for (glyph, dial, hover) in rings {
            scene.append(badge(glyph, dial, at: CGPoint(x: x, y: padY)), at: .zero)
            scene.hovers.append(HoverRegion(rect: CGRect(x: x - gap / 2, y: 0, width: style.badge + gap, height: style.badge + padY * 2), text: hover))
            x += style.badge + gap
        }
        scene.size = CGSize(width: x - gap + padX, height: style.badge + padY * 2)
        return scene
    }
}
