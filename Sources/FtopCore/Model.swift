import Foundation

/// A sensor value that is either known or explicitly unavailable. ftop never shows
/// a fabricated zero for something the hardware did not report.
public enum Reading<Value: Sendable & Codable & Equatable>: Sendable, Codable, Equatable {
    case value(Value)
    case unavailable(String)

    public var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }

    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

public enum CoreKind: String, Sendable, Codable {
    case performance, efficiency
}

public struct CoreSample: Sendable, Codable, Equatable, Identifiable {
    public var id: Int
    public var kind: CoreKind
    /// Position within its group, starting at 1.
    public var number: Int
    /// 0...1 share of the last interval the core was busy.
    public var usage: Double
    public var frequencyMHz: Reading<Double>
    public var maxFrequencyMHz: Double?

    public init(id: Int, kind: CoreKind, number: Int, usage: Double, frequencyMHz: Reading<Double>, maxFrequencyMHz: Double?) {
        self.id = id
        self.kind = kind
        self.number = number
        self.usage = usage
        self.frequencyMHz = frequencyMHz
        self.maxFrequencyMHz = maxFrequencyMHz
    }

    /// 0...1 position of the current frequency within the cluster's range.
    public var frequencyFraction: Double? {
        guard let mhz = frequencyMHz.value, let top = maxFrequencyMHz, top > 0 else { return nil }
        return min(1, max(0, mhz / top))
    }
}

public enum TemperatureSource: String, Sendable, Codable {
    /// Sensors placed on the CPU clusters.
    case cpuCluster
    /// Power-management die sensors: the chip as a whole, not individual cores.
    case chipDie
}

public struct Temperature: Sendable, Codable, Equatable {
    public var celsius: Double
    public var source: TemperatureSource
    public var sensorCount: Int

    public init(celsius: Double, source: TemperatureSource, sensorCount: Int) {
        self.celsius = celsius
        self.source = source
        self.sensorCount = sensorCount
    }
}

public struct CPUSample: Sendable, Codable, Equatable {
    public var cores: [CoreSample]
    public var temperature: Reading<Temperature>

    public init(cores: [CoreSample], temperature: Reading<Temperature>) {
        self.cores = cores
        self.temperature = temperature
    }

    public var usage: Double {
        cores.isEmpty ? 0 : cores.reduce(0) { $0 + $1.usage } / Double(cores.count)
    }

    public var performance: [CoreSample] { cores.filter { $0.kind == .performance } }
    public var efficiency: [CoreSample] { cores.filter { $0.kind == .efficiency } }
}

public enum PressureLevel: Int, Sendable, Codable {
    case normal = 1, warning = 2, critical = 4
}

public struct MemorySample: Sendable, Codable, Equatable {
    public var total: UInt64
    /// App memory + wired + compressed, the figure Activity Monitor calls "Memory Used".
    public var used: UInt64
    public var compressed: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: Reading<PressureLevel>

    public init(total: UInt64, used: UInt64, compressed: UInt64, swapUsed: UInt64, swapTotal: UInt64, pressure: Reading<PressureLevel>) {
        self.total = total
        self.used = used
        self.compressed = compressed
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    public var compressedFraction: Double { total > 0 ? Double(compressed) / Double(total) : 0 }
    public var appFraction: Double { max(0, usedFraction - compressedFraction) }
    /// Swap in use relative to what the system has allocated, or to 4 GB when nothing is allocated yet.
    public var swapFraction: Double {
        let scale = max(Double(swapTotal), 4 * 1_073_741_824)
        return min(1, Double(swapUsed) / scale)
    }
}

public struct NetworkSample: Sendable, Codable, Equatable {
    public var downBytesPerSecond: Double
    public var upBytesPerSecond: Double

    public init(downBytesPerSecond: Double, upBytesPerSecond: Double) {
        self.downBytesPerSecond = downBytesPerSecond
        self.upBytesPerSecond = upBytesPerSecond
    }
}

public struct ProcessSample: Sendable, Codable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    /// Percent of one core; 250 means two and a half cores.
    public var cpuPercent: Double
    public var memoryBytes: UInt64

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpuPercent: Double, memoryBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

public struct ProcessList: Sendable, Codable, Equatable {
    /// Sorted by CPU, highest first.
    public var top: [ProcessSample]
    /// Sorted by memory, highest first. Empty when the helper cannot provide it.
    public var byMemory: [ProcessSample]
    /// False when processes owned by other users could not be read.
    public var coversAllUsers: Bool
    /// True when the installed privileged helper predates this version: it costs more
    /// CPU or lacks the memory ranking; `sudo ftop grant` replaces it.
    public var helperOutdated: Bool

    public init(top: [ProcessSample], byMemory: [ProcessSample] = [], coversAllUsers: Bool, helperOutdated: Bool = false) {
        self.top = top
        self.byMemory = byMemory
        self.coversAllUsers = coversAllUsers
        self.helperOutdated = helperOutdated
    }
}

public struct Snapshot: Sendable, Codable, Equatable {
    public var time: Date
    public var cpu: Reading<CPUSample>
    public var memory: Reading<MemorySample>
    public var network: Reading<NetworkSample>
    public var processes: Reading<ProcessList>

    public init(time: Date, cpu: Reading<CPUSample>, memory: Reading<MemorySample>, network: Reading<NetworkSample>, processes: Reading<ProcessList>) {
        self.time = time
        self.cpu = cpu
        self.memory = memory
        self.network = network
        self.processes = processes
    }
}

extension Snapshot {
    /// Fixed sample data with the widest digits each field can show. Used to measure
    /// layouts and in previews and tests; never shown as a real reading.
    public static func sample(performance: Int = 8, efficiency: Int = 4, processes: Int = 32) -> Snapshot {
        var cores: [CoreSample] = []
        let pUsage = [0.47, 0.28, 0.64, 0.57, 0.68, 0.59, 0.57, 0.38, 0.44, 0.61, 0.33, 0.52, 0.48, 0.66, 0.41, 0.58]
        let eUsage = [0.16, 0.19, 0.39, 0.17, 0.22, 0.31, 0.14, 0.27]
        for index in 0..<performance {
            let usage = pUsage[index % pUsage.count]
            cores.append(
                CoreSample(
                    id: index, kind: .performance, number: index + 1, usage: usage,
                    frequencyMHz: .value(1000 + usage * 3000), maxFrequencyMHz: 4400))
        }
        for index in 0..<efficiency {
            let usage = eUsage[index % eUsage.count]
            cores.append(
                CoreSample(
                    id: performance + index, kind: .efficiency, number: index + 1, usage: usage,
                    frequencyMHz: .value(900 + usage * 2000), maxFrequencyMHz: 2600))
        }
        let names = [
            "Xcode", "Google Chrome Helper (Renderer)", "WindowServer", "Figma", "iTerm2", "Safari",
            "kernel_task", "Slack", "mds_stores", "Music", "Finder", "Notes", "Mail", "Terminal", "Spotlight", "Dock",
            "Activity Monitor", "coreaudiod", "launchd", "Preview", "Calendar", "bluetoothd", "Photos", "TextEdit",
            "ollama", "node", "Docker", "python3", "Messages", "cloudd", "Maps", "Reminders",
        ]
        let list = (0..<processes).map { index in
            ProcessSample(
                pid: Int32(100 + index), name: names[index % names.count],
                cpuPercent: max(1, 188.8 / Double(index + 1)), memoryBytes: UInt64(Double(8_800_000_000) / Double((index * 7) % 11 + 1)))
        }
        let byMemory = list.sorted { $0.memoryBytes > $1.memoryBytes }
        let gigabyte: UInt64 = 1_073_741_824
        return Snapshot(
            time: Date(timeIntervalSince1970: 0),
            cpu: .value(CPUSample(cores: cores, temperature: .value(Temperature(celsius: 58, source: .chipDie, sensorCount: 8)))),
            memory: .value(
                MemorySample(
                    total: 36 * gigabyte, used: 21 * gigabyte + gigabyte / 2, compressed: 3 * gigabyte,
                    swapUsed: gigabyte * 8 / 10, swapTotal: 2 * gigabyte, pressure: .value(.normal))),
            network: .value(NetworkSample(downBytesPerSecond: 2_400_000, upBytesPerSecond: 188_000)),
            processes: .value(ProcessList(top: list, byMemory: byMemory, coversAllUsers: true))
        )
    }
}
