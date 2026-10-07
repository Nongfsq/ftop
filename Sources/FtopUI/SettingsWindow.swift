import AppKit
import FtopCore

/// The settings window: every setting of the settings file as a standard control.
/// A change is written to the file and applied at once; there is no Save button.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Called with the new settings and the one `key: value` line that changed.
    public var onChange: ((Config, String, String) -> Void)?
    public var onOpenFile: (() -> Void)?
    public var onCheckUpdate: (() -> Void)?

    private var config: Config
    private var window: NSWindow?
    private var updateStatus = ""
    private var updateAction = ""
    private weak var updateLabel: NSTextField?
    private weak var updateButton: NSButton?

    private static let intervals: [Double] = [0.5, 1, 2, 5, 10]
    private static let rowCounts = [3, 5, 7, 9, 12, 16, 24]
    private static let optionalModules: [ModuleID] = [.memory, .network, .processes]

    public init(config: Config) {
        self.config = config
    }

    public func show(config: Config) {
        self.config = config
        if window == nil { window = makeWindow() }
        window?.contentView = makeContent()
        // The panel app has no Dock icon, so it must step forward to show a normal window.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Reflects a change made elsewhere: the menu, the pin button, or the file.
    public func refresh(config: Config) {
        guard config != self.config, let window, window.isVisible else { return }
        self.config = config
        window.contentView = makeContent()
    }

    /// The installed version and what the last check for a newer one found.
    /// `action` names the button: check, or install what was found.
    public func setUpdateStatus(_ text: String, action: String) {
        updateStatus = text
        updateAction = action
        updateLabel?.stringValue = text
        updateButton?.title = action
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = Strings.pick("ftop Settings", "ftop 设置")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    // MARK: Controls

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private func popup(_ titles: [String], selected: Int, action: Selector) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: titles)
        button.selectItem(at: max(0, selected))
        button.target = self
        button.action = action
        return button
    }

    private func checkbox(_ title: String, on: Bool, action: Selector, tag: Int = 0) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = on ? .on : .off
        button.tag = tag
        return button
    }

    func makeContent() -> NSView {
        let palettes = PaletteID.allCases
        let languages: [(Language, String)] = [(.auto, Strings.pick("Follow System", "跟随系统")), (.en, "English"), (.zh, "中文")]
        let nearestInterval = Self.intervals.enumerated().min { abs($0.element - config.interval) < abs($1.element - config.interval) }!.offset
        let nearestRows = Self.rowCounts.lastIndex { $0 <= config.maxProcesses } ?? 0

        let show = NSStackView(
            views: Self.optionalModules.enumerated().map { index, module in
                checkbox(Self.name(of: module), on: config.modules.contains(module), action: #selector(moduleChanged(_:)), tag: index)
            })
        show.orientation = .vertical
        show.alignment = .leading
        show.spacing = 6

        let file = NSButton(title: Strings.pick("Open Settings File…", "打开设置文件…"), target: self, action: #selector(openFile))
        file.bezelStyle = .rounded

        let modes = UpdateMode.allCases
        let modeNames = modes.map { mode in
            switch mode {
            case .install: Strings.pick("Install Automatically", "自动安装")
            case .check: Strings.pick("Check Only", "仅检查")
            case .off: Strings.pick("Off", "关闭")
            }
        }
        let check = NSButton(title: updateAction, target: self, action: #selector(checkUpdate))
        check.bezelStyle = .rounded
        check.controlSize = .small
        let status = NSTextField(labelWithString: updateStatus)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        updateLabel = status
        updateButton = check
        let update = NSStackView(views: [check, status])
        update.spacing = 8

        let rows: [[NSView]] = [
            [
                label(Strings.pick("Colors:", "配色：")),
                popup(palettes.map(\.displayName), selected: palettes.firstIndex(of: config.palette) ?? 0, action: #selector(paletteChanged(_:))),
            ],
            [
                label(Strings.pick("Language:", "语言：")),
                popup(languages.map(\.1), selected: languages.firstIndex { $0.0 == config.language } ?? 0, action: #selector(languageChanged(_:))),
            ],
            [
                label(Strings.pick("Update every:", "刷新间隔：")),
                popup(Self.intervals.map { Strings.pick("\(Self.trim($0)) s", "\(Self.trim($0)) 秒") }, selected: nearestInterval, action: #selector(intervalChanged(_:))),
            ],
            [label(Strings.pick("Process rows, up to:", "进程行数上限：")), popup(Self.rowCounts.map(String.init), selected: nearestRows, action: #selector(rowsChanged(_:)))],
            [label(Strings.pick("Show:", "显示：")), show],
            [label(Strings.pick("Window:", "窗口：")), checkbox(Strings.pick("Keep on top", "置顶"), on: config.floating, action: #selector(floatingChanged(_:)))],
            [NSGridCell.emptyContentView, checkbox(Strings.pick("Show CPU in the menu bar", "在菜单栏显示 CPU"), on: config.menuBar, action: #selector(menuBarChanged(_:)))],
            [NSGridCell.emptyContentView, checkbox(Strings.pick("Smooth column motion", "柱子平滑过渡"), on: config.motion, action: #selector(motionChanged(_:)))],
            [label(Strings.pick("Updates:", "更新：")), popup(modeNames, selected: modes.firstIndex(of: config.updates) ?? 0, action: #selector(updatesChanged(_:)))],
            [NSGridCell.emptyContentView, update],
            [NSGridCell.emptyContentView, file],
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 4).rowAlignment = .none
        grid.row(at: 4).yPlacement = .top
        grid.row(at: 5).topPadding = 6
        grid.row(at: 8).topPadding = 6
        grid.row(at: 10).topPadding = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
        ])
        return content
    }

    private static func name(of module: ModuleID) -> String {
        switch module {
        case .cpu: "CPU"
        case .memory: Strings.pick("Memory", "内存")
        case .network: Strings.pick("Network", "网络")
        case .processes: Strings.pick("Processes", "进程")
        }
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: Changes

    private func commit(_ key: String, _ value: String) {
        onChange?(config, key, value)
    }

    @objc private func paletteChanged(_ sender: NSPopUpButton) {
        config.palette = PaletteID.allCases[sender.indexOfSelectedItem]
        commit("palette", "\"\(config.palette.rawValue)\"")
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        config.language = [Language.auto, .en, .zh][sender.indexOfSelectedItem]
        commit("language", "\"\(config.language.rawValue)\"")
        // The window's own labels are in the old language until rebuilt.
        Strings.language = config.language
        window?.title = Strings.pick("ftop Settings", "ftop 设置")
        window?.contentView = makeContent()
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        config.interval = Self.intervals[sender.indexOfSelectedItem]
        commit("interval", Self.trim(config.interval))
    }

    @objc private func rowsChanged(_ sender: NSPopUpButton) {
        config.maxProcesses = Self.rowCounts[sender.indexOfSelectedItem]
        commit("maxProcesses", String(config.maxProcesses))
    }

    @objc private func moduleChanged(_ sender: NSButton) {
        let module = Self.optionalModules[sender.tag]
        var shown = Set(config.modules)
        if sender.state == .on { shown.insert(module) } else { shown.remove(module) }
        shown.insert(.cpu)
        // Keep the order the user wrote in the file; a module switched back on goes last.
        var modules = config.modules.filter(shown.contains)
        modules += ModuleID.allCases.filter { shown.contains($0) && !modules.contains($0) }
        config.modules = modules
        commit("modules", "[" + modules.map { "\"\($0.rawValue)\"" }.joined(separator: ", ") + "]")
    }

    @objc private func floatingChanged(_ sender: NSButton) {
        config.floating = sender.state == .on
        commit("floating", config.floating ? "true" : "false")
    }

    @objc private func menuBarChanged(_ sender: NSButton) {
        config.menuBar = sender.state == .on
        commit("menuBar", config.menuBar ? "true" : "false")
    }

    @objc private func motionChanged(_ sender: NSButton) {
        config.motion = sender.state == .on
        commit("motion", config.motion ? "true" : "false")
    }

    @objc private func updatesChanged(_ sender: NSPopUpButton) {
        config.updates = UpdateMode.allCases[sender.indexOfSelectedItem]
        commit("updates", "\"\(config.updates.rawValue)\"")
    }

    @objc private func checkUpdate() { onCheckUpdate?() }
    @objc private func openFile() { onOpenFile?() }
}
