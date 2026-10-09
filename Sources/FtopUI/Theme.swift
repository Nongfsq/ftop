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
    case ink, secondary, track, badge, performance, efficiency, gpu, normal, warning, critical
    /// Core group `group` of `of` groups, fastest first.
    case core(group: Int, of: Int)
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

    // Type scale: one emphasis size for the figures that head a block, body, caption.
    // A row holds one size of figure, whatever the window size.
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

    /// Between two rows of the process list.
    var processRowGap: CGFloat { points(8) }

    // Core columns.
    var coreGap: CGFloat { points(4) }
    var coreGroupGap: CGFloat { points(6) }
    /// Between the core columns and the GPU's column: more than between two kinds of core, since it is another part.
    var gpuColumnGap: CGFloat { points(14) }
    var coreSlimWidth: CGFloat { points(5) }
    var coreNumberedWidth: CGFloat { points(25) }
    var miniCoreWidth: CGFloat { points(3) }
    var miniCoreGap: CGFloat { points(1.5) }
    var miniCoreGroupGap: CGFloat { points(2) }
    /// The GPU's column among mini columns: three of them wide, so it reads as another part.
    var miniGPUWidth: CGFloat { points(9) }
    /// Between the mini core columns and the GPU's mini column when they share one area.
    var miniGPUGap: CGFloat { points(5.5) }
    /// Columns are capsules up to this corner radius; wider ones keep it instead of becoming half circles.
    var coreRadiusLimit: CGFloat { points(8) }
    /// An idle core still shows a dot this tall.
    var coreRestHeight: CGFloat { points(4) }
    var coreTickHeight: CGFloat { max(1, points(1.5)) }
    /// The frequency line stops short of the column's sides by this share of its width.
    static let coreTickInset: CGFloat = 0.2

    // Core column motion. A column follows each reading along a curve that starts and ends
    // without a jolt and is still moving when the next reading lands, so the row flows
    // instead of stopping and restarting once a sample.
    /// How fast a column closes on a reading, in time constants per sample interval.
    static let columnFollowRate: Double = 4.5
    /// Intervals longer than this do not slow the columns further.
    static let columnFollowLongestInterval: Double = 1.5
    /// Each column starts this much after the one to its left, so the row reads as one wave.
    static let columnStagger: Double = 0.018

    // Badges: the round mark in front of a figure. One size at every window size and in
    // every row; only the type beside it changes.
    var badge: CGFloat { points(20) }
    /// The longer side of every glyph, drawn or from the system, so none looks larger than another.
    var badgeGlyph: CGFloat { points(10.5) }
    var badgeRing: CGFloat { points(2.2) }
    /// Between a badge and its figure.
    var badgeGap: CGFloat { points(6) }
    /// Between a badge and a headline figure.
    var badgeLeadGap: CGFloat { points(8) }
    /// How far a row turning over in place travels on its way out and on its way in.
    var rowTurnShift: CGFloat { points(6) }
    /// An app's icon fills this share of its badge, inside the arc.
    static let badgeIconShare: CGFloat = 0.68

    // The menu bar item: a glyph and its figure, in the system's own typeface so it sits with its neighbors.
    /// The longer side of the glyph. At 12 the drawn glyphs' grid is one point a unit.
    static let menuBarGlyph: CGFloat = 12
    /// From the glyph's ink to the figure.
    static let menuBarGap: CGFloat = 3.5
    static let menuBarPadding: CGFloat = 7
    static let menuBarNumberSize: CGFloat = 12
    static let menuBarUnitSize: CGFloat = 10
    static let menuBarUnitGap: CGFloat = 0.5
    static let menuBarUnitOpacity: CGFloat = 0.62

    // The control block: the settings as round switches.
    static let controlDisc: CGFloat = 30
    static let controlGlyph: CGFloat = 15
    /// From one disc's left edge to the next one's.
    static let controlPitchX: CGFloat = 54
    /// From one row of discs to the next.
    static let controlRowPitch: CGFloat = 66
    static let controlPadding: CGFloat = 22
    static let controlLabelGap: CGFloat = 6
    static let controlLabelHeight: CGFloat = 14
    static let controlLabelSize: CGFloat = 10.5
    /// A row of the list "More" opens, and the space above the list.
    static let controlListRow: CGFloat = 34
    static let controlListGap: CGFloat = 10
    static let controlTitleSize: CGFloat = 13
    static let controlValueSize: CGFloat = 12
    static let controlCorner: CGFloat = 18
    /// The ring around the chosen palette.
    static let controlRingLine: CGFloat = 2
    static let controlRingGap: CGFloat = 2
    /// A disc under a press shrinks to this.
    static let controlPressScale: CGFloat = 0.9
    /// Turning a switch on: color spreads from the center, passes full size once and settles.
    static let controlSpringStiffness: CGFloat = 380
    static let controlSpringDamping: CGFloat = 22
    /// Color changes, and a switch turning off.
    static let controlTint: Double = 0.18
    static let controlRingSlide: Double = 0.26
    static let controlAppear: Double = 0.14
    static let controlLeave: Double = 0.1
    /// The glyph of a reading this machine does not give.
    static let controlDimOpacity: Float = 0.35

    // Process rows: how they move.
    /// A row under a press shrinks to this and springs back when let go.
    static let rowPressScale: CGFloat = 0.97
    static let rowPressDown: Double = 0.09
    static let rowSpringStiffness: CGFloat = 320
    static let rowSpringDamping: CGFloat = 22
    /// A row trading places with its neighbor: settles in about a third of a second without passing its place.
    static let rowSlideStiffness: CGFloat = 320
    static let rowSlideDamping: CGFloat = 36
    /// A row turning over in place: what it showed leaves in this time…
    static let rowLeave: Double = 0.14
    /// …and what it shows next takes this long to come in. A row new to the list comes in the same way.
    static let rowEnter: Double = 0.22
    /// A row dropping out of the list fades in this time.
    static let rowDepart: Double = 0.16
    /// The highlight of a row the pointer is on, against a pressed row's full strength.
    static let rowLitOpacity: Float = 0.6
    /// The other rows while one is lit.
    static let rowDimOpacity: Float = 0.5
    /// The card grows from this size out of its row, and leaves in this many seconds.
    static let cardStartScale: CGFloat = 0.9
    static let cardLeave: Double = 0.1

    /// Stroke of the glyphs drawn here, on their 16-unit grid.
    static let glyphLine: CGFloat = 1.5
    /// The drawn glyphs span this many of the grid's 16 units.
    static let glyphExtent: CGFloat = 12

    static let inkColor = nsDynamic(light: 0x111827, dark: 0xF3F4F6)
    static let secondaryColor = nsDynamic(light: 0x111827, dark: 0xF3F4F6, lightAlpha: 0.66, darkAlpha: 0.66)
    static let trackColor = nsDynamic(light: 0x111827, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.13)
    /// Behind a core column: fainter than other tracks, so the fill carries the shape.
    static let coreTrackColor = nsDynamic(light: 0x111827, dark: 0xFFFFFF, lightAlpha: 0.065, darkAlpha: 0.08)
    /// The disc behind a badge's glyph.
    static let badgeColor = nsDynamic(light: 0x111827, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.11)
    /// The glyph on a switch that is on.
    static let toggleInkColor = nsDynamic(light: 0xFFFFFF, dark: 0x14161B)
    static let cardColor = nsDynamic(light: 0xFFFFFF, dark: 0x2C2F3A, lightAlpha: 0.97, darkAlpha: 0.96)
    static let cardEdgeColor = nsDynamic(light: 0x111827, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.16)
    static let normalColor = nsDynamic(light: 0x1C9A50, dark: 0x4FD17F)
    static let warningColor = nsDynamic(light: 0xB26A00, dark: 0xF0B54A)
    static let criticalColor = nsDynamic(light: 0xD23F31, dark: 0xFF6B5E)
    static let chipColor = nsDynamic(light: 0x111827, dark: 0xF3F4F6)
    static let chipTextColor = nsDynamic(light: 0xFFFFFF, dark: 0x14161B)
    /// Behind the pin and hide buttons, so they read over whatever is under them.
    static let controlColor = nsDynamic(light: 0xFFFFFF, dark: 0x2A2D34, lightAlpha: 0.94, darkAlpha: 0.94)

    /// A switch that is off, and the same under the pointer.
    static let controlDiscColor = nsDynamic(light: 0x111827, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.11)
    static let controlDiscHoverColor = nsDynamic(light: 0x111827, dark: 0xFFFFFF, lightAlpha: 0.15, darkAlpha: 0.2)

    var performanceColor: NSColor { Self.nsDynamic(light: palette.colors.pLight, dark: palette.colors.pDark) }
    var efficiencyColor: NSColor { Self.nsDynamic(light: palette.colors.eLight, dark: palette.colors.eDark) }
    /// Core groups run from the performance color to the efficiency color in even steps,
    /// so a chip with any number of kinds of core has a color for each.
    func coreColor(group: Int, of count: Int) -> NSColor {
        let share = count > 1 ? Double(min(max(0, group), count - 1)) / Double(count - 1) : 0
        let colors = palette.colors
        return Self.nsDynamic(light: Self.mix(colors.pLight, colors.eLight, share), dark: Self.mix(colors.pDark, colors.eDark, share))
    }
    var gpuColor: NSColor { Self.nsDynamic(light: palette.gpuColors.light, dark: palette.gpuColors.dark) }

    func color(_ paint: Paint) -> NSColor {
        switch paint {
        case .ink: Self.inkColor
        case .secondary: Self.secondaryColor
        case .track: Self.trackColor
        case .badge: Self.badgeColor
        case .performance: performanceColor
        case .efficiency: efficiencyColor
        case .gpu: gpuColor
        case .core(let group, let count): coreColor(group: group, of: count)
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

    /// The color `share` of the way from one hex color to another.
    static func mix(_ first: Int, _ second: Int, _ share: Double) -> Int {
        [16, 8, 0].reduce(0) { result, shift in
            let from = Double((first >> shift) & 0xFF)
            let to = Double((second >> shift) & 0xFF)
            return result | Int((from + (to - from) * share).rounded()) << shift
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

    /// The GPU's color for light and dark appearance.
    var gpuColors: (light: Int, dark: Int) {
        switch self {
        case .sea: (0x7A4FD6, 0xB294FF)
        case .graphite: (0x8A6D2F, 0xC9B98F)
        case .warm: (0xB83280, 0xFF8FC4)
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
    static var noReading: String { pick("no reading yet", "尚无读数") }

    static func gpu(_ gpu: GPUSample, watts: Double?) -> String {
        var parts = ["GPU", "\(Format.percent(gpu.usage))%"]
        parts.append(gpu.frequencyMHz.value.map { "\(Format.gigahertz($0)) GHz" } ?? pick("frequency unavailable", "频率不可用"))
        if let watts { parts.append("\(Format.watts(watts)) W") }
        parts.append(gpu.memoryBytes.value.map { "VRAM \(Format.gigabytes($0)) GB" } ?? pick("VRAM unavailable", "VRAM 不可用"))
        parts.append(gpu.temperature.value.map { Format.degrees($0.celsius) } ?? pick("temperature unavailable", "温度不可用"))
        return parts.joined(separator: " · ")
    }

    static func power(_ power: PowerSample) -> String {
        var parts = [pick("Whole machine", "整机功耗") + " \(Format.watts(power.systemWatts)) W"]
        if let input = power.inputWatts.value { parts.append(pick("Adapter", "电源输入") + " \(Format.watts(input)) W") }
        if let gpu = power.gpuWatts.value { parts.append("GPU \(Format.watts(gpu)) W") }
        return parts.joined(separator: " · ")
    }

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
        let source =
            switch temperature.source {
            case .cpuCluster: pick("CPU cluster sensors", "处理器簇传感器")
            case .chipDie: pick("chip die sensors", "芯片传感器")
            case .gpu: pick("GPU sensors", "GPU 传感器")
            }
        return pick("Temperature", "温度") + " \(Format.degrees(temperature.celsius)) · \(temperature.sensorCount) \(source)"
    }
}
