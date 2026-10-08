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

/// The group a core is drawn in: the chip's fastest cores, or everything below them.
/// What the cores are called is `CoreTier`; an M5 Pro draws its "Performance" cores in
/// the `efficiency` group, under its "Super" cores.
public enum CoreKind: String, Sendable, Codable {
    case performance, efficiency
}

/// What the system calls a core. `unknown` when it does not say.
public enum CoreTier: String, Sendable, Codable {
    case superCore = "super"
    case performance, efficiency, unknown

    /// One letter for compact lists.
    public var letter: String {
        switch self {
        case .superCore: "S"
        case .performance: "P"
        case .efficiency: "E"
        case .unknown: "C"
        }
    }
}

public struct CoreSample: Sendable, Codable, Equatable, Identifiable {
    public var id: Int
    public var kind: CoreKind
    public var tier: CoreTier
    /// Position within its group, starting at 1.
    public var number: Int
    /// 0...1 share of the last interval the core was busy.
    public var usage: Double
    public var frequencyMHz: Reading<Double>
    public var maxFrequencyMHz: Double?

    /// `tier` nil names the core after its group.
    public init(
        id: Int, kind: CoreKind, tier: CoreTier? = nil, number: Int, usage: Double, frequencyMHz: Reading<Double>, maxFrequencyMHz: Double?
    ) {
        self.id = id
        self.kind = kind
        self.tier = tier ?? (kind == .performance ? .performance : .efficiency)
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
    /// The controller's sensors on the GPU part of the chip.
    case gpu
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

/// The GPU as the system reports it: one figure for all of its cores.
public struct GPUSample: Sendable, Codable, Equatable {
    /// 0...1 share of the last interval the GPU was busy.
    public var usage: Double
    public var frequencyMHz: Reading<Double>
    public var maxFrequencyMHz: Double?
    /// Unified memory the GPU holds. Apple Silicon has no separate video memory.
    public var memoryBytes: Reading<UInt64>
    public var temperature: Reading<Temperature>

    public init(usage: Double, frequencyMHz: Reading<Double>, maxFrequencyMHz: Double?, memoryBytes: Reading<UInt64>, temperature: Reading<Temperature>) {
        self.usage = usage
        self.frequencyMHz = frequencyMHz
        self.maxFrequencyMHz = maxFrequencyMHz
        self.memoryBytes = memoryBytes
        self.temperature = temperature
    }

    /// 0...1 position of the current frequency within the GPU's range.
    public var frequencyFraction: Double? {
        guard let mhz = frequencyMHz.value, let top = maxFrequencyMHz, top > 0 else { return nil }
        return min(1, max(0, mhz / top))
    }
}

public struct PowerSample: Sendable, Codable, Equatable {
    /// What the whole machine draws, in watts.
    public var systemWatts: Double
    /// What the power adapter delivers; zero on battery.
    public var inputWatts: Reading<Double>
    public var gpuWatts: Reading<Double>

    public init(systemWatts: Double, inputWatts: Reading<Double>, gpuWatts: Reading<Double>) {
        self.systemWatts = systemWatts
        self.inputWatts = inputWatts
        self.gpuWatts = gpuWatts
    }
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

/// One process folded into an app's entry.
public struct ProcessMember: Sendable, Codable, Equatable {
    public var name: String
    public var cpuPercent: Double
    public var memoryBytes: UInt64

    public init(name: String, cpuPercent: Double, memoryBytes: UInt64) {
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// What a process list is ranked by.
public enum ProcessSort: String, Sendable, Codable, CaseIterable {
    case cpu, memory
}

/// A row of the process list: one process, or an app with its helper processes folded in.
public struct ProcessSample: Sendable, Codable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    /// Percent of one core; 250 means two and a half cores.
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    /// The outermost app bundle the process runs from; nil outside any app.
    public var appPath: String?
    /// The processes folded into this entry, heaviest first; empty for a single process.
    public var members: [ProcessMember]

    /// Stable while the entry stays in the list: the app, or the process.
    public var id: String { appPath ?? "pid \(pid)" }

    public init(pid: Int32, name: String, cpuPercent: Double, memoryBytes: UInt64, appPath: String? = nil, members: [ProcessMember] = []) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.appPath = appPath
        self.members = members
    }

    /// The app bundle a process at `path` belongs to: a helper inside Chrome's bundle belongs to Chrome.
    public static func appPath(ofExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// `list` with every app's processes folded into one entry that carries their sums
    /// and the app's name, ranked by `sort`. Only what is in `list` is summed.
    public static func folded(_ list: [ProcessSample], by sort: ProcessSort) -> [ProcessSample] {
        var order: [String] = []
        var groups: [String: [ProcessSample]] = [:]
        for sample in list {
            if groups[sample.id] == nil { order.append(sample.id) }
            groups[sample.id, default: []].append(sample)
        }
        func heavier(_ first: (Double, UInt64), _ second: (Double, UInt64)) -> Bool {
            sort == .cpu ? (first.0 != second.0 ? first.0 > second.0 : first.1 > second.1) : first.1 > second.1
        }
        let entries = order.map { key -> ProcessSample in
            let group = groups[key]!.sorted { heavier(($0.cpuPercent, $0.memoryBytes), ($1.cpuPercent, $1.memoryBytes)) }
            guard let path = group[0].appPath, group.count > 1 || group[0].members.isEmpty else { return group[0] }
            let name = String(path.split(separator: "/").last ?? "").replacingOccurrences(of: ".app", with: "")
            return ProcessSample(
                pid: group[0].pid, name: name.isEmpty ? group[0].name : name, cpuPercent: group.reduce(0) { $0 + $1.cpuPercent },
                memoryBytes: group.reduce(0) { $0 + $1.memoryBytes }, appPath: path,
                members: group.count > 1 ? group.map { ProcessMember(name: $0.name, cpuPercent: $0.cpuPercent, memoryBytes: $0.memoryBytes) } : [])
        }
        return entries.sorted { heavier(($0.cpuPercent, $0.memoryBytes), ($1.cpuPercent, $1.memoryBytes)) }
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
    public var gpu: Reading<GPUSample>
    public var power: Reading<PowerSample>

    public init(
        time: Date, cpu: Reading<CPUSample>, memory: Reading<MemorySample>, network: Reading<NetworkSample>, processes: Reading<ProcessList>,
        gpu: Reading<GPUSample>, power: Reading<PowerSample>
    ) {
        self.time = time
        self.cpu = cpu
        self.memory = memory
        self.network = network
        self.processes = processes
        self.gpu = gpu
        self.power = power
    }

    /// The same readings with every module outside `modules` marked as turned off. The
    /// menu bar may need a module the panel does not show.
    public func limited(to modules: [ModuleID]) -> Snapshot {
        let off = "module is turned off"
        var copy = self
        if !modules.contains(.cpu) { copy.cpu = .unavailable(off) }
        if !modules.contains(.memory) { copy.memory = .unavailable(off) }
        if !modules.contains(.network) { copy.network = .unavailable(off) }
        if !modules.contains(.processes) { copy.processes = .unavailable(off) }
        if !modules.contains(.gpu) { copy.gpu = .unavailable(off) }
        if !modules.contains(.power) { copy.power = .unavailable(off) }
        return copy
    }
}

extension Snapshot {
    /// Fixed sample data with the widest digits each field can show. Used to measure
    /// layouts and in previews and tests; never shown as a real reading.
    /// Where the sample's apps live on a Mac, so pictures drawn from the sample show their icons.
    private static let samplePaths: [String: String] = [
        "Xcode": "/Applications/Xcode.app", "Google Chrome": "/Applications/Google Chrome.app", "Figma": "/Applications/Figma.app",
        "iTerm2": "/Applications/iTerm.app", "Safari": "/Applications/Safari.app", "Slack": "/Applications/Slack.app",
        "Music": "/System/Applications/Music.app", "Finder": "/System/Library/CoreServices/Finder.app", "Notes": "/System/Applications/Notes.app",
        "Mail": "/System/Applications/Mail.app", "Terminal": "/System/Applications/Utilities/Terminal.app",
        "Activity Monitor": "/System/Applications/Utilities/Activity Monitor.app", "Preview": "/System/Applications/Preview.app",
        "Calendar": "/System/Applications/Calendar.app", "Photos": "/System/Applications/Photos.app", "TextEdit": "/System/Applications/TextEdit.app",
        "Docker": "/Applications/Docker.app", "Messages": "/System/Applications/Messages.app", "Maps": "/System/Applications/Maps.app",
        "Reminders": "/System/Applications/Reminders.app",
    ]

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
            "Xcode", "Google Chrome", "WindowServer", "Figma", "iTerm2", "Safari",
            "kernel_task", "Slack", "mds_stores", "Music", "Finder", "Notes", "Mail", "Terminal", "Spotlight", "Dock",
            "Activity Monitor", "coreaudiod", "launchd", "Preview", "Calendar", "bluetoothd", "Photos", "TextEdit",
            "ollama", "node", "Docker", "python3", "Messages", "cloudd", "Maps", "Reminders",
        ]
        let list = (0..<processes).map { index -> ProcessSample in
            let name = names[index % names.count]
            return ProcessSample(
                pid: Int32(100 + index), name: name,
                cpuPercent: max(1, 188.8 / Double(index + 1)), memoryBytes: UInt64(Double(8_800_000_000) / Double((index * 7) % 11 + 1)),
                appPath: samplePaths[name])
        }
        let byMemory = ProcessSample.folded(list, by: .memory)
        let gigabyte: UInt64 = 1_073_741_824
        return Snapshot(
            time: Date(timeIntervalSince1970: 0),
            cpu: .value(CPUSample(cores: cores, temperature: .value(Temperature(celsius: 58, source: .chipDie, sensorCount: 8)))),
            memory: .value(
                MemorySample(
                    total: 36 * gigabyte, used: 21 * gigabyte + gigabyte / 2, compressed: 3 * gigabyte,
                    swapUsed: gigabyte * 8 / 10, swapTotal: 2 * gigabyte, pressure: .value(.normal))),
            network: .value(NetworkSample(downBytesPerSecond: 2_400_000, upBytesPerSecond: 188_000)),
            processes: .value(ProcessList(top: ProcessSample.folded(list, by: .cpu), byMemory: byMemory, coversAllUsers: true)),
            gpu: .value(
                GPUSample(
                    usage: 0.37, frequencyMHz: .value(620), maxFrequencyMHz: 1578, memoryBytes: .value(gigabyte * 14 / 10),
                    temperature: .value(Temperature(celsius: 56, source: .gpu, sensorCount: 22)))),
            power: .value(PowerSample(systemWatts: 18.6, inputWatts: .value(19.9), gpuWatts: .value(3.1)))
        )
    }
}
