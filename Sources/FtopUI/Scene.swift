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
    }

    public struct Segment: Hashable, Sendable {
        public var fraction: Double
        public var paint: Paint
    }

    public var rect: CGRect
    public var paint: Paint
    public var kind: Kind
}

/// Where the core columns go. They are drawn by `CoreBarsView`, not by the canvas.
public struct BarsItem: Equatable, Sendable {
    public var rect: CGRect
    public var cores: [CoreSample]
    public var showsFrequency: Bool
    public var gap: CGFloat
    public var groupGap: CGFloat
}

public struct HoverRegion: Equatable, Sendable {
    public var rect: CGRect
    public var text: String
    /// Set for a core column, so the column can be highlighted.
    public var coreIndex: Int?
}

public struct Scene: Equatable, Sendable {
    public var size: CGSize = .zero
    public var texts: [TextItem] = []
    public var shapes: [ShapeItem] = []
    public var bars: BarsItem?
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
        hovers += other.hovers.map {
            var item = $0
            item.rect = item.rect.offsetBy(dx: origin.x, dy: origin.y)
            return item
        }
        if var item = other.bars {
            item.rect = item.rect.offsetBy(dx: origin.x, dy: origin.y)
            bars = item
        }
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
