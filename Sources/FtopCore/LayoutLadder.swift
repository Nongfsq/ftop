import Foundation

/// How much the panel shows. Ordered richest first.
public enum Tier: Int, Sendable, Codable, CaseIterable {
    /// Core columns with usage and frequency numbers under each, full memory detail.
    case detailed
    /// Core columns, full memory detail.
    case full
    /// Core columns, memory bar without the compressed and swap figures.
    case compact
    /// For a desktop corner: CPU percent, core columns, memory bar, network rates.
    case corner
    /// One line or one narrow stack.
    case strip
    /// CPU percent and the memory-pressure dot.
    case micro
}

public enum StripStyle: Int, Sendable, Codable {
    /// Cores, CPU, temperature, memory, network, top process.
    case rich
    /// Cores, CPU, memory, network.
    case plain
    /// The plain items stacked for a tall, narrow window.
    case vertical
}

public struct LayoutCandidate: Hashable, Sendable, Codable {
    public var tier: Tier
    public var columns: Int
    public var processCount: Int
    public var strip: StripStyle?
    /// A further column listing processes by memory, beside the list by CPU.
    public var memoryList: Bool

    public init(tier: Tier, columns: Int = 1, processCount: Int = 0, strip: StripStyle? = nil, memoryList: Bool = false) {
        self.tier = tier
        self.columns = columns
        self.processCount = processCount
        self.strip = strip
        self.memoryList = memoryList
    }
}

public struct Extent: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct LayoutChoice: Sendable, Equatable, Codable {
    public var candidate: LayoutCandidate
    /// Multiplier applied to every type size and metric of the candidate.
    public var scale: Double
    /// Extra room given to the parts of the layout that can grow (core columns, name
    /// column), in points at scale 1.
    public var extraWidth: Double
    public var extraHeight: Double

    public init(candidate: LayoutCandidate, scale: Double, extraWidth: Double = 0, extraHeight: Double = 0) {
        self.candidate = candidate
        self.scale = scale
        self.extraWidth = extraWidth
        self.extraHeight = extraHeight
    }
}

/// Chooses what the panel shows for the size the user dragged the window to.
///
/// Every candidate is a fixed composition that can grow a limited amount where growing
/// keeps it well proportioned; the window then snaps to the chosen one. The choice is
/// the candidate that covers the most of the dragged size, so the snap moves the edges
/// as little as possible; among candidates that cover nearly as much, the one with
/// more content wins.
public enum LayoutLadder {
    /// A large window gets more content, not larger type: past this the panel would only
    /// be magnified, which says nothing more and costs more to draw.
    public static let maximumScale = 1.3
    /// Strips may shrink this far before the panel gives up their content.
    public static let minimumStripScale = 0.76
    public static let minimumMicroScale = 0.45
    /// A richer candidate wins when it covers at least this share of the best coverage.
    static let richnessTolerance = 0.9

    /// Process row counts a layout may show, largest first.
    public static func processCounts(maxProcesses: Int, showsProcesses: Bool) -> [Int] {
        showsProcesses ? [24, 16, 12, 9, 7, 5, 3].filter { $0 <= max(3, maxProcesses) } : []
    }

    /// Every candidate, richest first.
    public static func candidates(maxProcesses: Int, showsProcesses: Bool) -> [LayoutCandidate] {
        let counts = processCounts(maxProcesses: maxProcesses, showsProcesses: showsProcesses)
        // Three columns only where the middle column (memory, network) is about as
        // tall as the process list beside it; otherwise it leaves a hole.
        let threeColumnCount = counts.contains(5) ? 5 : counts.last
        var list: [LayoutCandidate] = []
        func add(_ tier: Tier, _ count: Int) {
            // A second list, by memory, once the list by CPU is long enough to stand beside.
            if count >= 7, tier != .compact { list.append(LayoutCandidate(tier: tier, columns: 2, processCount: count, memoryList: true)) }
            for columns in [1, 2, 3] where columns < 3 || (count > 0 && count == threeColumnCount) {
                list.append(LayoutCandidate(tier: tier, columns: columns, processCount: count))
            }
        }
        // More detail per core comes before more process rows; both come before dropping processes.
        for count in counts { add(.detailed, count) }
        for count in counts { add(.full, count) }
        if showsProcesses { add(.compact, 3) }
        add(.detailed, 0)
        add(.full, 0)
        add(.compact, 0)
        list.append(LayoutCandidate(tier: .corner))
        for style in [StripStyle.rich, .plain, .vertical] { list.append(LayoutCandidate(tier: .strip, strip: style)) }
        list.append(LayoutCandidate(tier: .micro))
        return list
    }

    /// `measure` returns a candidate's size at scale 1; `stretch` how much wider and
    /// taller than that it may be drawn, also at scale 1.
    public static func choose(
        available: Extent,
        maxProcesses: Int = 12,
        showsProcesses: Bool = true,
        measure: (LayoutCandidate) -> Extent,
        stretch: (LayoutCandidate) -> Extent = { _ in Extent(width: 0, height: 0) }
    ) -> LayoutChoice {
        let area = max(1, available.width * available.height)
        var fitting: [(choice: LayoutChoice, coverage: Double)] = []
        for candidate in candidates(maxProcesses: maxProcesses, showsProcesses: showsProcesses) {
            let size = measure(candidate)
            let fit = fitScale(of: size, in: available)
            let floor: Double
            switch candidate.tier {
            case .strip: floor = minimumStripScale
            case .micro: floor = minimumMicroScale
            default: floor = 1
            }
            guard fit >= floor else { continue }
            let scale = min(fit, maximumScale)
            let limit = stretch(candidate)
            let extraWidth = min(limit.width, max(0, available.width / scale - size.width))
            let extraHeight = min(limit.height, max(0, available.height / scale - size.height))
            let covered = (size.width + extraWidth) * scale * (size.height + extraHeight) * scale
            fitting.append((LayoutChoice(candidate: candidate, scale: scale, extraWidth: extraWidth, extraHeight: extraHeight), covered / area))
        }
        guard let best = fitting.map(\.coverage).max() else {
            return LayoutChoice(candidate: LayoutCandidate(tier: .micro), scale: minimumMicroScale)
        }
        // `fitting` is in richness order, so the first one close enough to the best is the richest.
        return fitting.first { $0.coverage >= best * richnessTolerance }!.choice
    }

    static func fitScale(of size: Extent, in available: Extent) -> Double {
        guard size.width > 0, size.height > 0 else { return 0 }
        return min(available.width / size.width, available.height / size.height)
    }
}
