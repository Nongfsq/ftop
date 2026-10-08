import Foundation

/// Keeps a ranked list from reshuffling on every sample.
///
/// Readings of busy processes cross each other all the time, so a list sorted by the
/// current reading never rests. This ranks by a level that rises with the reading at
/// once and falls slowly, and lets an entry pass another only when it is clearly ahead.
public struct SteadyRanking: Sendable {
    /// An entry passes another when its level is above the other's by this share of it…
    public var relative: Double
    /// …plus this much, in the unit of the readings.
    public var margin: Double
    /// Seconds for a level to lose about two thirds of its distance to a lower reading.
    public var fall: Double

    private var levels: [String: Double] = [:]
    private var order: [String] = []

    public init(relative: Double, margin: Double, fall: Double) {
        self.relative = relative
        self.margin = margin
        self.fall = fall
    }

    /// For processor use in percent of one core.
    public static var cpu: SteadyRanking { SteadyRanking(relative: 0.12, margin: 1, fall: 4) }
    /// For memory in bytes.
    public static var memory: SteadyRanking { SteadyRanking(relative: 0.04, margin: 24 * 1_048_576, fall: 4) }

    /// The order to show `entries` in, `elapsed` seconds after the last call. With `hold`
    /// nothing already listed changes rank; entries that left are dropped and new ones go last.
    public mutating func step(_ entries: [(id: String, value: Double)], elapsed: Double, hold: Bool = false) -> [String] {
        let keep = fall > 0 ? exp(-max(0, elapsed) / fall) : 0
        var next: [String: Double] = [:]
        for entry in entries where next[entry.id] == nil {
            next[entry.id] = levels[entry.id].map { max(entry.value, entry.value + ($0 - entry.value) * keep) } ?? entry.value
        }
        levels = next

        var result = order.filter { next[$0] != nil }
        let known = Set(result)
        var seen = known
        let arrivals = entries.filter { seen.insert($0.id).inserted }.enumerated()
            .sorted { $0.element.value != $1.element.value ? $0.element.value > $1.element.value : $0.offset < $1.offset }
        result += arrivals.map(\.element.id)
        // Arrivals are placed even under a hold when there was no list before.
        if !hold || known.isEmpty {
            for index in result.indices.dropFirst() {
                let level = next[result[index]]!
                guard let target = result[..<index].firstIndex(where: { level > next[$0]! * (1 + relative) + margin }) else { continue }
                result.insert(result.remove(at: index), at: target)
            }
        }
        order = result
        return result
    }
}

extension ProcessList {
    /// This list with both rankings put in the order `cpu` and `memory` settle on.
    public func steadied(cpu: inout SteadyRanking, memory: inout SteadyRanking, elapsed: Double, hold: Bool) -> ProcessList {
        func arrange(_ samples: [ProcessSample], _ ranking: inout SteadyRanking, _ value: (ProcessSample) -> Double) -> [ProcessSample] {
            let byID = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return ranking.step(samples.map { ($0.id, value($0)) }, elapsed: elapsed, hold: hold).compactMap { byID[$0] }
        }
        var list = self
        list.top = arrange(top, &cpu) { $0.cpuPercent }
        list.byMemory = arrange(byMemory, &memory) { Double($0.memoryBytes) }
        return list
    }
}
