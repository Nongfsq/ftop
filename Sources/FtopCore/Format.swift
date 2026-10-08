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

    /// A share as whole percent, for the menu bar: "18" and "%".
    public static func share(_ fraction: Double) -> Quantity {
        Quantity(number: percent(min(max(fraction, 0), 1)), unit: "%", shortUnit: "%")
    }

    /// A rate in at most four characters and one letter, for the menu bar: "84" K, "1.2" M, "120" M.
    public static func compactRate(_ bytesPerSecond: Double) -> Quantity {
        let value = max(0, bytesPerSecond)
        if value >= 999_500_000 { return Quantity(number: compact(value / 1_000_000_000), unit: "GB/s", shortUnit: "G") }
        if value >= 999_500 { return Quantity(number: compact(value / 1_000_000), unit: "MB/s", shortUnit: "M") }
        return Quantity(number: String(Int((value / 1000).rounded())), unit: "KB/s", shortUnit: "K")
    }

    /// Watts for the menu bar: "18.6" W, "120" W.
    public static func compactWatts(_ watts: Double) -> Quantity {
        Quantity(number: compact(max(0, watts)), unit: "W", shortUnit: "W")
    }

    /// One decimal below 100, none from there on.
    private static func compact(_ value: Double) -> String {
        value < 99.95 ? decimal(value) : String(Int(value.rounded()))
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

    /// Watts with one decimal, for detail: "18.6".
    public static func watts(_ watts: Double) -> String {
        decimal(max(0, watts))
    }

    /// Whole watts, for the one figure beside the temperature: "19".
    public static func wattsRounded(_ watts: Double) -> String {
        String(Int(max(0, watts).rounded()))
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
