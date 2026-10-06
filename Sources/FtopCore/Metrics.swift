import Foundation

public enum Metrics {
    /// Busy share of a core between two tick readings (user, system, idle, nice).
    /// Returns nil when no time passed or a counter went backwards, as after sleep.
    public static func usage(previous: [UInt32], current: [UInt32]) -> Double? {
        guard previous.count == 4, current.count == 4 else { return nil }
        var deltas = [Double](repeating: 0, count: 4)
        for index in 0..<4 {
            // Tick counters are 32-bit and wrap; wrapping subtraction yields the true delta.
            deltas[index] = Double(current[index] &- previous[index])
            if deltas[index] > 1_000_000_000 { return nil }
        }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return nil }
        let idle = deltas[2]
        return min(1, max(0, (total - idle) / total))
    }

    /// Bytes per second between two cumulative counters. Returns nil when the counter
    /// reset (interface went away, or the machine slept) or no time passed.
    public static func rate(previous: UInt64, current: UInt64, seconds: Double) -> Double? {
        guard seconds > 0, current >= previous else { return nil }
        return Double(current - previous) / seconds
    }

    /// Percent of one core used between two cumulative CPU-time readings.
    public static func cpuPercent(previousNanoseconds: UInt64, currentNanoseconds: UInt64, seconds: Double) -> Double? {
        guard seconds > 0, currentNanoseconds >= previousNanoseconds else { return nil }
        return Double(currentNanoseconds - previousNanoseconds) / (seconds * 1_000_000_000) * 100
    }
}
