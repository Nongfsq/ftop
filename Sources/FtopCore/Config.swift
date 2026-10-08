import Foundation

public enum ModuleID: String, Sendable, Codable, CaseIterable {
    case cpu, memory, network, processes, gpu, power

    /// Modules with a block of their own, stacked in the order the user lists them.
    public static let stacked: [ModuleID] = [.cpu, .memory, .network, .processes]
    /// Readings placed into the blocks of the stacked modules. A new one shows for
    /// everyone until it is listed under `hidden`.
    public static let added: [ModuleID] = [.gpu, .power]
}

public enum PaletteID: String, Sendable, Codable, CaseIterable {
    case sea, graphite, warm
}

/// The one reading the menu bar shows.
public enum MenuBarMetric: String, Sendable, Codable, CaseIterable {
    case cpu, memory, gpu, download, upload, power

    /// The module that has to be read for it, whether or not the panel shows that module.
    public var module: ModuleID {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .gpu: .gpu
        case .download, .upload: .network
        case .power: .power
        }
    }

    /// The figure as the menu bar writes it, the unit in `shortUnit`; nil when the machine does not report it.
    public func figure(in snapshot: Snapshot) -> Format.Quantity? {
        switch self {
        case .cpu: snapshot.cpu.value.map { Format.share($0.usage) }
        case .memory: snapshot.memory.value.map { Format.share($0.usedFraction) }
        case .gpu: snapshot.gpu.value.map { Format.share($0.usage) }
        case .download: snapshot.network.value.map { Format.compactRate($0.downBytesPerSecond) }
        case .upload: snapshot.network.value.map { Format.compactRate($0.upBytesPerSecond) }
        case .power: snapshot.power.value.map { Format.compactWatts($0.systemWatts) }
        }
    }
}

public enum Language: String, Sendable, Codable {
    case auto, en, zh
}

/// User-owned settings, read from `~/.config/ftop/config.json5`. Every field is
/// optional in the file; a missing or out-of-range value falls back to its default.
public struct Config: Sendable, Codable, Equatable {
    /// Stacked modules to show, in order.
    public var modules: [ModuleID] = ModuleID.stacked
    /// Added readings the user turned off.
    public var hidden: [ModuleID] = []
    public var palette: PaletteID = .sea
    /// Language of the few labels: follow the system, or force one.
    public var language: Language = .auto
    /// Seconds between samples.
    public var interval: Double = 1
    /// Columns ease to each new value.
    public var motion: Bool = true
    /// Most process rows a large window may show.
    public var maxProcesses: Int = 24
    /// What the process list is ranked by.
    public var processSort: ProcessSort = .cpu
    /// Keep the panel above other windows.
    public var floating: Bool = false
    /// Show one reading in the menu bar; clicking it shows or hides the panel.
    public var menuBar: Bool = true
    /// Which reading that is.
    public var menuBarShows: MenuBarMetric = .cpu
    /// New releases: install them, only offer them, or never look.
    public var updates: UpdateMode = .install

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        modules = try container.decodeIfPresent([ModuleID].self, forKey: .modules) ?? defaults.modules
        hidden = try container.decodeIfPresent([ModuleID].self, forKey: .hidden) ?? defaults.hidden
        palette = try container.decodeIfPresent(PaletteID.self, forKey: .palette) ?? defaults.palette
        language = try container.decodeIfPresent(Language.self, forKey: .language) ?? defaults.language
        interval = try container.decodeIfPresent(Double.self, forKey: .interval) ?? defaults.interval
        motion = try container.decodeIfPresent(Bool.self, forKey: .motion) ?? defaults.motion
        maxProcesses = try container.decodeIfPresent(Int.self, forKey: .maxProcesses) ?? defaults.maxProcesses
        processSort = try container.decodeIfPresent(ProcessSort.self, forKey: .processSort) ?? defaults.processSort
        floating = try container.decodeIfPresent(Bool.self, forKey: .floating) ?? defaults.floating
        menuBar = try container.decodeIfPresent(Bool.self, forKey: .menuBar) ?? defaults.menuBar
        menuBarShows = try container.decodeIfPresent(MenuBarMetric.self, forKey: .menuBarShows) ?? defaults.menuBarShows
        updates = try container.decodeIfPresent(UpdateMode.self, forKey: .updates) ?? defaults.updates
        normalize()
    }

    /// Clamps values to the ranges the panel supports and drops duplicate modules.
    public mutating func normalize() {
        interval = min(10, max(0.5, interval))
        maxProcesses = min(24, max(3, maxProcesses))
        var seen = Set<ModuleID>()
        modules = modules.filter { ModuleID.stacked.contains($0) && seen.insert($0).inserted }
        if modules.isEmpty { modules = [.cpu] }
        hidden = ModuleID.added.filter(hidden.contains)
    }

    /// Everything the panel shows: the stacked modules in the user's order, then the added readings.
    public var shown: [ModuleID] {
        modules + ModuleID.added.filter { !hidden.contains($0) }
    }

    /// Modules a user can turn off, in the order the settings list them. CPU is always shown.
    public static let optional: [ModuleID] = [.memory, .network, .gpu, .power, .processes]

    /// Shows or hides one module and returns the `key: value` line of the settings file that changed.
    public mutating func setShown(_ module: ModuleID, _ on: Bool) -> (key: String, value: String) {
        func list(_ items: [ModuleID]) -> String { "[" + items.map { "\"\($0.rawValue)\"" }.joined(separator: ", ") + "]" }
        if ModuleID.added.contains(module) {
            hidden = ModuleID.added.filter { $0 == module ? !on : hidden.contains($0) }
            return ("hidden", list(hidden))
        }
        var kept = Set(modules)
        if on { kept.insert(module) } else { kept.remove(module) }
        kept.insert(.cpu)
        // Keep the order the user wrote in the file; a module switched back on goes last.
        var ordered = modules.filter(kept.contains)
        ordered += ModuleID.stacked.filter { kept.contains($0) && !ordered.contains($0) }
        modules = ordered
        return ("modules", list(modules))
    }

    public static func decode(_ data: Data) throws -> Config {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        return try decoder.decode(Config.self, from: data)
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/ftop/config.json5")
    }

    /// The commented file written on first launch.
    public static let template = """
        // ftop settings. Changes apply as soon as the file is saved.
        {
          // Modules to show, top to bottom: "cpu", "memory", "network", "processes".
          modules: ["cpu", "memory", "network", "processes"],

          // Readings to leave out: "gpu" (the GPU's ring and its figures), "power" (the whole machine's watts).
          hidden: [],

          // Colors: "sea", "graphite", or "warm".
          palette: "sea",

          // Language of the labels: "auto" follows the system, or "zh" / "en".
          language: "auto",

          // Seconds between updates (0.5 to 10).
          interval: 1,

          // Columns glide to each new value instead of jumping. The system draws the glide, so
          // it costs ftop itself nothing. Always off in Low Power Mode and when macOS
          // "Reduce motion" is on.
          motion: true,

          // Most process rows a large window may show (3 to 24).
          maxProcesses: 24,

          // What the process list is ranked by: "cpu" or "memory". The two badges above
          // the list in a large window switch it.
          processSort: "cpu",

          // Keep the panel above other windows (the pin button does the same).
          floating: false,

          // Show one reading in the menu bar; click it to show or hide the panel.
          menuBar: true,

          // Which reading: "cpu", "memory", "gpu", "download", "upload", or "power". It does
          // not have to be one the panel shows.
          menuBarShows: "cpu",

          // New versions: "install" looks once a day and installs what it finds, "check"
          // only offers it in the right-click menu, "off" never goes online.
          updates: "install",
        }

        """
}
