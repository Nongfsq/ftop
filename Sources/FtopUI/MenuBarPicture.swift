import AppKit
import FtopCore

/// The menu bar item: each reading's glyph and its figure, one to three of them, drawn as
/// one picture, so the glyphs, the digits, and the units are placed here and not by the button.
@MainActor
public enum MenuBarPicture {
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: PanelStyle.menuBarNumberSize, weight: .medium)
    private static let unitFont = NSFont.monospacedDigitSystemFont(ofSize: PanelStyle.menuBarUnitSize, weight: .medium)

    private static func glyph(of metric: MenuBarMetric) -> Glyph {
        switch metric {
        case .cpu: .cpu
        case .memory: .memory
        case .gpu: .gpu
        case .download: .download
        case .upload: .upload
        case .power: .power
        }
    }

    private static func line(_ string: String, _ font: NSFont) -> (line: CTLine, width: CGFloat) {
        let attributed = NSAttributedString(
            string: string, attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
        let line = CTLineCreateWithAttributedString(attributed)
        return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// How wide `figure` is written; nil is the dash for a reading the machine does not give.
    public static func figureWidth(_ figure: Format.Quantity?) -> CGFloat {
        guard let figure else { return snapped(line("–", numberFont).width) }
        return snapped(line(figure.number, numberFont).width + PanelStyle.menuBarUnitGap + line(figure.shortUnit, unitFont).width)
    }

    /// One reading in the item: what it is, its figure (nil is the dash), and the room
    /// kept for that figure. The caller keeps the room steady, so the items beside this
    /// one do not move with every digit.
    public struct Entry: Equatable {
        public var metric: MenuBarMetric
        public var figure: Format.Quantity?
        public var room: CGFloat

        public init(_ metric: MenuBarMetric, figure: Format.Quantity?, room: CGFloat) {
            self.metric = metric
            self.figure = figure
            self.room = room
        }
    }

    /// The item's width: each reading's glyph and room, with a gap between readings.
    public static func width(of entries: [Entry]) -> CGFloat {
        let groups = entries.reduce(0) { $0 + groupWidth($1) }
        return ceil(PanelStyle.menuBarPadding * 2 + groups + PanelStyle.menuBarEntryGap * CGFloat(max(0, entries.count - 1)))
    }

    /// Half points, which are whole pixels on the screens Macs have.
    private static func snapped(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

    /// The glyph's ink starts at the group's start and the figure a fixed gap after the
    /// ink, whatever the glyph's own width: an arrow is narrower than the chip.
    private static func inkWidth(of metric: MenuBarMetric) -> CGFloat {
        snapped(GlyphArt.inkWidth(glyph(of: metric), side: PanelStyle.menuBarGlyph))
    }

    private static func groupWidth(_ entry: Entry) -> CGFloat {
        inkWidth(of: entry.metric) + PanelStyle.menuBarGap + entry.room
    }

    /// The picture in `color`, `height` points tall.
    public static func picture(_ entries: [Entry], height: CGFloat, scale: CGFloat, color: CGColor) -> CGImage? {
        let size = CGSize(width: width(of: entries), height: height)
        return drawnImage(size: size, scale: scale) { context in
            var start = PanelStyle.menuBarPadding
            for entry in entries {
                draw(entry, from: start, height: height, color: color, context: context)
                start += groupWidth(entry) + PanelStyle.menuBarEntryGap
            }
        }
    }

    /// One reading's glyph and figure, its group starting at `start`.
    private static func draw(_ entry: Entry, from start: CGFloat, height: CGFloat, color: CGColor, context: CGContext) {
        let metric = entry.metric
        let figure = entry.figure
        // The glyph's middle and the middle of the digits' height are the bar's middle.
        // Both are then moved to whole pixels: the glyph a quarter point off the half
        // points, so its strokes, a point and a half wide, cover whole pixels on both sides.
        let side = PanelStyle.menuBarGlyph
        let top = snapped((height - side) / 2) - 0.25
        // The glyph and its figure are one group in the middle of its room: where the
        // figure is narrower than its room, what is left is the same on both sides.
        let slack = snapped(max(0, entry.room - figureWidth(figure)) / 2)
        let left = start + slack - (side - inkWidth(of: metric)) / 2
        let box = CGRect(x: snapped(left - 0.25) + 0.25, y: top, width: side, height: side)
        GlyphArt.draw(glyph(of: metric), in: box, color: color, context: context)

        let baseline = snapped((height + numberFont.capHeight) / 2)
        var x = start + inkWidth(of: metric) + PanelStyle.menuBarGap + slack
        context.setFillColor(color)
        let number = line(figure?.number ?? "–", numberFont)
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(number.line, context)
        guard let figure else { return }
        // The unit is smaller and lighter than its number, on the same baseline, as in the panel.
        x += number.width + PanelStyle.menuBarUnitGap
        context.saveGState()
        context.setAlpha(PanelStyle.menuBarUnitOpacity)
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line(figure.shortUnit, unitFont).line, context)
        context.restoreGState()
    }

    /// The picture for a status item: the system colors it for a light or dark menu bar.
    public static func image(_ entries: [Entry], height: CGFloat, scale: CGFloat) -> NSImage? {
        guard let picture = picture(entries, height: height, scale: scale, color: CGColor(gray: 0, alpha: 1)) else { return nil }
        let image = NSImage(cgImage: picture, size: CGSize(width: width(of: entries), height: height))
        image.isTemplate = true
        return image
    }
}
