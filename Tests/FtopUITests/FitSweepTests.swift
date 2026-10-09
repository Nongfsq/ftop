import AppKit
import Testing

@testable import FtopCore
@testable import FtopUI

/// The product's main promise: at every window size the chosen layout fits completely,
/// and inside it nothing is cut off or drawn over something else.
@MainActor
@Suite struct FitSweepTests {
    static let machines: [MachineShape] = [
        MachineShape(performance: 4, efficiency: 4), MachineShape(performance: 8, efficiency: 4), MachineShape(performance: 10, efficiency: 4),
        MachineShape(performance: 12, efficiency: 4), MachineShape(performance: 8, efficiency: 0),
        MachineShape(groups: [2, 4, 6]), MachineShape(groups: [2, 2, 4, 4]),
    ]
    static let moduleSets: [[ModuleID]] = [
        ModuleID.stacked + ModuleID.added, ModuleID.stacked, ModuleID.stacked + [.gpu], ModuleID.stacked + [.power], [.cpu, .memory, .network, .gpu, .power],
        [.cpu, .memory, .network], [.memory, .processes, .gpu, .power], [.processes, .cpu],
    ]

    static func model(_ machine: MachineShape, _ modules: [ModuleID], language: Language = .zh) -> PanelModel {
        let model = PanelModel()
        var config = Config()
        config.modules = modules.filter(ModuleID.stacked.contains)
        config.hidden = ModuleID.added.filter { !modules.contains($0) }
        config.language = language
        model.apply(config)
        model.ingest(Snapshot.sample(groups: machine.groups))
        return model
    }

    static func scene(_ model: PanelModel, _ choice: LayoutChoice, snapshot: Snapshot?) -> Scene {
        SceneBuilder(snapshot: snapshot, machine: model.machine, modules: model.config.shown, style: model.style(scale: choice.scale))
            .build(choice)
    }

    /// Everything drawn lies inside the scene, and no two pieces of text overlap.
    static func expectWellFormed(_ scene: Scene, _ label: String) {
        let bounds = CGRect(origin: .zero, size: scene.size).insetBy(dx: -0.5, dy: -0.5)
        for item in scene.texts {
            // Glyph boxes include room for descenders that these strings may not use; check the inked width and the baseline.
            #expect(item.x >= bounds.minX && item.x + item.width <= bounds.maxX, "\(label): text '\(item.string)' leaves the panel sideways")
            #expect(item.baseline <= bounds.maxY && item.frame.minY >= bounds.minY - 3, "\(label): text '\(item.string)' leaves the panel vertically")
        }
        for shape in scene.shapes { #expect(bounds.contains(shape.rect), "\(label): a shape leaves the panel") }
        if let bars = scene.bars { #expect(bounds.contains(bars.rect), "\(label): the core columns leave the panel") }
        if let bar = scene.gpuBar { #expect(bounds.contains(bar.rect), "\(label): the GPU's column leaves the panel") }
        if let rows = scene.processes {
            #expect(bounds.contains(rows.rect), "\(label): the process rows leave the panel")
            for index in rows.rows.indices {
                #expect(
                    rows.rect.insetBy(dx: -0.5, dy: -0.5).contains(rows.frame(at: index).offsetBy(dx: rows.rect.minX, dy: rows.rect.minY)),
                    "\(label): a process row leaves its area")
            }
            for item in scene.texts where CGRect(x: item.x, y: item.baseline - 4, width: item.width, height: 4).intersects(rows.rect) {
                Issue.record("\(label): '\(item.string)' overlaps the process rows")
            }
        }
        let boxes = scene.texts.map {
            ($0, CGRect(x: $0.x, y: $0.baseline - Typesetter.metrics($0.font).capHeight, width: $0.width, height: Typesetter.metrics($0.font).capHeight))
        }
        for (index, first) in boxes.enumerated() {
            for second in boxes[(index + 1)...] where first.1.insetBy(dx: 0.5, dy: 0.5).intersects(second.1.insetBy(dx: 0.5, dy: 0.5)) {
                Issue.record("\(label): '\(first.0.string)' overlaps '\(second.0.string)'")
            }
            if let bars = scene.bars, first.1.intersects(bars.rect) { Issue.record("\(label): '\(first.0.string)' overlaps the core columns") }
        }
    }

    @Test func chosenLayoutFitsAtEverySize() {
        for machine in Self.machines {
            for modules in Self.moduleSets {
                let model = Self.model(machine, modules)
                var seen: Set<LayoutCandidate> = []
                for width in stride(from: 40.0, through: 1500, by: 37) {
                    for height in stride(from: 20.0, through: 1000, by: 31) {
                        let choice = model.choice(for: CGSize(width: width, height: height))
                        let size = model.size(of: choice)
                        // Below the smallest layout the panel shrinks type as far as allowed and no further.
                        if choice.candidate.tier == .micro, choice.scale <= LayoutLadder.minimumMicroScale { continue }
                        let label = "\(machine) \(modules) \(Int(width))x\(Int(height)) \(choice)"
                        #expect(size.width <= width + 0.5 && size.height <= height + 0.5, "does not fit: \(label) needs \(size)")
                        #expect(choice.scale <= LayoutLadder.maximumScale)
                        seen.insert(choice.candidate)
                    }
                }
                #expect(seen.count >= 5, "\(machine) \(modules) used only \(seen.count) layouts")
            }
        }
    }

    @Test func everyLayoutIsWellFormedAtEveryScale() {
        for language in [Language.zh, .en] {
            for machine in Self.machines {
                for modules in Self.moduleSets {
                    let model = Self.model(machine, modules, language: language)
                    let candidates = LayoutLadder.candidates(maxProcesses: 12, showsProcesses: modules.contains(.processes))
                    for candidate in candidates {
                        let limit = SceneBuilder.stretchLimit(candidate, modules: model.config.shown)
                        for (scale, stretched) in [(LayoutLadder.minimumMicroScale, false), (0.76, true), (1, false), (1, true), (1.37, true), (2, false)] {
                            let choice = LayoutChoice(
                                candidate: candidate, scale: scale, extraWidth: stretched ? limit.width : 0, extraHeight: stretched ? limit.height : 0)
                            let scene = Self.scene(model, choice, snapshot: model.snapshot)
                            #expect(scene.size.width > 10 && scene.size.height > 6)
                            Self.expectWellFormed(scene, "\(language) \(machine) \(modules) \(candidate) x\(scale)")
                        }
                    }
                }
            }
        }
    }

    /// A layout's size must not depend on the readings, or the window would move as numbers change.
    @Test func sizeDoesNotDependOnReadings() {
        let model = Self.model(MachineShape(performance: 10, efficiency: 4), ModuleID.stacked + ModuleID.added)
        let unavailable = Snapshot(
            time: Date(), cpu: .unavailable("x"), memory: .unavailable("x"), network: .unavailable("x"), processes: .unavailable("x"),
            gpu: .unavailable("x"), power: .unavailable("x"))
        var busy = Snapshot.sample(performance: 10, efficiency: 4)
        busy.network = .value(NetworkSample(downBytesPerSecond: 999_400_000, upBytesPerSecond: 888_800_000))
        busy.gpu = .value(
            GPUSample(usage: 1, frequencyMHz: .unavailable("x"), maxFrequencyMHz: nil, memoryBytes: .value(88_800_000_000), temperature: .unavailable("x")))
        busy.power = .value(PowerSample(systemWatts: 888.8, inputWatts: .unavailable("x"), gpuWatts: .value(88.8)))
        for candidate in LayoutLadder.candidates(maxProcesses: 12, showsProcesses: true) {
            let choice = LayoutChoice(candidate: candidate, scale: 1)
            let expected = model.size(of: choice)
            for snapshot in [unavailable, busy, model.snapshot!] {
                let scene = Self.scene(model, choice, snapshot: snapshot)
                #expect(scene.size == expected, "\(candidate)")
                Self.expectWellFormed(scene, "\(candidate) with other readings")
            }
        }
    }

    /// The title row and the process list are in one unit: a process that keeps 5.4 of ten
    /// cores busy on a machine that is 54% busy reads 54, not 540.
    @Test func processFiguresAreInTheTitleRowsUnit() throws {
        let machine = MachineShape(performance: 6, efficiency: 4)
        let model = Self.model(machine, ModuleID.stacked)
        var snapshot = Snapshot.sample(performance: 6, efficiency: 4)
        var cpu = try #require(snapshot.cpu.value)
        for index in cpu.cores.indices { cpu.cores[index].usage = 0.54 }
        snapshot.cpu = .value(cpu)
        let chrome = ProcessSample(
            pid: 1, name: "Google Chrome", cpuPercent: 455, memoryBytes: 1 << 30, appPath: "/Applications/Google Chrome.app",
            members: [ProcessMember(name: "Google Chrome Helper", cpuPercent: 300, memoryBytes: 1 << 29)])
        let all = ProcessSample(pid: 2, name: "all", cpuPercent: 540, memoryBytes: 1 << 20)
        let small = ProcessSample(pid: 3, name: "small", cpuPercent: 4, memoryBytes: 1 << 20)
        snapshot.processes = .value(ProcessList(top: [all, chrome, small], byMemory: [chrome, all, small], coversAllUsers: true))

        let title = Format.percent(cpu.usage)
        #expect(title == "54")
        var listed = 0
        for candidate in LayoutLadder.candidates(maxProcesses: 12, showsProcesses: true) {
            let scene = Self.scene(model, LayoutChoice(candidate: candidate, scale: 1), snapshot: snapshot)
            guard let rows = scene.processes?.rows, rows.count == 3 else { continue }
            listed += 1
            #expect(scene.texts.contains { $0.string == title }, "\(candidate): the title row")
            #expect(rows.map(\.card.cpu) == [title, "46", "0.4"], "\(candidate)")
            #expect(rows.map(\.value) == rows.map(\.card.cpu), "\(candidate)")
            #expect(rows[1].card.members.map(\.value) == ["30"], "\(candidate)")
            // The arc stays the share of what is in use (here what the list sums to); it is not divided by the cores again.
            #expect(abs(rows[0].card.cpuShare - 540.0 / 999) < 0.001, "\(candidate)")
        }
        #expect(listed > 0)
        // The strip's busiest process, in the same unit.
        let strip = Self.scene(model, LayoutChoice(candidate: LayoutCandidate(tier: .strip, strip: .rich), scale: 1), snapshot: snapshot)
        #expect(strip.texts.contains { $0.string == title + "%" })
        #expect(strip.hovers.contains { $0.text.contains("all · CPU \(title)%") })
    }

    /// Each number under the core columns is centered under its own column.
    @Test func coreNumbersSitUnderTheirColumns() {
        let model = Self.model(MachineShape(performance: 10, efficiency: 4), ModuleID.stacked + ModuleID.added)
        for columns in [1, 2] {
            let choice = LayoutChoice(candidate: LayoutCandidate(tier: .detailed, columns: columns, processCount: 12), scale: 1.5, extraWidth: 33)
            let scene = Self.scene(model, choice, snapshot: model.snapshot)
            let bars = try! #require(scene.bars)
            let slots = CoreBarsGeometry.slots(
                groups: bars.cores.map(\.group), width: bars.rect.width, gap: bars.gap, groupGap: bars.groupGap)
            #expect(slots.count == bars.cores.count, "the columns are the cores and nothing else")
            let numbers = scene.texts.filter { $0.font == model.style(scale: 1.5).coreNumber }
            #expect(numbers.count == slots.count)
            for (number, slot) in zip(numbers, slots) {
                #expect(abs((number.x + number.width / 2) - (bars.rect.minX + slot.x + slot.width / 2)) < 0.01)
            }
        }
    }

    /// The GPU's figure starts where its column does, and the column is at least as wide as the
    /// widest figure, on every machine and in every layout that has full-size columns.
    @Test func theGPUFigureStandsOverItsColumn() {
        for machine in Self.machines + [MachineShape(groups: [5, 5, 4]), MachineShape(groups: [12, 16])] {
            for modules in [ModuleID.stacked + ModuleID.added, ModuleID.stacked + [.gpu]] {
                let model = Self.model(machine, modules)
                let cases: [(Tier, Int, Double, Double)] = [
                    (.compact, 1, 1.0, 0), (.compact, 2, 1.0, 57), (.full, 1, 1.3, 0), (.full, 2, 0.8, 91), (.detailed, 1, 1.0, 40), (.detailed, 2, 1.0, 0),
                ]
                for (tier, columns, scale, extra) in cases {
                    let choice = LayoutChoice(candidate: LayoutCandidate(tier: tier, columns: columns, processCount: 3), scale: scale, extraWidth: extra)
                    let scene = Self.scene(model, choice, snapshot: model.snapshot)
                    let label = "\(machine.groups) \(tier) c\(columns)"
                    guard let bars = scene.bars, let bar = scene.gpuBar else {
                        Issue.record("\(label): no GPU column")
                        continue
                    }
                    #expect(bar.rect.minX > bars.rect.maxX, "\(label)")
                    #expect(bar.rect.minY == bars.rect.minY, "\(label)")
                    #expect(bar.rect.height == bars.rect.height, "\(label)")
                    let badges = scene.shapes.filter {
                        if case .badge(.gpu, _) = $0.kind { return $0.rect.maxY <= bar.rect.minY }
                        return false
                    }
                    #expect(badges.count == 1, "\(label): one GPU figure above the columns")
                    #expect(abs((badges.first?.rect.minX ?? -1) - bar.rect.minX) < 0.01, "\(label): the GPU's badge starts where its column does")
                    // Nothing else above the columns but the processor's badge, at the first column's edge.
                    let above = scene.shapes.filter {
                        if case .badge = $0.kind { return $0.rect.maxY <= bars.rect.minY && $0.rect.minX < bar.rect.maxX }
                        return false
                    }
                    #expect(above.count == 2, "\(label): only the two owners above the columns")
                    #expect(above.contains { abs($0.rect.minX - bars.rect.minX) < 0.01 }, "\(label): the processor's badge starts at the first column")
                    // In one column, the GPU's column is on the line the rows below share.
                    if columns == 1 {
                        let below = scene.shapes.filter {
                            if case .badge = $0.kind { return $0.rect.minY >= bar.rect.maxY && abs($0.rect.minX - bar.rect.minX) < 0.01 }
                            return false
                        }
                        #expect(!below.isEmpty, "\(label): a badge below shares the GPU column's left edge")
                    }
                }
            }
        }
    }

    /// In the small layouts the GPU's column is as tall as the core columns and level with
    /// them; in the corner its figure starts where it does, as in the large layouts.
    @Test func theGPUColumnInTheSmallLayouts() {
        for machine in Self.machines + [MachineShape(groups: [5, 5, 4])] {
            let model = Self.model(machine, ModuleID.stacked + ModuleID.added)
            let candidates = [
                LayoutCandidate(tier: .corner), LayoutCandidate(tier: .strip, strip: .rich), LayoutCandidate(tier: .strip, strip: .vertical),
            ]
            for candidate in candidates {
                let scene = Self.scene(model, LayoutChoice(candidate: candidate, scale: 1, extraWidth: 20, extraHeight: 20), snapshot: model.snapshot)
                let label = "\(machine.groups) \(candidate.tier) \(String(describing: candidate.strip))"
                Self.expectWellFormed(scene, label)
                guard let bars = scene.bars, let bar = scene.gpuBar else {
                    Issue.record("\(label): no GPU column")
                    continue
                }
                #expect(bar.rect.minY == bars.rect.minY, "\(label)")
                #expect(bar.rect.height == bars.rect.height, "\(label)")
                #expect(bar.rect.minX > bars.rect.maxX, "\(label)")
                let badge = scene.shapes.first {
                    if case .badge(.gpu, _) = $0.kind { return true }
                    return false
                }
                if candidate.tier == .corner {
                    #expect(abs((badge?.rect.minX ?? -1) - bar.rect.minX) < 0.01, "\(label): the GPU's badge starts where its column does")
                    // Every badge is on one of two lines: the left edge, or the GPU column's.
                    for shape in scene.shapes {
                        guard case .badge = shape.kind else { continue }
                        #expect(
                            abs(shape.rect.minX - bars.rect.minX) < 0.01 || abs(shape.rect.minX - bar.rect.minX) < 0.01, "\(label): a badge off the two lines")
                    }
                } else if candidate.strip == .rich {
                    // The column, then its figure.
                    #expect((badge?.rect.minX ?? 0) > bar.rect.maxX, "\(label)")
                }
            }
            // The plain strip and the smallest layout have no GPU column.
            for candidate in [LayoutCandidate(tier: .strip, strip: .plain), LayoutCandidate(tier: .micro)] {
                #expect(Self.scene(model, LayoutChoice(candidate: candidate, scale: 1), snapshot: model.snapshot).gpuBar == nil)
            }
        }
    }
}
