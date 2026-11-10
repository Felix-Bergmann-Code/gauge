import AppKit
import SwiftUI

/// A menu bar item. Either shows one module, or (`.rotating`) cycles through all enabled
/// modules in a single fixed-width slot. Click opens the detail popover; in rotating mode
/// a right-click skips to the next module.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    enum Kind: Equatable {
        case single(Module)
        case rotating
    }

    let kind: Kind
    /// The module currently drawn in the menu bar.
    private(set) var current: Module
    private let item: NSStatusItem
    private let view = StatusView()
    private let popover = NSPopover()
    private let monitor: Monitor
    private let settings: GaugeSettings
    private var shownSince = Date()
    /// Text form of what was last drawn. Redrawing a status item is the costliest part of a tick
    /// (AppKit repeats it for every display's menu bar), so unchanged items are skipped.
    private var drawn = ""

    init(kind: Kind, monitor: Monitor, settings: GaugeSettings) {
        self.kind = kind
        self.monitor = monitor
        self.settings = settings
        switch kind {
        case let .single(m):
            current = m
        case .rotating:
            current = Module.allCases.first { settings.enabled.contains($0) } ?? .cpu
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Keeps ⌘-drag positions across launches.
        item.autosaveName = if case let .single(m) = kind { "gauge.\(m.rawValue)" } else { "gauge.combined" }
        super.init()

        if let button = item.button {
            view.frame = button.bounds
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(kind == .rotating ? "Gauge" : "Gauge \(current.title)")
        }
        popover.behavior = .transient
        popover.delegate = self
        refresh()
    }

    /// Modules this item can show.
    var modules: [Module] {
        switch kind {
        case let .single(m): [m]
        case .rotating: Module.allCases.filter { settings.enabled.contains($0) }
        }
    }

    var isVisible: Bool {
        get { item.isVisible }
        set { if item.isVisible != newValue { item.isVisible = newValue } }
    }

    func remove() {
        popover.close()
        NSStatusBar.system.removeStatusItem(item)
    }

    // MARK: - Rotation

    /// Called every second; moves on once the current module has been up for `rotation` seconds.
    func tick(rotation: TimeInterval) {
        guard kind == .rotating, rotation > 0, !popover.isShown,
              Date().timeIntervalSince(shownSince) >= rotation else { return }
        advance()
    }

    private func advance() {
        let list = modules
        guard list.count > 1 else { return }
        let next = list[((list.firstIndex(of: current) ?? -1) + 1) % list.count]
        show(next, animated: true)
    }

    private func show(_ module: Module, animated: Bool) {
        shownSince = Date()
        guard module != current else { return }
        current = module
        if animated { view.slideNextChange() }
        refresh()
    }

    // MARK: - Drawing

    func refresh() {
        let list = modules
        if !list.contains(current), let first = list.first { current = first }
        let content = content(for: current)
        // The rotating slot is as wide as its widest module, so neighbouring icons never shift.
        let width = kind == .rotating
            ? list.map { StatusView.width(of: self.content(for: $0)) }.max() ?? StatusView.width(of: content)
            : StatusView.width(of: content)
        let signature = "\(settings.colorful)\(width)\(content)"
        guard signature != drawn else { return }
        drawn = signature
        view.colorful = settings.colorful
        view.content = content
        if abs(item.length - width) > 0.5 { item.length = width }
    }

    // MARK: - Popover

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, kind == .rotating, !popover.isShown {
            advance()
        } else {
            togglePopover()
        }
    }

    /// Opens (or closes) the popover; `module` picks the tab to open on.
    func togglePopover(_ module: Module? = nil) {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if let module, modules.contains(module) { show(module, animated: false) }
        // The SwiftUI panel exists only while open, so closed panels cost nothing per sample.
        let panel = PanelView(modules: kind == .rotating ? modules : [current], selection: current,
                              monitor: monitor, settings: settings) { [weak self] newModule in
            self?.panelSwitched(to: newModule)
        }
        let host = NSHostingController(rootView: panel)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        monitor.panelOpened(current)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
    }

    /// A tab change in the combined popover: the menu bar follows, so closing the popover leaves
    /// the item on what you were just looking at.
    private func panelSwitched(to module: Module) {
        monitor.panelClosed(current)
        monitor.panelOpened(module)
        show(module, animated: false)
    }

    func popoverDidClose(_ notification: Notification) {
        item.button?.highlight(false)
        popover.contentViewController = nil
        monitor.panelClosed(current)
        shownSince = Date()
    }

    // MARK: - Content

    private func content(for module: Module) -> StatusContent {
        let m = monitor
        switch module {
        case .cpu:
            switch settings.cpuStyle {
            case .graph:
                return .graph(label: "CPU", value: Fmt.percent(m.cpu.total),
                              series: [m.cpuUser.suffix(26), m.cpuSystem.suffix(26)],
                              colors: [.systemBlue, .systemRed])
            case .cores:
                return .cores(m.cpu.cores, SysInfo.coreKinds)
            case .percent:
                return .pairs([("CPU", Fmt.percent(m.cpu.total), "100%")])
            }
        case .gpu:
            return .graph(label: "GPU", value: m.gpu.utilization.map(Fmt.percent) ?? "–",
                          series: [m.gpuHistory.suffix(26)], colors: [.systemPurple])
        case .memory:
            let color: NSColor = switch m.memory.pressure {
            case .normal: .systemGreen
            case .warning: .systemYellow
            case .critical: .systemRed
            }
            return .meter(label: "MEM", value: Fmt.percent(m.memory.usedFraction),
                          fraction: m.memory.usedFraction, color: color)
        case .disk:
            return .lines(top: "R " + Fmt.rate(m.disk.read), bottom: "W " + Fmt.rate(m.disk.write),
                          reference: "W 999 MB/s")
        case .network:
            return .lines(top: "↑ " + Fmt.rate(m.network.upload), bottom: "↓ " + Fmt.rate(m.network.download),
                          reference: "↓ 999 MB/s")
        case .sensors:
            var pairs: [(String, String, String)] = [
                ("TEMP", m.sensors.cpu.map { Fmt.temperature($0, fahrenheit: settings.fahrenheit) } ?? "–", "100°"),
            ]
            if let fan = m.sensors.fans.max(by: { $0.rpm < $1.rpm }), fan.isSpinning {
                pairs.append(("FAN", "\(Int(fan.rpm))", "8888"))
            }
            return .pairs(pairs)
        }
    }
}
