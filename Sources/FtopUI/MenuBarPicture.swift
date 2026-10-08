import AppKit
import FtopCore

/// The menu bar item: one reading's glyph and its figure, drawn as one picture, so the
/// glyph, the digits, and the unit are placed here and not by the button.
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

    /// The item's width with `room` for its figure. The caller keeps the room steady, so
    /// the items beside this one do not move with every digit.
    public static func width(of metric: MenuBarMetric, room: CGFloat) -> CGFloat {
        ceil(figureStart(of: metric) + room + PanelStyle.menuBarPadding)
    }

    /// Half points, which are whole pixels on the screens Macs have.
    private static func snapped(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

    /// The glyph's ink starts at the padding and the figure a fixed gap after the ink,
    /// whatever the glyph's own width: an arrow is narrower than the chip.
    private static func inkWidth(of metric: MenuBarMetric) -> CGFloat {
        snapped(GlyphArt.inkWidth(glyph(of: metric), side: PanelStyle.menuBarGlyph))
    }

    private static func figureStart(of metric: MenuBarMetric) -> CGFloat {
        PanelStyle.menuBarPadding + inkWidth(of: metric) + PanelStyle.menuBarGap
    }

    /// The picture in `color`, `height` points tall, with `room` for the figure. `figure`
    /// nil draws a dash: the machine does not report the reading.
    public static func picture(_ metric: MenuBarMetric, figure: Format.Quantity?, room: CGFloat, height: CGFloat, scale: CGFloat, color: CGColor) -> CGImage? {
        let size = CGSize(width: width(of: metric, room: room), height: height)
        return drawnImage(size: size, scale: scale) { context in
            // The glyph's middle and the middle of the digits' height are the bar's middle.
            // Both are then moved to whole pixels: the glyph a quarter point off the half
            // points, so its strokes, a point and a half wide, cover whole pixels on both sides.
            let side = PanelStyle.menuBarGlyph
            let top = snapped((height - side) / 2) - 0.25
            // The glyph and its figure are one group in the middle of the item: where the
            // figure is narrower than its room, what is left is the same on both sides.
            let slack = snapped(max(0, room - figureWidth(figure)) / 2)
            let left = PanelStyle.menuBarPadding + slack - (side - inkWidth(of: metric)) / 2
            let box = CGRect(x: snapped(left - 0.25) + 0.25, y: top, width: side, height: side)
            GlyphArt.draw(glyph(of: metric), in: box, color: color, context: context)

            let baseline = snapped((height + numberFont.capHeight) / 2)
            var x = figureStart(of: metric) + slack
            context.setFillColor(color)
            let number = line(figure?.number ?? "–", numberFont)
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(number.line, context)
            guard let figure else { return }
            // The unit is smaller and lighter than its number, on the same baseline, as in the panel.
            x += number.width + PanelStyle.menuBarUnitGap
            context.setAlpha(PanelStyle.menuBarUnitOpacity)
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line(figure.shortUnit, unitFont).line, context)
        }
    }

    /// The picture for a status item: the system colors it for a light or dark menu bar.
    public static func image(_ metric: MenuBarMetric, figure: Format.Quantity?, room: CGFloat, height: CGFloat, scale: CGFloat) -> NSImage? {
        guard let picture = picture(metric, figure: figure, room: room, height: height, scale: scale, color: CGColor(gray: 0, alpha: 1)) else { return nil }
        let image = NSImage(cgImage: picture, size: CGSize(width: width(of: metric, room: room), height: height))
        image.isTemplate = true
        return image
    }
}
