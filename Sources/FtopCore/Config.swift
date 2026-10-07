import Foundation

public enum ModuleID: String, Sendable, Codable, CaseIterable {
    case cpu, memory, network, processes
}

public enum PaletteID: String, Sendable, Codable, CaseIterable {
    case sea, graphite, warm
}

public enum Language: String, Sendable, Codable {
    case auto, en, zh
}

/// User-owned settings, read from `~/.config/ftop/config.json5`. Every field is
/// optional in the file; a missing or out-of-range value falls back to its default.
public struct Config: Sendable, Codable, Equatable {
    /// Modules to show, in order.
    public var modules: [ModuleID] = ModuleID.allCases
    public var palette: PaletteID = .sea
    /// Language of the few labels: follow the system, or force one.
    public var language: Language = .auto
    /// Seconds between samples.
    public var interval: Double = 1
    /// Columns ease to each new value.
    public var motion: Bool = true
    /// Most process rows a large window may show.
    public var maxProcesses: Int = 24
    /// Keep the panel above other windows.
    public var floating: Bool = false
    /// Show the CPU percentage in the menu bar; clicking it shows or hides the panel.
    public var menuBar: Bool = true
    /// New releases: install them, only offer them, or never look.
    public var updates: UpdateMode = .install

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        modules = try container.decodeIfPresent([ModuleID].self, forKey: .modules) ?? defaults.modules
        palette = try container.decodeIfPresent(PaletteID.self, forKey: .palette) ?? defaults.palette
        language = try container.decodeIfPresent(Language.self, forKey: .language) ?? defaults.language
        interval = try container.decodeIfPresent(Double.self, forKey: .interval) ?? defaults.interval
        motion = try container.decodeIfPresent(Bool.self, forKey: .motion) ?? defaults.motion
        maxProcesses = try container.decodeIfPresent(Int.self, forKey: .maxProcesses) ?? defaults.maxProcesses
        floating = try container.decodeIfPresent(Bool.self, forKey: .floating) ?? defaults.floating
        menuBar = try container.decodeIfPresent(Bool.self, forKey: .menuBar) ?? defaults.menuBar
        updates = try container.decodeIfPresent(UpdateMode.self, forKey: .updates) ?? defaults.updates
        normalize()
    }

    /// Clamps values to the ranges the panel supports and drops duplicate modules.
    public mutating func normalize() {
        interval = min(10, max(0.5, interval))
        maxProcesses = min(24, max(3, maxProcesses))
        var seen = Set<ModuleID>()
        modules = modules.filter { seen.insert($0).inserted }
        if modules.isEmpty { modules = [.cpu] }
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

          // Keep the panel above other windows (the pin button does the same).
          floating: false,

          // Show the CPU percentage in the menu bar; click it to show or hide the panel.
          menuBar: true,

          // New versions: "install" looks once a day and installs what it finds, "check"
          // only offers it in the right-click menu, "off" never goes online.
          updates: "install",
        }

        """
}
