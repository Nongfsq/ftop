import AppKit
import FtopCore
import FtopSensors
import FtopUI
import SwiftUI
import os

let log = Logger(subsystem: "dev.ftop", category: "lifecycle")

/// A panel that never takes focus from the app you are working in but still accepts
/// clicks, drags, and edge resizing.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum SamplingMode { case off, usageOnly, full }
    /// Which edges stay put when the window snaps to its layout.
    private struct Anchor {
        var right: Bool
        var top: Bool
    }

    private let model = PanelModel()
    private let sampler = SystemSampler()
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var snapWork: DispatchWorkItem?
    private var samplingMode = SamplingMode.off
    private var resizeStart: NSRect?
    /// True while the window is springing to its layout; nothing else may move it then.
    private var settling = false
    private var statusText = ""
    private var statusTick = 0

    static let margin: CGFloat = 14
    static let defaultSize = NSSize(width: 300, height: 420)
    static let choiceKey = "layoutChoice"
    static let machineKey = "machineShape"

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.apply(ConfigStore.load())
        restoreMachineShape()
        buildPanel()
        updateStatusItem()
        observeEnvironment()
        watchConfig()
        updateMotion()
        model.render()
        panel.orderFrontRegardless()
        updateSampling()
    }

    /// Layout sizes depend on the core counts, so they must be known before the window
    /// is sized. They are remembered between launches; the first launch reads them.
    private func restoreMachineShape() {
        if let data = UserDefaults.standard.data(forKey: Self.machineKey), let shape = try? JSONDecoder().decode(MachineShape.self, from: data) {
            model.setMachine(shape)
            return
        }
        _ = sampler.sampleNow()
        Thread.sleep(forTimeInterval: 0.08)
        if model.ingest(sampler.sampleNow()) { saveMachineShape() }
    }

    private func saveMachineShape() {
        UserDefaults.standard.set(try? JSONEncoder().encode(model.machine), forKey: Self.machineKey)
    }

    // MARK: Window

    private func buildPanel() {
        let frame = NSRect(origin: .zero, size: Self.defaultSize)
        panel = FloatingPanel(
            contentRect: frame,
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        applyFloating()

        // The system material gives the translucent "glass" look and follows light and dark.
        let glass = NSVisualEffectView(frame: frame)
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        let canvas = model.canvas
        canvas.frame = frame
        canvas.autoresizingMask = [.width, .height]
        canvas.onTogglePin = { [weak self] in self?.toggleFloating() }
        canvas.onHide = { [weak self] in self?.hidePanel() }
        canvas.menu = buildMenu()
        glass.addSubview(canvas)
        panel.contentView = glass
        applyMinimumSize()

        // First launch: top-right corner of the main screen. Later launches restore the saved frame.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - frame.width - Self.margin, y: visible.maxY - frame.height - Self.margin))
        }
        panel.setFrameAutosaveName("FtopPanel")
        pullOnScreen()

        // Back to the layout it had, or the best one for the restored size.
        if let data = UserDefaults.standard.data(forKey: Self.choiceKey), let saved = try? JSONDecoder().decode(LayoutChoice.self, from: data),
            model.offers(saved.candidate), saved.scale >= LayoutLadder.minimumMicroScale, saved.scale <= LayoutLadder.maximumScale
        {
            model.setChoice(saved)
        } else {
            model.setChoice(PanelModel.firstChoice)
        }
        hug(keeping: nearestCorner(), animated: false)
    }

    private func applyMinimumSize() {
        panel.contentMinSize = model.size(of: LayoutChoice(candidate: LayoutCandidate(tier: .micro), scale: LayoutLadder.minimumMicroScale))
    }

    private func applyFloating() {
        panel.level = model.config.floating ? .floating : .normal
    }

    /// The window corner closest to a screen corner; snapping keeps it in place.
    private func nearestCorner() -> Anchor {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return Anchor(right: true, top: true) }
        return Anchor(right: panel.frame.midX > visible.midX, top: panel.frame.midY > visible.midY)
    }

    /// Sizes the window to exactly fit the chosen layout.
    private func hug(keeping anchor: Anchor, animated: Bool) {
        let size = model.hugSize
        let old = panel.frame
        let frame = NSRect(
            x: anchor.right ? old.maxX - size.width : old.minX, y: anchor.top ? old.maxY - size.height : old.minY,
            width: size.width, height: size.height)
        guard frame != old else { return }
        if animated, model.config.motion, model.motionAllowed {
            settling = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                // Slightly past the target and back: the window settles like a spring.
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1.25, 0.45, 1)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.settling = false
                    self?.snapToMargins()
                }
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(model.choice), forKey: Self.choiceKey)
    }

    /// Picks the layout again after something that changes layout sizes, keeping the
    /// current one where it is still offered.
    private func relayout() {
        applyMinimumSize()
        if !model.offers(model.choice.candidate) { model.setChoice(model.choice(for: panel.frame.size)) }
        model.render()
        hug(keeping: nearestCorner(), animated: false)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        resizeStart = panel.frame
        model.canvas.dismissHover()
    }

    /// While an edge is dragged the panel shows the layout it will snap to.
    func windowDidResize(_ notification: Notification) {
        guard panel.inLiveResize else { return }
        let choice = model.choice(for: panel.frame.size, coarse: true)
        if choice != model.choice { model.setChoice(choice) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        Typesetter.trim()
        model.setChoice(model.choice(for: panel.frame.size))
        // The edges the user did not drag stay where they are.
        var anchor = nearestCorner()
        if let start = resizeStart {
            let end = panel.frame
            if abs(end.minX - start.minX) > 0.5 { anchor.right = true } else if abs(end.maxX - start.maxX) > 0.5 { anchor.right = false }
            if abs(end.minY - start.minY) > 0.5 { anchor.top = true } else if abs(end.maxY - start.maxY) > 0.5 { anchor.top = false }
        }
        resizeStart = nil
        hug(keeping: anchor, animated: true)
    }

    /// After a move settles, snap to the screen margins when close to them.
    func windowDidMove(_ notification: Notification) {
        snapWork?.cancel()
        // Resizing from the left or bottom edge also moves the window; that is not a drag.
        guard !settling, !panel.inLiveResize else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.snapToMargins() }
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func snapToMargins() {
        guard NSEvent.pressedMouseButtons == 0, !panel.inLiveResize, !settling, let visible = panel.screen?.visibleFrame else { return }
        var frame = panel.frame
        let reach: CGFloat = 12
        let targets: [(CGFloat, WritableKeyPath<NSRect, CGFloat>)] = [
            (visible.minX + Self.margin, \.origin.x), (visible.maxX - Self.margin - frame.width, \.origin.x),
            (visible.minY + Self.margin, \.origin.y), (visible.maxY - Self.margin - frame.height, \.origin.y),
        ]
        for (target, keyPath) in targets where abs(frame[keyPath: keyPath] - target) < reach {
            frame[keyPath: keyPath] = target
        }
        guard frame != panel.frame else { return }
        // Not `setFrame(_:display:animate:)`: that blocks until the animation ends, which
        // stalls a drag begun in the meantime.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func pullOnScreen() {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard !screens.contains(where: { $0.intersects(panel.frame.insetBy(dx: 20, dy: 10)) }), let visible = NSScreen.main?.visibleFrame else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - frame.width - Self.margin, y: visible.maxY - frame.height - Self.margin))
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateSampling()
    }

    // MARK: Sampling

    private var panelShowing: Bool { panel.isVisible && panel.occlusionState.contains(.visible) }

    /// Reads everything while the panel can be seen, only CPU usage while just the menu
    /// bar number shows, and nothing otherwise.
    private func updateSampling(restart: Bool = false) {
        let wanted: SamplingMode = panelShowing ? .full : (statusItem != nil ? .usageOnly : .off)
        guard wanted != samplingMode || restart else { return }
        samplingMode = wanted
        log.info(
            "sampling \(String(describing: wanted), privacy: .public): window shown \(self.panel.isVisible), seen \(self.panel.occlusionState.contains(.visible)), on active space \(self.panel.isOnActiveSpace)"
        )
        guard wanted != .off else {
            sampler.stop()
            return
        }
        sampler.start(interval: model.config.interval, modules: model.config.modules, usageOnly: wanted == .usageOnly) { [weak self] snapshot in
            Task { @MainActor in self?.ingest(snapshot) }
        }
    }

    private func ingest(_ snapshot: Snapshot) {
        // A usage-only reading has no frequencies or processes; it is for the menu bar alone.
        if samplingMode == .full {
            if model.ingest(snapshot) {
                saveMachineShape()
                relayout()
            } else {
                model.render()
            }
        }
        // The menu bar redraws through the system's status item machinery, which costs
        // more than drawing the whole panel; every other sample is enough for one number.
        statusTick += 1
        if statusTick % 2 == 0, let cpu = snapshot.cpu.value { setStatusText(Format.percent(cpu.usage) + "%") }
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        if model.config.menuBar, statusItem == nil {
            // "CPU" in front: a bare number in the menu bar says nothing about what it measures.
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let width = ceil((Self.statusTitle("100%") as NSString).size(withAttributes: [.font: font]).width) + 14
            let item = NSStatusBar.system.statusItem(withLength: width)
            item.button?.font = font
            item.button?.title = Self.statusTitle(statusText.isEmpty ? "–%" : statusText)
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        } else if !model.config.menuBar, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private static func statusTitle(_ percent: String) -> String { "CPU " + percent }

    private func setStatusText(_ text: String) {
        guard text != statusText else { return }
        statusText = text
        statusItem?.button?.title = Self.statusTitle(text)
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent, let button = statusItem?.button else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            buildMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
        } else if panelShowing {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: Settings

    private var settings: SettingsWindowController?

    private func apply(_ config: Config) {
        let needsRestart = config.interval != model.config.interval || config.modules != model.config.modules
        let layoutChanged = model.apply(config)
        applyFloating()
        updateStatusItem()
        model.canvas.menu = buildMenu()
        settings?.refresh(config: config)
        if layoutChanged { relayout() } else { model.render() }
        updateSampling(restart: needsRestart)
    }

    private func watchConfig() {
        ConfigStore.ensureFileExists()
        configWatcher?.cancel()
        let descriptor = Darwin.open(Config.fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Editors often replace the file; reload, then watch the new one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated {
                        self.apply(ConfigStore.load(fallback: self.model.config))
                        self.watchConfig()
                    }
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        configWatcher = source
    }

    private func updateMotion() {
        model.motionAllowed = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func observeEnvironment() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(environmentChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(environmentChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        center.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let remote = DistributedNotificationCenter.default()
        remote.addObserver(self, selector: #selector(showPanel), name: Notification.Name("dev.ftop.app.show"), object: nil)
        remote.addObserver(self, selector: #selector(togglePanel), name: Notification.Name("dev.ftop.app.toggle"), object: nil)
        remote.addObserver(self, selector: #selector(quit), name: Notification.Name("dev.ftop.app.quit"), object: nil)
        remote.addObserver(self, selector: #selector(resize(_:)), name: Notification.Name("dev.ftop.app.size"), object: nil)
    }

    @objc private func environmentChanged() { updateMotion() }
    @objc private func screensChanged() { pullOnScreen() }
    /// Counters jump across sleep; restart so the first sample after wake is a clean baseline.
    @objc private func didWake() { updateSampling(restart: true) }

    // MARK: Commands

    @objc private func showPanel() {
        pullOnScreen()
        panel.orderFrontRegardless()
        updateSampling()
    }

    @objc private func hidePanel() {
        model.canvas.dismissHover()
        panel.orderOut(nil)
        updateSampling()
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// `ftop size 300x420`: the layout for that size, keeping the top-right corner in place.
    @objc private func resize(_ notification: Notification) {
        guard let parts = (notification.object as? String)?.split(separator: "x").compactMap({ Double($0) }), parts.count == 2 else { return }
        model.setChoice(model.choice(for: CGSize(width: parts[0], height: parts[1])))
        hug(keeping: Anchor(right: true, top: true), animated: false)
        pullOnScreen()
    }

    @objc private func choosePalette(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let palette = PaletteID(rawValue: raw) else { return }
        var config = model.config
        config.palette = palette
        ConfigStore.update(key: "palette", value: "\"\(palette.rawValue)\"")
        apply(config)
    }

    @objc private func toggleFloating() {
        var config = model.config
        config.floating.toggle()
        ConfigStore.update(key: "floating", value: config.floating ? "true" : "false")
        apply(config)
    }

    @objc private func toggleMenuBar() {
        var config = model.config
        config.menuBar.toggle()
        ConfigStore.update(key: "menuBar", value: config.menuBar ? "true" : "false")
        apply(config)
    }

    @objc private func openSettings() {
        if settings == nil {
            let controller = SettingsWindowController(config: model.config)
            controller.onChange = { [weak self] config, key, value in
                ConfigStore.update(key: key, value: value)
                self?.apply(config)
            }
            controller.onOpenFile = { [weak self] in self?.openConfig() }
            settings = controller
        }
        settings?.show(config: model.config)
    }

    @objc private func openConfig() {
        ConfigStore.ensureFileExists()
        // No app claims `.json5` on a fresh Mac, and macOS would ask the user to pick one.
        if NSWorkspace.shared.urlForApplication(toOpen: Config.fileURL) != nil {
            NSWorkspace.shared.open(Config.fileURL)
        } else {
            let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            NSWorkspace.shared.open([Config.fileURL], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, checked: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = checked ? .on : .off
            menu.addItem(item)
            return item
        }
        if panel?.isVisible == true {
            _ = add(Strings.pick("Hide Panel", "收起面板"), #selector(hidePanel))
        } else {
            _ = add(Strings.pick("Show Panel", "显示面板"), #selector(showPanel))
        }
        _ = add(Strings.pick("Keep on Top", "置顶"), #selector(toggleFloating), checked: model.config.floating)
        _ = add(Strings.pick("Show in Menu Bar", "在菜单栏显示"), #selector(toggleMenuBar), checked: model.config.menuBar)
        menu.addItem(.separator())
        for palette in PaletteID.allCases {
            let item = add(palette.displayName, #selector(choosePalette(_:)), checked: palette == model.config.palette)
            item.representedObject = palette.rawValue
        }
        menu.addItem(.separator())
        _ = add(Strings.pick("Settings…", "设置…"), #selector(openSettings))
        menu.addItem(.separator())
        _ = add(Strings.pick("Quit ftop", "退出 ftop"), #selector(quit))
        return menu
    }
}

/// Reads and edits the user's settings file.
enum ConfigStore {
    static func ensureFileExists() {
        let url = Config.fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(Config.template.utf8).write(to: url)
    }

    /// A missing file gives defaults; an invalid file keeps `fallback` and logs why.
    static func load(fallback: Config = Config()) -> Config {
        guard let data = try? Data(contentsOf: Config.fileURL) else { return Config() }
        do {
            return try Config.decode(data)
        } catch {
            Logger(subsystem: "dev.ftop", category: "config").error("config.json5 is invalid, keeping previous settings: \(String(describing: error), privacy: .public)")
            return fallback
        }
    }

    /// Rewrites one `key: value` line in place so the user's comments survive.
    static func update(key: String, value: String) {
        ensureFileExists()
        guard var text = try? String(contentsOf: Config.fileURL, encoding: .utf8) else { return }
        // The value is a bracketed list or everything up to the comma.
        let pattern = "(?m)^(\\s*\"?\(key)\"?\\s*:\\s*)(?:\\[[^\\]\\n]*\\]|[^,\\n]*)(,?)"
        if let range = text.range(of: pattern, options: .regularExpression) {
            let line = String(text[range])
            let prefix = line[..<(line.range(of: ":")!.upperBound)]
            text.replaceSubrange(range, with: "\(prefix) \(value)\(line.hasSuffix(",") ? "," : "")")
        } else if let brace = text.range(of: "}", options: .backwards) {
            text.replaceSubrange(brace, with: "  \(key): \(value),\n}")
        }
        try? Data(text.utf8).write(to: Config.fileURL)
    }
}

// A second launch hands over to the running panel instead of opening another.
if let identifier = Bundle.main.bundleIdentifier,
    NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1
{
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("dev.ftop.app.show"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
