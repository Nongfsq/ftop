import AppKit

/// The ftop mark: a snowy owl with its eyes closed under a night sky. Used for the
/// app icon. The drawing is the approved design `A2` on the design canvas
/// (`design/canvas/Logo.dc.html`), in the same 100-unit square.
@MainActor
public enum Logo {
    /// The app icon at `pixels` square.
    public static func appIcon(pixels: Int) -> CGImage? {
        let side = CGFloat(pixels)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        let night = color(0x1A2036)
        let snow = color(0xF5F2EA)
        let amber = color(0xE9A93B)

        // Draw in the design's coordinates: 100 units square, origin at the top left.
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: side / 100, y: -side / 100)

        // macOS icon shape: a rounded square inset from the canvas.
        let tile = CGPath(roundedRect: CGRect(x: 9.8, y: 9.8, width: 80.4, height: 80.4), cornerWidth: 18.1, cornerHeight: 18.1, transform: nil)
        context.addPath(tile)
        context.clip()
        let sky = CGGradient(colorsSpace: space, colors: [color(0x34406B), night] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: 9.8), end: CGPoint(x: 0, y: 90.2), options: [])

        // Two stars.
        context.setFillColor(color(0xF5F2EA, 0.7))
        context.fillEllipse(in: CGRect(x: 74.9, y: 24.9, width: 2.2, height: 2.2))
        context.setFillColor(color(0xF5F2EA, 0.5))
        context.fillEllipse(in: CGRect(x: 22.2, y: 29.2, width: 1.6, height: 1.6))

        // Head and shoulders, running off the bottom of the tile.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 50, y: 28))
        body.addCurve(to: CGPoint(x: 75, y: 53), control1: CGPoint(x: 66, y: 28), control2: CGPoint(x: 75, y: 39))
        body.addCurve(to: CGPoint(x: 81, y: 95), control1: CGPoint(x: 75, y: 64), control2: CGPoint(x: 79, y: 76))
        body.addLine(to: CGPoint(x: 19, y: 95))
        body.addCurve(to: CGPoint(x: 25, y: 53), control1: CGPoint(x: 21, y: 76), control2: CGPoint(x: 25, y: 64))
        body.addCurve(to: CGPoint(x: 50, y: 28), control1: CGPoint(x: 25, y: 39), control2: CGPoint(x: 34, y: 28))
        body.closeSubpath()
        context.addPath(body)
        context.setFillColor(snow)
        context.fillPath()

        // The facial disc, a shade darker than the feathers.
        let disc = CGMutablePath()
        disc.move(to: CGPoint(x: 50, y: 44))
        disc.addCurve(to: CGPoint(x: 31, y: 43), control1: CGPoint(x: 46, y: 38), control2: CGPoint(x: 36, y: 37))
        disc.addCurve(to: CGPoint(x: 38, y: 59), control1: CGPoint(x: 27, y: 49), control2: CGPoint(x: 30, y: 58))
        disc.addCurve(to: CGPoint(x: 50, y: 53), control1: CGPoint(x: 44, y: 60), control2: CGPoint(x: 48, y: 57))
        disc.addCurve(to: CGPoint(x: 62, y: 59), control1: CGPoint(x: 52, y: 57), control2: CGPoint(x: 56, y: 60))
        disc.addCurve(to: CGPoint(x: 69, y: 43), control1: CGPoint(x: 70, y: 58), control2: CGPoint(x: 73, y: 49))
        disc.addCurve(to: CGPoint(x: 50, y: 44), control1: CGPoint(x: 64, y: 37), control2: CGPoint(x: 54, y: 38))
        disc.closeSubpath()
        context.addPath(disc)
        context.setFillColor(color(0xE7E3D9))
        context.fillPath()

        // Closed eyes.
        context.setStrokeColor(night)
        context.setLineWidth(2.2)
        context.setLineCap(.round)
        for x in [34.5, 55.5] as [CGFloat] {
            context.move(to: CGPoint(x: x, y: 48.5))
            context.addQuadCurve(to: CGPoint(x: x + 10, y: 48.5), control: CGPoint(x: x + 5, y: 53))
        }
        context.strokePath()

        // Beak.
        context.move(to: CGPoint(x: 47.6, y: 54.5))
        context.addLine(to: CGPoint(x: 52.4, y: 54.5))
        context.addLine(to: CGPoint(x: 50, y: 59))
        context.closePath()
        context.setFillColor(amber)
        context.setStrokeColor(amber)
        context.setLineWidth(1.2)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        return context.makeImage()
    }
}
