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
        model.ingest(Snapshot.sample(performance: machine.performance, efficiency: machine.efficiency))
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
            gpu: .unavailable("x"), power: .unavailable("x"), ane: .unavailable("x"))
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

    /// Each number under the core columns is centered under its own column.
    @Test func coreNumbersSitUnderTheirColumns() {
        let model = Self.model(MachineShape(performance: 10, efficiency: 4), ModuleID.stacked + ModuleID.added)
        for columns in [1, 2] {
            let choice = LayoutChoice(candidate: LayoutCandidate(tier: .detailed, columns: columns, processCount: 12), scale: 1.5, extraWidth: 33)
            let scene = Self.scene(model, choice, snapshot: model.snapshot)
            let bars = try! #require(scene.bars)
            let slots = CoreBarsGeometry.slots(
                kinds: bars.cores.map(\.kind), width: bars.rect.width, gap: bars.gap, groupGap: bars.groupGap)
            #expect(slots.count == bars.cores.count, "the columns are the cores and nothing else")
            let numbers = scene.texts.filter { $0.font == model.style(scale: 1.5).coreNumber }
            #expect(numbers.count == slots.count)
            for (number, slot) in zip(numbers, slots) {
                #expect(abs((number.x + number.width / 2) - (bars.rect.minX + slot.x + slot.width / 2)) < 0.01)
            }
        }
    }
}
