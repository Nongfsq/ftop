import AppKit
import FtopCore

/// A type size and weight. The font itself is created once and cached.
public struct FontSpec: Hashable, Sendable {
    public var size: Double
    public var weight: Double

    init(_ size: Double, _ weight: NSFont.Weight = .regular) {
        // Tenths of a point are enough and keep the caches small while the scale changes.
        self.size = (size * 10).rounded() / 10
        self.weight = Double(weight.rawValue)
    }
}

/// A color by role, resolved for the current appearance and palette when drawn.
public enum Paint: Hashable, Sendable {
    case ink, secondary, track, performance, efficiency, normal, warning, critical
    /// Compressed memory: the pressure color, lighter.
    indirect case faded(Paint)
}

/// Every color, type size, and spacing the panel uses is defined here and nowhere else.
/// Sizes are in points at scale 1; layouts multiply them by `PanelStyle.scale`.
public struct PanelStyle: Equatable, Sendable {
    public var scale: Double = 1
    public var palette: PaletteID = .sea
    /// Columns ease to each new value.
    public var motion: Bool = true
    /// Seconds between samples.
    public var interval: Double = 1

    public init(scale: Double = 1, palette: PaletteID = .sea, motion: Bool = true, interval: Double = 1) {
        self.scale = scale
        self.palette = palette
        self.motion = motion
        self.interval = interval
    }

    func points(_ value: Double) -> CGFloat { CGFloat(value * scale) }

    func font(_ size: Double, _ weight: NSFont.Weight = .regular) -> FontSpec {
        FontSpec(size * scale, weight)
    }

    // Type scale: one display size, one emphasis size, body, caption.
    var display: FontSpec { font(28, .semibold) }
    var displayUnit: FontSpec { font(13, .medium) }
    var cornerDisplay: FontSpec { font(21, .semibold) }
    var cornerUnit: FontSpec { font(11, .medium) }
    var emphasis: FontSpec { font(17, .semibold) }
    var body: FontSpec { font(12) }
    var bodyStrong: FontSpec { font(12, .semibold) }
    var caption: FontSpec { font(10.5) }
    var captionStrong: FontSpec { font(10.5, .semibold) }
    var coreNumber: FontSpec { font(10, .semibold) }
    var tiny: FontSpec { font(8.5) }

    // Spacing.
    var paddingX: CGFloat { points(15) }
    var paddingY: CGFloat { points(13) }
    var moduleGap: CGFloat { points(15) }
    var columnGap: CGFloat { points(22) }
    var rowGap: CGFloat { points(7) }
    var innerGap: CGFloat { points(8) }
    /// Narrowest right-hand column that holds swap, upload, and the process numbers.
    var sideColumn: CGFloat { points(78) }
    var processCPUWidth: CGFloat { points(34) }
    var processMemoryWidth: CGFloat { points(36) }
    var processNameWidth: CGFloat { points(92) }
    /// Process names get more room when the list has a column to itself.
    var processNameWideWidth: CGFloat { points(124) }

    // Core columns.
    var coreGap: CGFloat { points(4) }
    var coreGroupGap: CGFloat { points(6) }
    var coreSlimWidth: CGFloat { points(5) }
    var coreNumberedWidth: CGFloat { points(25) }
    var miniCoreWidth: CGFloat { points(3) }
    var miniCoreGap: CGFloat { points(1.5) }
    var miniCoreGroupGap: CGFloat { points(2) }

    static let inkColor = nsDynamic(light: 0x111827, dark: 0xF3F4F6)
    static let secondaryColor = nsDynamic(light: 0x111827, dark: 0xF3F4F6, lightAlpha: 0.66, darkAlpha: 0.66)
    static let trackColor = nsDynamic(light: 0x111827, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.13)
    static let normalColor = nsDynamic(light: 0x1C9A50, dark: 0x4FD17F)
    static let warningColor = nsDynamic(light: 0xB26A00, dark: 0xF0B54A)
    static let criticalColor = nsDynamic(light: 0xD23F31, dark: 0xFF6B5E)
    static let chipColor = nsDynamic(light: 0x111827, dark: 0xF3F4F6)
    static let chipTextColor = nsDynamic(light: 0xFFFFFF, dark: 0x14161B)
    /// Behind the pin and hide buttons, so they read over whatever is under them.
    static let controlColor = nsDynamic(light: 0xFFFFFF, dark: 0x2A2D34, lightAlpha: 0.94, darkAlpha: 0.94)

    var performanceColor: NSColor { Self.nsDynamic(light: palette.colors.pLight, dark: palette.colors.pDark) }
    var efficiencyColor: NSColor { Self.nsDynamic(light: palette.colors.eLight, dark: palette.colors.eDark) }

    func color(_ paint: Paint) -> NSColor {
        switch paint {
        case .ink: Self.inkColor
        case .secondary: Self.secondaryColor
        case .track: Self.trackColor
        case .performance: performanceColor
        case .efficiency: efficiencyColor
        case .normal: Self.normalColor
        case .warning: Self.warningColor
        case .critical: Self.criticalColor
        case .faded(let base): color(base).withAlphaComponent(0.45)
        }
    }

    static func pressurePaint(_ level: PressureLevel?) -> Paint {
        switch level {
        case .normal: .normal
        case .warning: .warning
        case .critical: .critical
        case nil: .secondary
        }
    }

    static func nsDynamic(light: Int, dark: Int, lightAlpha: Double = 1, darkAlpha: Double = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
}

extension PaletteID {
    /// Core colors as (performance, efficiency) for light and dark appearance.
    var colors: (pLight: Int, eLight: Int, pDark: Int, eDark: Int) {
        switch self {
        case .sea: (0x1F5FE0, 0x0B8F7E, 0x5B9BFF, 0x45D1BD)
        case .graphite: (0x1F2937, 0x6B7280, 0xF3F4F6, 0x9AA1AD)
        case .warm: (0xDC4A2B, 0xB9770A, 0xFF8468, 0xFFC857)
        }
    }

    @MainActor public var displayName: String {
        switch self {
        case .sea: Strings.pick("Sea", "海")
        case .graphite: Strings.pick("Graphite", "石墨")
        case .warm: Strings.pick("Warm", "暖")
        }
    }
}

/// The few words the panel shows, in English and Simplified Chinese.
@MainActor
public enum Strings {
    /// Set from the settings file; `.auto` follows the system language.
    public static var language: Language = .auto

    static var chinese: Bool {
        switch language {
        case .zh: true
        case .en: false
        case .auto: Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }

    public static func pick(_ english: String, _ chinese: String) -> String {
        Self.chinese ? chinese : english
    }

    static var compressed: String { pick("Compressed", "压缩") }
    static var swap: String { pick("Swap", "交换") }

    static func pressure(_ level: PressureLevel) -> String {
        switch level {
        case .normal: pick("Normal", "正常")
        case .warning: pick("Elevated", "偏高")
        case .critical: pick("Critical", "紧张")
        }
    }

    /// Every pressure word, so a layout can reserve room for the widest.
    static var pressureWords: [String] { [PressureLevel.normal, .warning, .critical].map(pressure) }

    static func core(_ core: CoreSample) -> String {
        let kind =
            switch core.tier {
            case .superCore: pick("Super core", "超级核")
            case .performance: pick("Performance core", "性能核")
            case .efficiency: pick("Efficiency core", "能效核")
            case .unknown: pick("Core", "核心")
            }
        let frequency = core.frequencyMHz.value.map { " · \(Format.gigahertz($0)) GHz" } ?? " · " + pick("frequency unavailable", "频率不可用")
        return "\(kind) \(core.number) · \(Format.percent(core.usage))%\(frequency)"
    }

    static func temperature(_ temperature: Temperature) -> String {
        let source = temperature.source == .cpuCluster ? pick("CPU cluster sensors", "处理器簇传感器") : pick("chip die sensors", "芯片传感器")
        return pick("Temperature", "温度") + " \(Format.degrees(temperature.celsius)) · \(temperature.sensorCount) \(source)"
    }
}
