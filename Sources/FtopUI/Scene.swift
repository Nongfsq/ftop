import AppKit
import CoreText
import FtopCore

// A scene is the panel's contents as plain geometry: where every piece of text, shape,
// and core column goes for one layout at one scale. Building it is arithmetic on
// measured text, so the same scene is drawn on screen, checked in tests, and used to
// size the window. Coordinates have their origin at the top left.

public struct TextItem: Hashable, Sendable {
    public var string: String
    /// Left edge of the drawn text.
    public var x: CGFloat
    public var baseline: CGFloat
    public var width: CGFloat
    public var font: FontSpec
    public var paint: Paint
}

public struct ShapeItem: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case circle
        /// A capsule track filled from the left by consecutive segments (0...1 each).
        case meter(track: Paint?, segments: [Segment], outline: Paint?)
        /// The round mark in front of a figure: a soft disc with a glyph. A gauge has an `ArcItem` around its edge as well.
        case badge(glyph: Glyph, tint: Paint)
        /// A badge that is a switch: filled with `paint` while it is on.
        case toggle(glyph: Glyph, on: Bool, paint: Paint)
    }

    public struct Segment: Hashable, Sendable {
        public var fraction: Double
        public var paint: Paint
    }

    public var rect: CGRect
    public var paint: Paint
    public var kind: Kind
}

/// The arc of a ring badge, from the top clockwise. Drawn as a layer, so it glides to each reading like the core columns.
public struct ArcItem: Hashable, Sendable {
    public var rect: CGRect
    public var fraction: Double
    public var paint: Paint
}

/// Where the core columns go. They are drawn by `CoreBarsView`, not by the canvas.
public struct BarsItem: Equatable, Sendable {
    public var rect: CGRect
    public var cores: [CoreSample]
    public var showsFrequency: Bool
    public var gap: CGFloat
    public var groupGap: CGFloat
    /// One color for every column instead of a color for each group of cores.
    public var paint: Paint?
}

/// What a floating card says about one row of the process list.
public struct ProcessCard: Hashable, Sendable {
    public var name: String
    public var appPath: String?
    public var cpu: String
    public var cpuShare: Double
    public var memory: String
    public var memoryUnit: String
    public var memoryShare: Double
    /// The heaviest processes folded into the entry, with the figure the list is ranked by.
    public var members: [Member]

    public struct Member: Hashable, Sendable {
        public var name: String
        public var value: String
        public var unit: String
    }
}

public struct ProcessRow: Hashable, Sendable {
    /// Stable while the entry stays listed, so its row can slide to a new rank.
    public var key: String
    public var name: String
    public var appPath: String?
    public var value: String
    public var unit: String
    /// The entry's share of what is in use: the arc around its badge.
    public var share: Double
    public var card: ProcessCard
}

/// Where the process rows go. They are layers in `ProcessRowsView`, so a row can slide
/// to a new rank and give under a press; the canvas does not draw them.
public struct ProcessRowsItem: Equatable, Sendable {
    public var rect: CGRect
    public var rows: [ProcessRow]
    /// Rows fill a column top to bottom, then continue in the next.
    public var perColumn: Int
    public var rowHeight: CGFloat
    public var columnWidth: CGFloat
    public var columnGap: CGFloat
    public var pitch: CGFloat
    public var paint: Paint

    /// The row at `index`, in the item's own coordinates.
    public func frame(at index: Int) -> CGRect {
        let column = CGFloat(index / max(1, perColumn))
        let line = CGFloat(index % max(1, perColumn))
        return CGRect(x: column * (columnWidth + columnGap), y: line * pitch, width: columnWidth, height: rowHeight)
    }
}

public enum ClickAction: Hashable, Sendable {
    case sort(ProcessSort)
    /// A row of the process list, by its key.
    case process(String)
}

public struct ClickRegion: Equatable, Sendable {
    public var rect: CGRect
    public var action: ClickAction
}

public struct HoverRegion: Equatable, Sendable {
    public var rect: CGRect
    public var text: String
    /// Set for a core column, so the column can be highlighted.
    public var coreIndex: Int?
    /// Set for a row of the process list, so the row can be lit.
    public var processKey: String?
}

public struct Scene: Equatable, Sendable {
    public var size: CGSize = .zero
    public var texts: [TextItem] = []
    public var shapes: [ShapeItem] = []
    public var arcs: [ArcItem] = []
    public var bars: BarsItem?
    /// The GPU's one column, beside the core columns and drawn the same way.
    public var gpuBar: BarsItem?
    public var processes: ProcessRowsItem?
    public var clicks: [ClickRegion] = []
    /// Later regions sit on top of earlier ones.
    public var hovers: [HoverRegion] = []

    public init() {}

    mutating func append(_ other: Scene, at origin: CGPoint) {
        texts += other.texts.map {
            var item = $0
            item.x += origin.x
            item.baseline += origin.y
            return item
        }
        shapes += other.shapes.map {
            var item = $0
            item.rect = item.rect.offsetBy(dx: origin.x, dy: origin.y)
            return item
        }
        arcs += other.arcs.map {
            var item = $0
            item.rect = item.rect.offsetBy(dx: origin.x, dy: origin.y)
            return item
        }
        hovers += other.hovers.map {
            var item = $0
            item.rect = item.rect.offsetBy(dx: origin.x, dy: origin.y)
            return item
        }
        clicks += other.clicks.map {
            var item = $0
            item.rect = item.rect.offsetBy(dx: origin.x, dy: origin.y)
            return item
        }
        if var item = other.processes {
            item.rect = item.rect.offsetBy(dx: origin.x, dy: origin.y)
            processes = item
        }
        if var item = other.bars {
            item.rect = item.rect.offsetBy(dx: origin.x, dy: origin.y)
            bars = item
        }
        if var item = other.gpuBar {
            item.rect = item.rect.offsetBy(dx: origin.x, dy: origin.y)
            gpuBar = item
        }
    }

    public func click(at point: CGPoint) -> ClickRegion? {
        clicks.last { $0.rect.contains(point) }
    }

    public func hover(at point: CGPoint) -> HoverRegion? {
        hovers.last { $0.rect.contains(point) }
    }
}

extension TextItem {
    /// The box the glyphs are drawn in, for redrawing and for tests.
    @MainActor public var frame: CGRect {
        let metrics = Typesetter.metrics(font)
        return CGRect(x: x, y: baseline - metrics.ascent, width: width, height: metrics.ascent + metrics.descent)
    }
}

/// Fonts, text widths, and typeset lines, each made once and reused.
@MainActor
public enum Typesetter {
    struct Metrics {
        var ascent: CGFloat
        var descent: CGFloat
        var capHeight: CGFloat
        var lineHeight: CGFloat { ascent + descent }
    }

    private struct LineKey: Hashable {
        var string: String
        var font: FontSpec
    }

    private static var fonts: [FontSpec: NSFont] = [:]
    private static var fontMetrics: [FontSpec: Metrics] = [:]
    private static var lines: [LineKey: (line: CTLine, width: CGFloat)] = [:]

    /// Drops everything typeset so far. Called after a resize, which passes through
    /// many type sizes that will not be used again.
    public static func trim() {
        fonts.removeAll()
        fontMetrics.removeAll()
        lines.removeAll()
    }

    static func nsFont(_ spec: FontSpec) -> NSFont {
        if let font = fonts[spec] { return font }
        let base = NSFont.systemFont(ofSize: spec.size, weight: NSFont.Weight(spec.weight))
        // Rounded design with fixed-width digits, so changing numbers do not shift their neighbors.
        let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let descriptor = rounded.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector]]
        ])
        let font = NSFont(descriptor: descriptor, size: spec.size) ?? base
        if fonts.count > 400 { fonts.removeAll() }
        fonts[spec] = font
        return font
    }

    static func metrics(_ spec: FontSpec) -> Metrics {
        if let known = fontMetrics[spec] { return known }
        let font = nsFont(spec)
        let metrics = Metrics(ascent: ceil(font.ascender), descent: ceil(-font.descender), capHeight: font.capHeight)
        if fontMetrics.count > 400 { fontMetrics.removeAll() }
        fontMetrics[spec] = metrics
        return metrics
    }

    /// The line takes its color from the context it is drawn in, so one cached line
    /// serves every appearance and palette.
    static func line(_ string: String, _ spec: FontSpec) -> (line: CTLine, width: CGFloat) {
        let key = LineKey(string: string, font: spec)
        if let known = lines[key] { return known }
        let attributed = NSAttributedString(
            string: string,
            attributes: [.font: nsFont(spec), NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if lines.count > 6000 { lines.removeAll() }
        lines[key] = (line, width)
        return (line, width)
    }

    static func width(_ string: String, _ spec: FontSpec) -> CGFloat {
        ceil(line(string, spec).width * 2) / 2
    }

    /// `string` cut with an ellipsis to fit `width`.
    static func truncated(_ string: String, _ spec: FontSpec, to width: CGFloat) -> String {
        guard Typesetter.width(string, spec) > width else { return string }
        var characters = Array(string)
        while characters.count > 1 {
            characters.removeLast()
            while characters.last == " " { characters.removeLast() }
            let candidate = String(characters) + "…"
            if Typesetter.width(candidate, spec) <= width { return candidate }
        }
        return "…"
    }
}
