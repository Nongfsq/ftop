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
            let visible = modules.filter { $0 != .processes || candidate.processCount > 0 }
            let columns = min(candidate.columns, visible.count)
            if candidate.memoryList, candidate.processCount > 0 { return Extent(width: 70 * Double(min(2, visible.count) + 1), height: 0) }
            if columns <= 1 { return Extent(width: 110, height: visible.contains(.cpu) ? 150 : 0) }
            return Extent(width: 70 * Double(columns), height: 0)
        }
    }

    // MARK: Pieces

    private enum Anchor { case leading, center, trailing }

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

    private var cpuReason: String { snapshot?.cpu.reason ?? Strings.pick("no reading yet", "尚无读数") }
    private var totalText: String { memory.map { Format.gigabytesCompact($0.total) } ?? "—" }

    private var memoryHover: String {
        guard let memory else { return snapshot?.memory.reason ?? "" }
        return Strings.pick("Memory used", "内存已用") + " \(Format.gigabytes(memory.used)) / \(Format.gigabytesCompact(memory.total)) GB"
    }

    /// Right-hand column shared by memory, network, and processes; wide enough for each.
    private var side: CGFloat {
        let rate = width("↑", style.body) + style.points(4) + width("888.8", style.bodyStrong) + style.points(3) + width("MB/s", style.caption)
        return max(style.sideColumn, labeledWidth(Strings.swap), rate, style.processCPUWidth + style.innerGap + style.processMemoryWidth)
    }

    private func labeledWidth(_ label: String) -> CGFloat {
        width(label, style.caption) + style.points(4) + width("88.8", style.captionStrong) + style.points(4) + width("GB", style.caption)
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

    private func miniBarsWidth() -> CGFloat {
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

    private func cpuModule(width fixedWidth: CGFloat?, height fixedHeight: CGFloat?, numbers: Bool, minimumBars: CGFloat) -> Scene {
        var scene = Scene()
        let kinds = machine.kinds
        let column = numbers ? style.coreNumberedWidth : style.coreSlimWidth
        let barsMinimum = CoreBarsGeometry.minimumWidth(kinds: kinds, column: column, gap: style.coreGap, groupGap: style.coreGroupGap)
        let headerMinimum =
            width("100", style.display) + style.points(1) + width("%", style.displayUnit) + style.points(10) + width("100°", style.body)
        let total = fixedWidth ?? max(barsMinimum, headerMinimum)

        // Header: the big number sits with its top at the module's top edge.
        let baseline = cap(style.display)
        let number = text(cpu.map { Format.percent($0.usage) } ?? "—", style.display, .ink, x: 0, baseline: baseline)
        scene.texts.append(number)
        let unit = text("%", style.displayUnit, .secondary, x: number.x + number.width + style.points(1), baseline: baseline)
        scene.texts.append(unit)
        scene.hovers.append(
            HoverRegion(
                rect: CGRect(x: 0, y: 0, width: unit.x + unit.width, height: baseline),
                text: cpu.map { Strings.pick("CPU usage", "处理器总占用") + " \(Format.percent($0.usage))%" } ?? cpuReason))
        let temperature = cpu?.temperature
        let degrees = text(temperature?.value.map { Format.degrees($0.celsius) } ?? "—", style.body, .secondary, x: total, baseline: baseline, anchor: .trailing)
        scene.texts.append(degrees)
        scene.hovers.append(
            HoverRegion(
                rect: degrees.frame.insetBy(dx: -style.points(4), dy: 0),
                text: temperature?.value.map(Strings.temperature) ?? temperature?.reason ?? cpuReason))

        let barsTop = baseline + style.innerGap
        let usageBaseline = style.points(5) + cap(style.coreNumber)
        let frequencyBaseline = usageBaseline + style.points(4) + cap(style.tiny)
        let numbersHeight = numbers ? frequencyBaseline : 0
        let barsHeight = max(minimumBars, (fixedHeight ?? 0) - barsTop - numbersHeight)
        let rect = CGRect(x: 0, y: barsTop, width: total, height: barsHeight)
        scene.append(bars(in: rect, mini: false, hoverHeight: barsHeight + numbersHeight), at: .zero)

        if numbers {
            let list = cores
            let slots = CoreBarsGeometry.slots(kinds: kinds, width: total, gap: style.coreGap, groupGap: style.coreGroupGap)
            for (index, slot) in slots.enumerated() where index < list.count {
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
        let dot = style.points(8)
        let pressureWidth = detail ? (Strings.pressureWords.map { width($0, style.caption) }.max() ?? 0) + style.points(5) : 0
        let totalLabel = "/ \(totalText) GB"
        let headerMinimum =
            width("88.8", style.emphasis) + style.points(5) + width("/ 888 GB", style.caption) + style.points(8) + pressureWidth + dot
        let barMinimum = style.points(56) + style.rowGap + side
        let detailMinimum = detail ? labeledWidth(Strings.compressed) + style.rowGap + side : 0
        let total = fixed ?? max(headerMinimum, barMinimum, detailMinimum)
        let baseline = cap(style.emphasis)
        let barTop = baseline + style.innerGap
        let barHeight = style.points(6)
        let detailBaseline = barTop + barHeight + style.points(9) + cap(style.caption)
        scene.size = CGSize(width: total, height: detail ? detailBaseline : barTop + barHeight)

        guard let memory else {
            return unavailable(snapshot?.memory.reason ?? Strings.pick("no reading yet", "尚无读数"), width: total, height: scene.size.height)
        }
        let used = text(Format.gigabytes(memory.used), style.emphasis, .ink, x: 0, baseline: baseline)
        scene.texts.append(used)
        scene.texts.append(text(totalLabel, style.caption, .secondary, x: used.x + used.width + style.points(5), baseline: baseline))
        scene.hovers.append(HoverRegion(rect: CGRect(x: 0, y: 0, width: total, height: baseline), text: memoryHover))

        // The dot is centered on the caption beside it.
        let level = memory.pressure.value
        let dotRect = CGRect(x: total - dot, y: baseline - cap(style.caption) / 2 - dot / 2, width: dot, height: dot)
        scene.shapes.append(ShapeItem(rect: dotRect, paint: PanelStyle.pressurePaint(level), kind: .circle))
        var pressureRect = dotRect
        if detail, let level {
            let word = text(Strings.pressure(level), style.caption, .secondary, x: dotRect.minX - style.points(5), baseline: baseline, anchor: .trailing)
            scene.texts.append(word)
            pressureRect = pressureRect.union(word.frame)
        }
        scene.hovers.append(
            HoverRegion(
                rect: pressureRect.insetBy(dx: -style.points(3), dy: -style.points(3)),
                text: Strings.pick("Memory pressure", "内存压力") + " " + (level.map(Strings.pressure) ?? memory.pressure.reason ?? "")))

        let sideLeft = total - side
        let barRect = CGRect(x: 0, y: barTop, width: sideLeft - style.rowGap, height: barHeight)
        let paint = PanelStyle.pressurePaint(level ?? .normal)
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
    private func labeled(_ label: String, _ value: String, x: CGFloat, baseline: CGFloat) -> Scene {
        var scene = Scene()
        let name = text(label, style.caption, .secondary, x: x, baseline: baseline)
        let number = text(value, style.captionStrong, .ink, x: name.x + name.width + style.points(4), baseline: baseline)
        let unit = text("GB", style.caption, .secondary, x: number.x + number.width + style.points(4), baseline: baseline)
        scene.texts += [name, number, unit]
        scene.hovers.append(HoverRegion(rect: name.frame.union(unit.frame), text: "\(label) \(value) GB"))
        return scene
    }

    private func networkModule(width fixed: CGFloat?, longUnits: Bool) -> Scene {
        let unit = longUnits ? "MB/s" : "M"
        let rateWidth = width("↓", style.body) + style.points(4) + width("888.8", style.bodyStrong) + style.points(3) + width(unit, style.caption)
        let total = fixed ?? rateWidth + style.rowGap + side
        let baseline = cap(style.body)
        guard let network = snapshot?.network.value else {
            return unavailable(snapshot?.network.reason ?? Strings.pick("no reading yet", "尚无读数"), width: total, height: baseline)
        }
        var scene = Scene()
        scene.size = CGSize(width: total, height: baseline)
        scene.append(rate("↓", network.downBytesPerSecond, Strings.pick("Download", "下载"), long: longUnits, x: 0, baseline: baseline), at: .zero)
        scene.append(rate("↑", network.upBytesPerSecond, Strings.pick("Upload", "上传"), long: longUnits, x: total - side, baseline: baseline), at: .zero)
        return scene
    }

    private func rate(_ arrow: String, _ value: Double, _ label: String, long: Bool, x: CGFloat, baseline: CGFloat) -> Scene {
        var scene = Scene()
        let quantity = Format.rate(value)
        let mark = text(arrow, style.body, .secondary, x: x, baseline: baseline)
        let number = text(quantity.number, style.bodyStrong, .ink, x: mark.x + mark.width + style.points(4), baseline: baseline)
        let unit = text(long ? quantity.unit : quantity.shortUnit, style.caption, .secondary, x: number.x + number.width + style.points(3), baseline: baseline)
        scene.texts += [mark, number, unit]
        scene.hovers.append(HoverRegion(rect: mark.frame.union(unit.frame), text: "\(label) \(quantity.text)"))
        return scene
    }

    /// `byMemory` lists the processes holding the most memory instead of the busiest.
    /// Both lists have the same columns; the figure a list is sorted by is the strong one.
    private func processModule(width fixed: CGFloat?, count: Int, roomy: Bool, byMemory: Bool = false) -> Scene {
        let nameWidth = roomy ? style.processNameWideWidth : style.processNameWidth
        let total = fixed ?? nameWidth + style.rowGap + side
        let pitch = processPitch
        let first = cap(style.body)
        let height = first + CGFloat(max(0, count - 1)) * pitch
        guard let list = snapshot?.processes.value else {
            return unavailable(snapshot?.processes.reason ?? Strings.pick("no reading yet", "尚无读数"), width: total, height: height)
        }
        if byMemory, list.byMemory.isEmpty {
            return unavailable(
                Strings.pick("Run `sudo ftop grant` again to list processes by memory", "再执行一次 sudo ftop grant 才能按内存列出进程"), width: total,
                height: height)
        }
        var scene = Scene()
        scene.size = CGSize(width: total, height: height)
        let nameRoom = total - side - style.rowGap
        for (index, process) in (byMemory ? list.byMemory : list.top).prefix(count).enumerated() {
            let baseline = first + CGFloat(index) * pitch
            let percent = "\(Int(process.cpuPercent.rounded()))%"
            let memoryText = Format.processMemory(process.memoryBytes)
            scene.texts.append(text(Typesetter.truncated(process.name, style.body, to: nameRoom), style.body, .ink, x: 0, baseline: baseline))
            scene.texts.append(
                text(
                    percent, style.body, byMemory ? .secondary : .ink, x: total - style.processMemoryWidth - style.innerGap, baseline: baseline,
                    anchor: .trailing))
            scene.texts.append(text(memoryText, style.body, byMemory ? .ink : .secondary, x: total, baseline: baseline, anchor: .trailing))
            scene.hovers.append(
                HoverRegion(
                    rect: CGRect(x: 0, y: baseline - first - style.rowGap / 2, width: total, height: pitch),
                    text: "\(process.name) · CPU \(percent) · " + Strings.pick("memory", "内存") + " \(memoryText)"))
        }
        return scene
    }

    private var processPitch: CGFloat { Typesetter.metrics(style.body).lineHeight + style.rowGap }

    // MARK: Column layouts

    private func module(_ id: ModuleID, candidate: LayoutCandidate, width: CGFloat?, height: CGFloat? = nil, roomy: Bool) -> Scene {
        switch id {
        case .cpu:
            let numbers = candidate.tier == .detailed
            let minimum = style.points(numbers || candidate.processCount > 3 ? 84 : 44)
            return cpuModule(width: width, height: height, numbers: numbers, minimumBars: minimum)
        case .memory: return memoryModule(width: width, detail: candidate.tier != .compact)
        case .network: return networkModule(width: width, longUnits: candidate.tier != .compact)
        case .processes: return processModule(width: width, count: candidate.processCount, roomy: roomy)
        }
    }

    /// First module alone on the left, last alone on the right when there are three columns.
    private func split(_ list: [ModuleID], into count: Int) -> [[ModuleID]] {
        guard count >= 2, list.count >= count else { return [list] }
        if count == 2 { return [[list[0]], Array(list.dropFirst())] }
        return [[list[0]], Array(list.dropFirst().dropLast()), [list[list.count - 1]]]
    }

    private func columns(_ candidate: LayoutCandidate, extra: CGSize) -> Scene {
        let visible = modules.filter { $0 != .processes || candidate.processCount > 0 }
        let memoryList = candidate.memoryList && candidate.processCount > 0 && modules.contains(.processes)
        // With two process lists the lists are columns of their own, equal and side by
        // side, and everything else stacks in the first column.
        let groups: [[ModuleID]]
        if memoryList, visible.count > 1 {
            groups = [visible.filter { $0 != .processes }, [.processes]]
        } else {
            groups = split(visible, into: min(candidate.columns, visible.count))
        }
        let roomy = groups.count > 1 || memoryList
        // Where a column starts with the process list, its first row shares a baseline
        // with the memory figure heading the column beside it.
        let memoryLeads = groups.contains { $0.first == .memory }
        func lead(_ group: [ModuleID]) -> CGFloat {
            roomy && memoryLeads && group.first == .processes ? cap(style.emphasis) - cap(style.body) : 0
        }

        let share = extra.width / CGFloat(groups.count + (memoryList ? 1 : 0))
        let widths = groups.map { group in
            (group.map { module($0, candidate: candidate, width: nil, roomy: roomy).size.width }.max() ?? 0) + share
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
            heights.append(lead(group) + built.reduce(0) { $0 + $1.size.height } + style.moduleGap * CGFloat(max(0, built.count - 1)))
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
            var y = style.paddingY + lead(group)
            for (position, block) in blocks.enumerated() {
                // A shorter middle column ends level with its neighbors: its last module sits at the bottom.
                if groups.count == 3, index == 1, blocks.count > 1, position == blocks.count - 1 {
                    y = max(y, style.paddingY + tallest - block.size.height)
                }
                scene.append(block, at: CGPoint(x: x, y: y))
                y += block.size.height + style.moduleGap
            }
            x += widths[index] + style.columnGap
        }
        if memoryList {
            // The same rows as the list beside it, on the same lines.
            let listGroup = groups.first { $0.contains(.processes) } ?? []
            let width = processModule(width: nil, count: candidate.processCount, roomy: true).size.width + share
            scene.append(
                processModule(width: width, count: candidate.processCount, roomy: true, byMemory: true),
                at: CGPoint(x: x, y: style.paddingY + lead(listGroup)))
            x += width + style.columnGap
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
        let rateWidth = width("↓", style.body) + style.points(1) + width("888.8M", style.body)
        let barsMinimum = CoreBarsGeometry.minimumWidth(kinds: machine.kinds, column: style.coreSlimWidth, gap: style.coreGap, groupGap: style.coreGroupGap)
        let headerMinimum =
            width("100", style.cornerDisplay) + style.points(1) + width("%", style.cornerUnit) + style.points(10) + width("100°", style.body)
        let total = max(barsMinimum, headerMinimum, rateWidth * 2 + style.points(10)) + extra.width
        var y = padY

        if modules.contains(.cpu) {
            let baseline = y + cap(style.cornerDisplay)
            let number = text(cpu.map { Format.percent($0.usage) } ?? "—", style.cornerDisplay, .ink, x: padX, baseline: baseline)
            scene.texts.append(number)
            scene.texts.append(text("%", style.cornerUnit, .secondary, x: number.x + number.width + style.points(1), baseline: baseline))
            scene.append(temperatureText(x: padX + total, baseline: baseline, anchor: .trailing), at: .zero)
            y = baseline + gap
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
        if modules.contains(.network) {
            let baseline = y + cap(style.body)
            scene.append(shortRate("↓", \.downBytesPerSecond, x: padX, baseline: baseline, anchor: .leading), at: .zero)
            scene.append(shortRate("↑", \.upBytesPerSecond, x: padX + total / 2 + style.points(5), baseline: baseline, anchor: .leading), at: .zero)
            y = baseline + gap
        }
        scene.size = CGSize(width: total + padX * 2, height: y - gap + padY)
        return scene
    }

    // MARK: Strips

    private func cpuText(x: CGFloat, baseline: CGFloat, anchor: Anchor) -> Scene {
        var scene = Scene()
        let item = text((cpu.map { Format.percent($0.usage) } ?? "—") + "%", style.bodyStrong, .ink, x: x, baseline: baseline, anchor: anchor)
        scene.texts.append(item)
        scene.hovers.append(
            HoverRegion(rect: item.frame, text: cpu.map { Strings.pick("CPU usage", "处理器总占用") + " \(Format.percent($0.usage))%" } ?? cpuReason))
        return scene
    }

    private func temperatureText(x: CGFloat, baseline: CGFloat, anchor: Anchor) -> Scene {
        var scene = Scene()
        let temperature = cpu?.temperature
        let item = text(temperature?.value.map { Format.degrees($0.celsius) } ?? "—", style.body, .secondary, x: x, baseline: baseline, anchor: anchor)
        scene.texts.append(item)
        scene.hovers.append(
            HoverRegion(rect: item.frame.insetBy(dx: -style.points(3), dy: 0), text: temperature?.value.map(Strings.temperature) ?? temperature?.reason ?? cpuReason))
        return scene
    }

    private func shortRate(_ arrow: String, _ keyPath: KeyPath<NetworkSample, Double>, x: CGFloat, baseline: CGFloat, anchor: Anchor) -> Scene {
        var scene = Scene()
        let network = snapshot?.network.value
        let value = network.map { Format.rate($0[keyPath: keyPath]).shortText } ?? "—"
        let gap = style.points(1)
        let total = width(arrow, style.body) + gap + width(value, style.body)
        let left = anchor == .center ? x - total / 2 : x
        let mark = text(arrow, style.body, .secondary, x: left, baseline: baseline)
        let number = text(value, style.body, .ink, x: mark.x + mark.width + gap, baseline: baseline)
        scene.texts += [mark, number]
        let label = arrow == "↓" ? Strings.pick("Download", "下载") : Strings.pick("Upload", "上传")
        scene.hovers.append(
            HoverRegion(
                rect: mark.frame.union(number.frame),
                text: network.map { "\(label) \(Format.rate($0[keyPath: keyPath]).text)" } ?? snapshot?.network.reason ?? ""))
        return scene
    }

    /// The pressure dot followed by memory as "21.5 / 36G" or "60%".
    private func memoryText(full: Bool, x: CGFloat, baseline: CGFloat, centered: Bool = false) -> (scene: Scene, width: CGFloat) {
        var scene = Scene()
        let dot = style.points(7)
        let gap = style.points(4)
        let value: String
        let widest: String
        if full {
            value = memory.map { "\(Format.gigabytes($0.used)) / \(Format.gigabytesCompact($0.total))G" } ?? "—"
            widest = "88.8 / 888G"
        } else {
            value = memory.map { "\(Format.percent($0.usedFraction))%" } ?? "—"
            widest = "100%"
        }
        let reserved = dot + gap + width(widest, style.body)
        let left = centered ? x - (dot + gap + width(value, style.body)) / 2 : x
        let dotRect = CGRect(x: left, y: baseline - cap(style.body) / 2 - dot / 2, width: dot, height: dot)
        scene.shapes.append(ShapeItem(rect: dotRect, paint: PanelStyle.pressurePaint(memory?.pressure.value), kind: .circle))
        let item = text(value, style.body, .ink, x: dotRect.maxX + gap, baseline: baseline)
        scene.texts.append(item)
        scene.hovers.append(HoverRegion(rect: dotRect.union(item.frame), text: memoryHover))
        return (scene, reserved)
    }

    private func horizontalStrip(rich: Bool) -> Scene {
        var scene = Scene()
        let padX = style.points(12)
        let padY = style.points(7)
        let gap = style.points(12)
        let baseline = padY + cap(style.body)
        let barsHeight = style.points(14)
        var x = padX

        if modules.contains(.cpu) {
            let rect = CGRect(x: x, y: baseline - cap(style.body) / 2 - barsHeight / 2, width: miniBarsWidth(), height: barsHeight)
            scene.append(bars(in: rect, mini: true), at: .zero)
            x = rect.maxX + gap
            scene.append(cpuText(x: x, baseline: baseline, anchor: .leading), at: .zero)
            x += width("100%", style.bodyStrong) + gap
            if rich {
                scene.append(temperatureText(x: x, baseline: baseline, anchor: .leading), at: .zero)
                x += width("100°", style.body) + gap
            }
        }
        if modules.contains(.memory) {
            let block = memoryText(full: rich, x: x, baseline: baseline)
            scene.append(block.scene, at: .zero)
            x += block.width + gap
        }
        if modules.contains(.network) {
            let rateWidth = width("↓", style.body) + style.points(1) + width("888.8M", style.body)
            scene.append(shortRate("↓", \.downBytesPerSecond, x: x, baseline: baseline, anchor: .leading), at: .zero)
            x += rateWidth + style.points(6)
            scene.append(shortRate("↑", \.upBytesPerSecond, x: x, baseline: baseline, anchor: .leading), at: .zero)
            x += rateWidth + gap
        }
        if rich, modules.contains(.processes) {
            let nameRoom = style.points(104)
            let percentWidth = width("888%", style.body)
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
        scene.size = CGSize(width: x - gap + padX, height: baseline + padY)
        return scene
    }

    private func verticalStrip(extra: CGSize) -> Scene {
        var scene = Scene()
        let padX = style.points(5)
        let padY = style.points(10)
        let gap = style.points(9)
        let rateWidth = width("↓", style.body) + style.points(1) + width("888.8M", style.body)
        let memoryWidth = style.points(7 + 4) + width("100%", style.body)
        let total = max(miniBarsWidth(), width("100%", style.bodyStrong), rateWidth, memoryWidth)
        let middle = padX + total / 2
        var y = padY

        if modules.contains(.cpu) {
            scene.append(cpuText(x: middle, baseline: y + cap(style.bodyStrong), anchor: .center), at: .zero)
            y += cap(style.bodyStrong) + gap
            let barsWidth = miniBarsWidth()
            let rect = CGRect(x: middle - barsWidth / 2, y: y, width: barsWidth, height: style.points(48) + extra.height)
            scene.append(bars(in: rect, mini: true), at: .zero)
            y = rect.maxY + gap
            scene.append(temperatureText(x: middle, baseline: y + cap(style.body), anchor: .center), at: .zero)
            y += cap(style.body) + gap
        }
        if modules.contains(.memory) {
            scene.append(memoryText(full: false, x: middle, baseline: y + cap(style.body), centered: true).scene, at: .zero)
            y += cap(style.body) + gap
        }
        if modules.contains(.network) {
            scene.append(shortRate("↓", \.downBytesPerSecond, x: middle, baseline: y + cap(style.body), anchor: .center), at: .zero)
            y += cap(style.body) + gap
            scene.append(shortRate("↑", \.upBytesPerSecond, x: middle, baseline: y + cap(style.body), anchor: .center), at: .zero)
            y += cap(style.body) + gap
        }
        scene.size = CGSize(width: total + padX * 2, height: y - gap + padY)
        return scene
    }

    private func micro() -> Scene {
        var scene = Scene()
        let padX = style.points(8)
        let padY = style.points(6)
        let baseline = padY + cap(style.bodyStrong)
        scene.append(cpuText(x: padX, baseline: baseline, anchor: .leading), at: .zero)
        let dot = style.points(7)
        let dotRect = CGRect(
            x: padX + width("100%", style.bodyStrong) + style.points(5), y: baseline - cap(style.bodyStrong) / 2 - dot / 2, width: dot, height: dot)
        scene.shapes.append(ShapeItem(rect: dotRect, paint: PanelStyle.pressurePaint(memory?.pressure.value), kind: .circle))
        scene.hovers.append(HoverRegion(rect: dotRect.insetBy(dx: -style.points(3), dy: -style.points(3)), text: memoryHover))
        scene.size = CGSize(width: dotRect.maxX + padX, height: baseline + padY)
        return scene
    }
}
