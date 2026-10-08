import AppKit
import FtopCore

/// Holds what the panel shows — the latest reading, the settings, and the chosen
/// layout — and turns it into a scene on the canvas.
@MainActor
public final class PanelModel {
    public let canvas = PanelCanvasView()
    public private(set) var config = Config()
    public private(set) var snapshot: Snapshot?
    public private(set) var machine = MachineShape()
    public private(set) var choice = PanelModel.firstChoice
    public var motionAllowed = true

    /// What a first launch shows: the essentials with the three busiest processes.
    public static let firstChoice = LayoutChoice(candidate: LayoutCandidate(tier: .full, processCount: 3), scale: 1.2, extraWidth: 24)

    /// Candidate sizes at scale 1 for the current machine and settings.
    private var sizes: [LayoutCandidate: Extent] = [:]

    /// The process rankings as shown, which change less often than the readings do.
    private var cpuRanking = SteadyRanking.cpu
    private var memoryRanking = SteadyRanking.memory

    public init() {}

    // MARK: Inputs

    /// Returns true when the change can alter the size of the current layout.
    @discardableResult
    public func apply(_ new: Config) -> Bool {
        let layoutChanged = new.shown != config.shown || new.maxProcesses != config.maxProcesses || new.language != config.language
        config = new
        Strings.language = new.language
        if layoutChanged { sizes = [:] }
        return layoutChanged
    }

    /// Returns true when the core counts changed, which changes every layout's size.
    @discardableResult
    public func ingest(_ new: Snapshot) -> Bool {
        var new = new
        if let list = new.processes.value {
            let elapsed = snapshot.map { min(10, max(0, new.time.timeIntervalSince($0.time))) } ?? 0
            // Rows stay where they are while the pointer is on them, so a click lands on the row it was aimed at.
            new.processes = .value(list.steadied(cpu: &cpuRanking, memory: &memoryRanking, elapsed: elapsed, hold: canvas.pointerOnProcesses))
        }
        snapshot = new
        guard let cpu = new.cpu.value else { return false }
        let shape = MachineShape(performance: cpu.performance.count, efficiency: cpu.efficiency.count)
        guard shape != machine else { return false }
        machine = shape
        sizes = [:]
        return true
    }

    public func setMachine(_ shape: MachineShape) {
        guard shape != machine else { return }
        machine = shape
        sizes = [:]
    }

    // MARK: Layout

    private var showsProcesses: Bool { config.modules.contains(.processes) }

    public func style(scale: Double) -> PanelStyle {
        PanelStyle(scale: scale, palette: config.palette, motion: config.motion && motionAllowed, interval: config.interval)
    }

    private func builder(scale: Double, live: Bool) -> SceneBuilder {
        var builder = SceneBuilder(snapshot: live ? snapshot : nil, machine: machine, modules: config.shown, style: style(scale: scale))
        builder.processSort = config.processSort
        return builder
    }

    /// The size a layout needs. It does not depend on the readings.
    public func size(of choice: LayoutChoice) -> CGSize {
        builder(scale: choice.scale, live: false).build(choice).size
    }

    private func measure(_ candidate: LayoutCandidate) -> Extent {
        if let known = sizes[candidate] { return known }
        let size = size(of: LayoutChoice(candidate: candidate, scale: 1))
        let extent = Extent(width: size.width, height: size.height)
        sizes[candidate] = extent
        return extent
    }

    /// The layout for a window of `size`, adjusted so the real scene fits it exactly.
    ///
    /// `coarse` is for the many sizes passed through while an edge is dragged: scale moves
    /// in larger steps, so most of them reuse type sizes that are already typeset.
    public func choice(for size: CGSize, coarse: Bool = false) -> LayoutChoice {
        let modules = config.shown
        var choice = LayoutLadder.choose(
            available: Extent(width: size.width, height: size.height), maxProcesses: config.maxProcesses, showsProcesses: showsProcesses,
            measure: measure, stretch: { SceneBuilder.stretchLimit($0, modules: modules) })
        // Whole percents keep the font caches small while the window is dragged.
        let steps: Double = coarse ? 20 : 100
        choice.scale = max(LayoutLadder.minimumMicroScale, (choice.scale * steps).rounded(.down) / steps)
        choice.extraWidth = 0
        choice.extraHeight = 0
        // Text does not scale perfectly linearly; shrink until the real scene fits.
        var natural = self.size(of: choice)
        for _ in 0..<4 {
            let ratio = min(size.width / max(1, natural.width), size.height / max(1, natural.height))
            guard ratio < 0.999, choice.scale > LayoutLadder.minimumMicroScale else { break }
            choice.scale = max(LayoutLadder.minimumMicroScale, min(choice.scale - 1 / steps, (choice.scale * ratio * steps).rounded(.down) / steps))
            natural = self.size(of: choice)
        }
        // Then let the parts that can grow take what is left, in whole points.
        let limit = SceneBuilder.stretchLimit(choice.candidate, modules: modules)
        choice.extraWidth = min(limit.width, max(0, (size.width - natural.width).rounded(.down)) / choice.scale)
        choice.extraHeight = min(limit.height, max(0, (size.height - natural.height).rounded(.down)) / choice.scale)
        // Scene sizes are rounded up to whole points; take back any point that rounding added.
        for _ in 0..<2 where choice.extraWidth > 0 || choice.extraHeight > 0 {
            let grown = self.size(of: choice)
            if grown.width > size.width { choice.extraWidth = max(0, choice.extraWidth - (grown.width - size.width + 0.01) / choice.scale) }
            if grown.height > size.height { choice.extraHeight = max(0, choice.extraHeight - (grown.height - size.height + 0.01) / choice.scale) }
        }
        return choice
    }

    /// Whether `candidate` is still offered under the current settings.
    public func offers(_ candidate: LayoutCandidate) -> Bool {
        LayoutLadder.candidates(maxProcesses: config.maxProcesses, showsProcesses: showsProcesses).contains(candidate)
    }

    public func setChoice(_ new: LayoutChoice) {
        let changedLayout = new.candidate != choice.candidate
        choice = new
        render(fade: changedLayout)
    }

    /// The size the window should have to hug the current layout.
    public var hugSize: CGSize { size(of: choice) }

    public func render(fade: Bool = false) {
        let scene = builder(scale: choice.scale, live: true).build(choice)
        canvas.show(scene, style: style(scale: choice.scale), pinned: config.floating, fade: fade)
    }
}
