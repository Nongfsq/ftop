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
/// More than one frame per size gives a sequence at 15 frames a second in which the
/// readings change once a second and the columns ease to them, as in the running panel.
private let demoLanguage: Language = ProcessInfo.processInfo.environment["FTOP_DEMO_LANG"] == "zh" ? .zh : .en
/// `FTOP_DEMO_SIZES=96x32,400x30` replaces the default sizes; `FTOP_DEMO_SCALE` the pixel scale.
private let demoSizeList: [(Double, Double)]? = ProcessInfo.processInfo.environment["FTOP_DEMO_SIZES"].map {
    $0.split(separator: ",").compactMap { item in
        let parts = item.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
}
private let demoScale = ProcessInfo.processInfo.environment["FTOP_DEMO_SCALE"].flatMap { Double($0) } ?? 2
/// `FTOP_DEMO_PALETTE=warm` draws the demo frames in another palette, into files with that name in front.
private let demoPalette = ProcessInfo.processInfo.environment["FTOP_DEMO_PALETTE"].flatMap { PaletteID(rawValue: $0) }
/// `FTOP_RENDER_SCALE=4` writes the control block and card pictures at that many pixels per point.
private let renderScale = ProcessInfo.processInfo.environment["FTOP_RENDER_SCALE"].flatMap { Double($0) }

/// A bitmap to capture `view` into: the screen's own scale, or `FTOP_RENDER_SCALE` when set.
@MainActor
private func sharpBitmap(for view: NSView) -> NSBitmapImageRep? {
    guard let renderScale else { return view.bitmapImageRepForCachingDisplay(in: view.bounds) }
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * renderScale), pixelsHigh: Int(view.bounds.height * renderScale), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    bitmap?.size = view.bounds.size
    return bitmap
}
private let demoFrameCount = ProcessInfo.processInfo.environment["FTOP_DEMO_FRAMES"].flatMap { Int($0) } ?? 1

@MainActor
@Suite struct RenderTests {
    static let sizes: [(Double, Double)] = [
        (96, 32), (400, 30), (760, 30), (90, 330), (270, 150), (300, 420), (300, 640), (445, 820), (480, 260), (660, 230), (860, 820),
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

    /// Chips with three and four kinds of core (an M6 is 2 super, 4 performance, 6 efficiency), in every palette.
    @Test(.enabled(if: renderDirectory != nil))
    func writeThreeGroupImages() throws {
        let directory = URL(fileURLWithPath: renderDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (groups, palette) in [[2, 4, 6], [2, 2, 4, 4]].flatMap({ groups in PaletteID.allCases.map { (groups, $0) } }) {
            for dark in [true, false] {
                for (width, height) in [(400.0, 30.0), (270.0, 150.0), (300.0, 420.0), (660.0, 230.0)] {
                    let model = PanelModel()
                    var config = Config()
                    config.motion = false
                    config.palette = palette
                    model.apply(config)
                    model.ingest(Snapshot.sample(groups: groups))
                    model.setChoice(model.choice(for: CGSize(width: width, height: height)))

                    let frame = NSRect(origin: .zero, size: model.hugSize)
                    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let backdrop = NSView(frame: frame)
                    backdrop.wantsLayer = true
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
                    backdrop.layer?.render(in: NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext)
                    let name = "groups-\(groups.map(String.init).joined(separator: "+"))-\(Int(width))x\(Int(height))-\(palette.rawValue)-\(dark ? "dark" : "light").png"
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appending(path: name))
                }
            }
        }
    }

    /// The control block with "More" open, in both languages.
    @Test(.enabled(if: renderDirectory != nil))
    func writeSettingsImages() throws {
        let directory = URL(fileURLWithPath: renderDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for language in [Language.en, .zh] {
            Strings.language = language
            let state = ControlPanel.State(
                config: Config(), updateStatus: Strings.pick("Version 0.2.0 · up to date", "版本 0.2.0 · 已是最新"), updateAction: Strings.pick("Check Now", "立即检查"))
            // For the README: the block closed and open, dark, on nothing, to be set on glass.
            for expanded in [false, true] {
                let content = ControlPanel.picture(state, expanded: expanded)
                let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.isOpaque = false
                window.backgroundColor = .clear
                let backdrop = NSView(frame: content.frame)
                backdrop.wantsLayer = true
                backdrop.addSubview(content)
                window.contentView = backdrop
                window.layoutIfNeeded()
                let bitmap = try #require(sharpBitmap(for: backdrop))
                backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: directory.appending(path: "control-\(language.rawValue)-\(expanded ? "open" : "closed").png"))
            }
            // The closed block with the panel pinned, in each palette, for anything that shows a switch or the colors changing.
            for palette in PaletteID.allCases where language == .en {
                var pinned = state
                pinned.config.floating = true
                pinned.config.palette = palette
                let content = ControlPanel.picture(pinned, expanded: false)
                let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.isOpaque = false
                window.backgroundColor = .clear
                let backdrop = NSView(frame: content.frame)
                backdrop.wantsLayer = true
                backdrop.addSubview(content)
                window.contentView = backdrop
                window.layoutIfNeeded()
                let bitmap = try #require(sharpBitmap(for: backdrop))
                backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "control-pinned-\(palette.rawValue).png"))
            }
            for dark in [true, false] {
                let content = ControlPanel.picture(state, expanded: true)
                let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let backdrop = NSView(frame: content.frame)
                backdrop.wantsLayer = true
                backdrop.layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
                backdrop.addSubview(content)
                window.contentView = backdrop
                window.layoutIfNeeded()
                let bitmap = try #require(sharpBitmap(for: backdrop))
                backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: directory.appending(path: "settings-\(language.rawValue)\(dark ? "-dark" : "").png"))
            }
        }
        Strings.language = .auto
    }

    /// The card a click on a process row brings up, with sample figures.
    @Test(.enabled(if: renderDirectory != nil))
    func writeCardImage() throws {
        let directory = URL(fileURLWithPath: renderDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Strings.language = .en
        let card = ProcessCard(
            name: "Google Chrome", appPath: "/Applications/Google Chrome.app", cpu: "94", cpuShare: 0.42, memory: "1.0", memoryUnit: "G", memoryShare: 0.12,
            members: [
                .init(name: "Google Chrome Helper (Renderer)", value: "51", unit: "%"), .init(name: "Google Chrome Helper", value: "22", unit: "%"),
                .init(name: "Google Chrome", value: "14", unit: "%"), .init(name: "Google Chrome Helper (GPU)", value: "7", unit: "%"),
            ])
        let content = ProcessCardPicture.view(card)
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        let backdrop = NSView(frame: content.frame)
        backdrop.wantsLayer = true
        backdrop.addSubview(content)
        window.contentView = backdrop
        window.layoutIfNeeded()
        let bitmap = try #require(sharpBitmap(for: backdrop))
        backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "card.png"))
        Strings.language = .auto
    }

    static let demoSizes: [(Double, Double)] = [(96, 32), (400, 30), (270, 150), (300, 420), (480, 260), (660, 230), (860, 500), (1049, 500)]

    /// Sample readings for second `step`; the columns are `progress` (0...1) of the way
    /// from the previous second's values.
    /// With `period`, second `period` shows what second 0 does, so the frames loop.
    static func demoSnapshot(step: Int, progress: Double = 1, period: Int? = nil) -> Snapshot {
        func wrapped(_ step: Int) -> Int { period.map { ((step % $0) + $0) % $0 } ?? step }
        func usage(_ base: Double, _ index: Int, _ step: Int) -> Double {
            let t = Double(wrapped(step))
            return min(0.97, max(0.04, base + sin(t * 1.9 + Double(index) * 1.7) * 0.2 + sin(t * 0.8 + Double(index) * 0.6) * 0.1))
        }
        var snapshot = Snapshot.sample(performance: 10, efficiency: 4)
        guard var cpu = snapshot.cpu.value else { return snapshot }
        for index in cpu.cores.indices {
            let base = cpu.cores[index].usage
            let before = usage(base, index, step - 1)
            let value = before + (usage(base, index, step) - before) * progress
            cpu.cores[index].usage = value
            let efficiency = cpu.cores[index].group > 0
            cpu.cores[index].frequencyMHz = .value((efficiency ? 900 : 1000) + value * (efficiency ? 1600 : 3200))
        }
        snapshot.cpu = .value(cpu)
        let t = Double(wrapped(step))
        snapshot.network = .value(
            NetworkSample(downBytesPerSecond: 2_400_000 * (1.2 + sin(t * 1.3)), upBytesPerSecond: 188_000 * (1.3 + cos(t * 1.1))))
        return snapshot
    }

    @Test(.enabled(if: demoDirectory != nil))
    func writeDemoFrames() throws {
        let directory = URL(fileURLWithPath: demoDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (width, height) in demoSizeList ?? Self.demoSizes {
            for frame in 0..<demoFrameCount {
                let model = PanelModel()
                var config = Config()
                config.motion = false
                config.language = demoLanguage
                if let demoPalette { config.palette = demoPalette }
                model.apply(config)
                // The columns take 0.7 s of each second to reach the new value.
                let part = min(1, Double(frame % 15) / 15 / 0.7)
                let eased = 1 - pow(1 - part, 3)
                model.ingest(
                    Self.demoSnapshot(step: frame / 15, progress: demoFrameCount > 1 ? eased : 1, period: demoFrameCount > 15 ? demoFrameCount / 15 : nil))
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

                let scale = CGFloat(demoScale)
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(frameRect.width * scale), pixelsHigh: Int(frameRect.height * scale), bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                bitmap.size = frameRect.size
                backdrop.layer?.render(in: NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext)
                let name = (demoPalette.map { $0.rawValue + "-" } ?? "") + String(format: "%dx%d-%03d.png", Int(width), Int(height), frame)
                // Where the process rows are, for anything that animates them apart from the picture.
                if frame == 0 {
                    let scene = SceneBuilder(
                        snapshot: model.snapshot, machine: model.machine, modules: model.config.shown, style: model.style(scale: model.choice.scale)
                    ).build(model.choice)
                    let rows = (scene.processes.map { item in item.rows.indices.map { item.frame(at: $0).offsetBy(dx: item.rect.minX, dy: item.rect.minY) } } ?? [])
                        .map { [$0.minX, $0.minY, $0.width, $0.height] }
                    let facts: [String: Any] = ["width": frameRect.width, "height": frameRect.height, "rows": rows]
                    try JSONSerialization.data(withJSONObject: facts).write(to: directory.appending(path: name.replacingOccurrences(of: "-000.png", with: ".json")))
                }
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appending(path: name))
            }
        }
        Strings.language = .auto
    }
}
