import AppKit
import Testing

@testable import FtopCore
@testable import FtopUI

/// Draws the panel off screen for a set of dragged window sizes and writes PNG files,
/// so layouts can be reviewed without a screen recording permission. Each image is the
/// size the window snaps to. Runs only when asked:
///
///     FTOP_RENDER_DIR=/tmp/ftop-render swift test --filter RenderTests
private let renderDirectory = ProcessInfo.processInfo.environment["FTOP_RENDER_DIR"]
/// Frames for the README pictures (`scripts/readme-media.sh`): the panel alone on a
/// transparent background, with sample readings.
private let demoDirectory = ProcessInfo.processInfo.environment["FTOP_DEMO_DIR"]

@MainActor
@Suite struct RenderTests {
    static let sizes: [(Double, Double)] = [
        (64, 26), (280, 30), (620, 30), (60, 330), (200, 150), (300, 420), (300, 640), (445, 820), (480, 260), (660, 230), (860, 820),
        (1000, 435), (1049, 500), (1400, 800), (1700, 1000), (700, 1000),
    ]

    @Test(.enabled(if: renderDirectory != nil))
    func writeReferenceImages() throws {
        let directory = URL(fileURLWithPath: renderDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [true, false] {
            for (width, height) in Self.sizes {
                let model = PanelModel()
                var config = Config()
                config.motion = false
                config.language = .zh
                model.apply(config)
                model.ingest(Snapshot.sample(performance: 10, efficiency: 4))
                model.setChoice(model.choice(for: CGSize(width: width, height: height)))

                let frame = NSRect(origin: .zero, size: model.hugSize)
                let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let backdrop = NSView(frame: frame)
                backdrop.wantsLayer = true
                // Stands in for the glass material over a mid-tone wallpaper.
                backdrop.layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.9, alpha: 1)).cgColor
                model.canvas.frame = frame
                backdrop.addSubview(model.canvas)
                window.contentView = backdrop
                model.render()
                window.layoutIfNeeded()
                backdrop.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))

                let scale: CGFloat = 2
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(frame.width * scale), pixelsHigh: Int(frame.height * scale), bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                bitmap.size = frame.size
                let context = NSGraphicsContext(bitmapImageRep: bitmap)!
                backdrop.layer?.render(in: context.cgContext)
                let choice = model.choice.candidate
                let label = "\(choice.tier)-c\(choice.columns)-p\(choice.processCount)\(choice.memoryList ? "-mem" : "")"
                let name = "\(Int(width))x\(Int(height))-\(label)-\(dark ? "dark" : "light").png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appending(path: name))
            }
        }
    }

    /// The settings window's contents, in both languages.
    @Test(.enabled(if: renderDirectory != nil))
    func writeSettingsImages() throws {
        let directory = URL(fileURLWithPath: renderDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for language in [Language.en, .zh] {
            Strings.language = language
            let content = SettingsWindowController(config: Config()).makeContent()
            let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = content
            window.layoutIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "settings-\(language.rawValue).png"))
        }
        Strings.language = .auto
    }

    static let demoSizes: [(Double, Double)] = [(64, 26), (280, 30), (200, 150), (300, 420), (480, 260), (660, 230), (860, 500), (1049, 500)]

    /// Sample readings at time `t`; whole numbers are the states the panel rests on.
    static func demoSnapshot(_ t: Double) -> Snapshot {
        var snapshot = Snapshot.sample(performance: 10, efficiency: 4)
        guard var cpu = snapshot.cpu.value else { return snapshot }
        for index in cpu.cores.indices {
            let wave = sin(t * 1.9 + Double(index) * 1.7) * 0.2 + sin(t * 0.8 + Double(index) * 0.6) * 0.1
            let usage = min(0.97, max(0.04, cpu.cores[index].usage + wave))
            cpu.cores[index].usage = usage
            let efficiency = cpu.cores[index].kind == .efficiency
            cpu.cores[index].frequencyMHz = .value((efficiency ? 900 : 1000) + usage * (efficiency ? 1600 : 3200))
        }
        snapshot.cpu = .value(cpu)
        snapshot.network = .value(
            NetworkSample(downBytesPerSecond: 2_400_000 * (1.2 + sin(t * 1.3)), upBytesPerSecond: 188_000 * (1.3 + cos(t * 1.1))))
        return snapshot
    }

    @Test(.enabled(if: demoDirectory != nil))
    func writeDemoFrames() throws {
        let directory = URL(fileURLWithPath: demoDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (width, height) in Self.demoSizes {
            do {
                let frame = 0
                let model = PanelModel()
                var config = Config()
                config.motion = false
                config.language = .en
                model.apply(config)
                model.ingest(Self.demoSnapshot(Double(frame) / 4))
                model.setChoice(model.choice(for: CGSize(width: width, height: height)))

                let frameRect = NSRect(origin: .zero, size: model.hugSize)
                let window = NSWindow(contentRect: frameRect, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.isOpaque = false
                window.backgroundColor = .clear
                let backdrop = NSView(frame: frameRect)
                backdrop.wantsLayer = true
                model.canvas.frame = frameRect
                backdrop.addSubview(model.canvas)
                window.contentView = backdrop
                model.render()
                window.layoutIfNeeded()
                backdrop.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))

                let scale: CGFloat = 2
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(frameRect.width * scale), pixelsHigh: Int(frameRect.height * scale), bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                bitmap.size = frameRect.size
                backdrop.layer?.render(in: NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext)
                let name = String(format: "%dx%d-%02d.png", Int(width), Int(height), frame)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appending(path: name))
            }
        }
        Strings.language = .auto
    }
}
