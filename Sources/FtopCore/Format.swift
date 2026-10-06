import Foundation

/// Number formatting shared by the panel and the CLI. Numbers and units are returned
/// separately because the panel draws units smaller and lighter than their numbers.
public enum Format {
    public struct Quantity: Sendable, Equatable {
        public var number: String
        public var unit: String
        /// One-letter unit for tight layouts.
        public var shortUnit: String

        public var text: String { "\(number) \(unit)" }
        public var shortText: String { "\(number)\(shortUnit)" }
    }

    public static func percent(_ fraction: Double) -> String {
        String(Int((min(max(fraction, 0), 9.99) * 100).rounded()))
    }

    /// Bytes per second as KB/s below 1 MB/s, then MB/s, then GB/s (decimal units).
    public static func rate(_ bytesPerSecond: Double) -> Quantity {
        let value = max(0, bytesPerSecond)
        if value >= 999_500_000 { return Quantity(number: decimal(value / 1_000_000_000), unit: "GB/s", shortUnit: "G") }
        if value >= 999_500 { return Quantity(number: decimal(value / 1_000_000), unit: "MB/s", shortUnit: "M") }
        return Quantity(number: String(Int((value / 1000).rounded())), unit: "KB/s", shortUnit: "K")
    }

    /// Memory in binary gigabytes with one decimal, as Activity Monitor shows it.
    public static func gigabytes(_ bytes: UInt64) -> String {
        decimal(Double(bytes) / 1_073_741_824)
    }

    /// Whole gigabytes when exact, otherwise one decimal: "36", "17.5".
    public static func gigabytesCompact(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        return value == value.rounded() ? String(Int(value)) : decimal(value)
    }

    /// Process memory: "512M" below 1 GB, "4.1G" above.
    public static func processMemory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 1000 { return decimal(megabytes / 1024) + "G" }
        return String(Int(megabytes.rounded())) + "M"
    }

    public static func gigahertz(_ megahertz: Double) -> String {
        String(format: "%.2f", megahertz / 1000)
    }

    public static func degrees(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))°"
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
