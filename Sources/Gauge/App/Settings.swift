import Combine
import Foundation
import ServiceManagement

enum Module: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, disk, network, sensors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .sensors: "Sensors"
        }
    }

    /// For the tab bar of the combined popover.
    var shortTitle: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "RAM"
        case .disk: "Disk"
        case .network: "Net"
        case .sensors: "Temp"
        }
    }

    static let defaults: Set<Module> = [.cpu, .memory, .network, .sensors]
}

enum CPUStyle: String, CaseIterable, Identifiable {
    case graph, cores, percent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .graph: "History graph"
        case .cores: "Per-core bars"
        case .percent: "Percentage only"
        }
    }
}

final class GaugeSettings: ObservableObject {
    static let shared = GaugeSettings()

    /// Called after any change; the app delegate re-applies status items and the timer.
    var onChange: (() -> Void)?
    private let store = UserDefaults.standard

    @Published var enabled: Set<Module> {
        didSet { store.set(enabled.map(\.rawValue), forKey: "enabled"); onChange?() }
    }
    /// One menu bar item that cycles through the enabled modules, instead of one item each.
    @Published var combined: Bool {
        didSet { store.set(combined, forKey: "combined"); onChange?() }
    }
    /// Seconds each module stays in the combined item; 0 = don't rotate.
    @Published var rotation: Double {
        didSet { store.set(rotation, forKey: "rotation"); onChange?() }
    }
    @Published var interval: Double {
        didSet { store.set(interval, forKey: "interval"); onChange?() }
    }
    @Published var cpuStyle: CPUStyle {
        didSet { store.set(cpuStyle.rawValue, forKey: "cpuStyle"); onChange?() }
    }
    @Published var colorful: Bool {
        didSet { store.set(colorful, forKey: "colorful"); onChange?() }
    }
    @Published var fahrenheit: Bool {
        didSet { store.set(fahrenheit, forKey: "fahrenheit"); onChange?() }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Gauge: launch at login failed: \(error)")
            }
        }
    }

    private init() {
        let saved = (store.array(forKey: "enabled") as? [String])?.compactMap(Module.init(rawValue:))
        enabled = saved.map(Set.init).flatMap { $0.isEmpty ? nil : $0 } ?? Module.defaults
        combined = store.object(forKey: "combined") as? Bool ?? true
        rotation = store.object(forKey: "rotation") as? Double ?? 5
        let i = store.double(forKey: "interval")
        interval = i > 0 ? i : 2
        cpuStyle = CPUStyle(rawValue: store.string(forKey: "cpuStyle") ?? "") ?? .graph
        colorful = store.object(forKey: "colorful") as? Bool ?? true
        fahrenheit = store.bool(forKey: "fahrenheit")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ module: Module, _ on: Bool) {
        if on { enabled.insert(module) } else if enabled.count > 1 { enabled.remove(module) }
    }
}
