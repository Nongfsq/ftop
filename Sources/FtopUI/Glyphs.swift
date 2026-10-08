import AppKit

/// The small picture inside a badge. Each reading has one, and it is the same picture at every window size.
public enum Glyph: Hashable, Sendable {
    case cpu, gpu, memory, temperature, download, upload, adapter, machine, power
    /// A process that belongs to no app.
    case process

    /// System symbols, where their shape stays clear at badge size. The chip, the memory
    /// module, and the thermometer are drawn here instead: the system's have pins and
    /// tick marks that close up into a blot this small.
    var symbol: String? {
        switch self {
        case .gpu: "square.stack.3d.up"
        case .download: "arrow.down"
        case .upload: "arrow.up"
        case .adapter: "powerplug"
        case .machine: "laptopcomputer"
        case .power: "bolt.fill"
        case .cpu, .memory, .temperature, .process: nil
        }
    }
}

@MainActor
enum GlyphArt {
    private struct Key: Hashable {
        var glyph: Glyph
        var size: CGFloat
    }

    private static var masks: [Key: (image: CGImage, size: CGSize)] = [:]

    /// Draws `glyph` centered in `rect`, in a context with its origin at the top left.
    static func draw(_ glyph: Glyph, in rect: CGRect, color: CGColor, context: CGContext) {
        if glyph.symbol != nil {
            drawSymbol(glyph, in: rect, color: color, context: context)
        } else {
            context.saveGState()
            // Paths are written on a 16-unit grid and fill its middle; scale that part to the box.
            let unit = rect.width / PanelStyle.glyphExtent
            context.translateBy(x: rect.midX - 8 * unit, y: rect.midY - 8 * unit)
            context.scaleBy(x: unit, y: unit)
            context.setStrokeColor(color)
            context.setLineWidth(PanelStyle.glyphLine)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path(glyph))
            context.strokePath()
            context.restoreGState()
        }
    }

    /// How wide the ink of `glyph` is when drawn in a box `side` wide, where a figure
    /// beside it is spaced from the ink and not from the box.
    static func inkWidth(_ glyph: Glyph, side: CGFloat) -> CGFloat {
        if glyph.symbol != nil { return symbolMask(glyph, side: side)?.size.width ?? side }
        // The drawn glyphs' strokes end past the 12 units their paths span.
        let unit = side / PanelStyle.glyphExtent
        switch glyph {
        case .cpu: return (12 + PanelStyle.glyphLine) * unit
        case .memory: return (11 + PanelStyle.glyphLine) * unit
        default: return side
        }
    }

    private static func symbolMask(_ glyph: Glyph, side: CGFloat) -> (image: CGImage, size: CGSize)? {
        let key = Key(glyph: glyph, size: (side * 4).rounded() / 4)
        if masks[key] == nil, let name = glyph.symbol {
            let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .semibold)
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
            // Rendered large enough for any screen the panel is on.
            var proposed = CGRect(origin: .zero, size: CGSize(width: image.size.width * 4, height: image.size.height * 4))
            guard let whole = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil), let inked = trimmed(whole) else { return nil }
            // Symbols come with different margins and proportions; each is cut to its ink
            // and fitted so its longer side is the box's.
            let fit = side / CGFloat(max(inked.width, inked.height))
            if masks.count > 200 { masks.removeAll() }
            masks[key] = (inked, CGSize(width: CGFloat(inked.width) * fit, height: CGFloat(inked.height) * fit))
        }
        return masks[key]
    }

    private static func drawSymbol(_ glyph: Glyph, in rect: CGRect, color: CGColor, context: CGContext) {
        guard let mask = symbolMask(glyph, side: rect.width) else { return }
        let box = CGRect(x: rect.midX - mask.size.width / 2, y: rect.midY - mask.size.height / 2, width: mask.size.width, height: mask.size.height)
        context.saveGState()
        // Images are drawn bottom-up; the context is top-down.
        context.translateBy(x: box.minX, y: box.maxY)
        context.scaleBy(x: 1, y: -1)
        let local = CGRect(origin: .zero, size: box.size)
        context.clip(to: local, mask: mask.image)
        context.setFillColor(color)
        context.fill(local)
        context.restoreGState()
    }

    /// `image` cut down to the pixels that are not transparent.
    static func trimmed(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var left = width
        var right = -1
        var top = height
        var bottom = -1
        for row in 0..<height {
            for column in 0..<width where alpha[row * width + column] > 8 {
                left = min(left, column)
                right = max(right, column)
                top = min(top, row)
                bottom = max(bottom, row)
            }
        }
        guard right >= left, bottom >= top else { return nil }
        return image.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1))
    }

    private static func path(_ glyph: Glyph) -> CGPath {
        let path = CGMutablePath()
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
        }
        switch glyph {
        case .cpu:
            path.addRoundedRect(in: CGRect(x: 4, y: 4, width: 8, height: 8), cornerWidth: 1.5, cornerHeight: 1.5)
            for offset in [6.5, 9.5] as [CGFloat] {
                line(offset, 4, offset, 2)
                line(offset, 12, offset, 14)
                line(4, offset, 2, offset)
                line(12, offset, 14, offset)
            }
        case .memory:
            path.addRoundedRect(in: CGRect(x: 2.5, y: 5, width: 11, height: 6), cornerWidth: 1, cornerHeight: 1)
            for offset in [5, 8, 11] as [CGFloat] {
                line(offset, 5, offset, 3)
                line(offset, 11, offset, 13)
            }
        case .temperature:
            // A stem with a round top that opens into the bulb, as one outline.
            let stem: CGFloat = 1.6
            let bulb: CGFloat = 3.1
            let center = CGPoint(x: 8, y: 11.4)
            let join = center.y - (bulb * bulb - stem * stem).squareRoot()
            path.move(to: CGPoint(x: 8 - stem, y: join))
            path.addLine(to: CGPoint(x: 8 - stem, y: 3.6))
            for step in 0...12 {
                let angle = CGFloat.pi + CGFloat.pi * CGFloat(step) / 12
                path.addLine(to: CGPoint(x: 8 + stem * cos(angle), y: 3.6 + stem * sin(angle)))
            }
            path.addLine(to: CGPoint(x: 8 + stem, y: join))
            let start = atan2(join - center.y, stem)
            let sweep = 2 * CGFloat.pi - 2 * (CGFloat.pi / 2 + start)
            for step in 0...32 {
                let angle = start + sweep * CGFloat(step) / 32
                path.addLine(to: CGPoint(x: center.x + bulb * cos(angle), y: center.y + bulb * sin(angle)))
            }
            path.closeSubpath()
        case .process:
            // A gear: a hub and eight teeth.
            path.addEllipse(in: CGRect(x: 5.6, y: 5.6, width: 4.8, height: 4.8))
            for step in 0..<8 {
                let angle = CGFloat(step) * .pi / 4
                line(8 + 4 * cos(angle), 8 + 4 * sin(angle), 8 + 5.9 * cos(angle), 8 + 5.9 * sin(angle))
            }
        default: break
        }
        return path
    }
}
