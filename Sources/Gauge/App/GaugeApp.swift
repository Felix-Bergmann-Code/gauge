import AppKit

@main
enum GaugeMain {
    static func main() {
        if CommandLine.arguments.contains("--dump") { return dump() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = GaugeSettings.shared
    private let monitor = Monitor()
    private var items: [StatusItemController] = []
    private var itemsAreCombined: Bool?
    private var interval: Double = 0
    private var rotationTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.onSample = { [weak self] in
            self?.items.forEach { if $0.isVisible { $0.refresh() } }
        }
        settings.onChange = { [weak self] in
            DispatchQueue.main.async { self?.applySettings() }
        }
        applySettings()

        let rotation = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.items.forEach { $0.tick(rotation: self.settings.rotation) }
            }
        }
        rotation.tolerance = 0.1
        RunLoop.main.add(rotation, forMode: .common)
        rotationTimer = rotation

        // `--open <module>` shows that popover on launch (handy for screenshots and testing).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count, let module = Module(rawValue: args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.items.first { $0.modules.contains(module) }?.togglePopover(module)
            }
        }
    }

    /// One rotating item, or one item per module (created right-to-left, since new status
    /// items appear to the left of existing ones).
    private func rebuildItems() {
        items.forEach { $0.remove() }
        items = settings.combined
            ? [StatusItemController(kind: .rotating, monitor: monitor, settings: settings)]
            : Module.allCases.reversed().map { StatusItemController(kind: .single($0), monitor: monitor, settings: settings) }
        itemsAreCombined = settings.combined
    }

    private func applySettings() {
        if itemsAreCombined != settings.combined { rebuildItems() }
        for item in items {
            switch item.kind {
            case let .single(m): item.isVisible = settings.enabled.contains(m)
            case .rotating: item.isVisible = true
            }
            item.refresh()
        }
        if settings.interval != interval {
            interval = settings.interval
            monitor.start(interval: interval)
        }
    }
}

extension GaugeMain {
    /// `Gauge --dump`: prints two samples of every reading and exits. For checking sensors on a new Mac.
    static func dump() {
        let s = Samplers()
        let request = Samplers.Request(sensors: true, sensorDetails: true, battery: true, volumes: true, processes: true)
        _ = s.sample(request)
        Thread.sleep(forTimeInterval: 1)
        let r = s.sample(request)
        print("chip:", SysInfo.chip, "generation:", SysInfo.chipGeneration.map(String.init) ?? "?",
              "cores:", SysInfo.coreKinds.map { $0 == .efficiency ? "E" : "P" }.joined())
        print("cpu:", r.cpu)
        print("gpu:", r.gpu)
        print("memory:", r.memory, "used:", Fmt.memory(r.memory.used))
        print("network:", r.network)
        print("disk:", r.disk)
        print("volumes:", r.volumes ?? [])
        print("sensors:", r.sensors.map { String(describing: $0) } ?? "-")
        print("battery:", r.battery.map { String(describing: $0) } ?? "-")
        print("top cpu:", r.processes?.byCPU.map { "\($0.name) \($0.cpu)%" } ?? [])
        print("top mem:", r.processes?.byMemory.map { "\($0.name) \(Fmt.memory($0.memory))" } ?? [])
    }
}
