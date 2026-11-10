import Foundation
import Observation

struct History {
    static let capacity = 90
    private(set) var values: [Double] = []

    mutating func push(_ v: Double) {
        values.append(v)
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
    }

    var peak: Double { values.max() ?? 0 }
    func suffix(_ n: Int) -> [Double] { Array(values.suffix(n)) }
}

/// Holds the latest readings and their history. Sampling runs on a background queue;
/// results are applied on the main thread so SwiftUI and the status items see them together.
@Observable @MainActor
final class Monitor {
    private(set) var cpu = CPUReading()
    private(set) var cpuUser = History()
    private(set) var cpuSystem = History()
    private(set) var gpu = GPUReading()
    private(set) var gpuHistory = History()
    private(set) var memory = MemoryReading()
    private(set) var memoryHistory = History()
    private(set) var network = NetworkReading()
    private(set) var downloadHistory = History()
    private(set) var uploadHistory = History()
    private(set) var disk = DiskReading()
    private(set) var readHistory = History()
    private(set) var writeHistory = History()
    private(set) var volumes: [Volume] = []
    private(set) var sensors = SensorReading()
    private(set) var cpuTempHistory = History()
    private(set) var battery: BatteryReading?
    private(set) var topCPU: [ProcRow] = []
    private(set) var topMemory: [ProcRow] = []

    @ObservationIgnored var onSample: (@MainActor () -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "io.github.felix-bergmann-code.gauge.sampler", qos: .utility)
    @ObservationIgnored private let samplers = Samplers()
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var openPanels: Set<Module> = []

    func start(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if Demo.isEnabled, cpuUser.values.isEmpty { prefillDemoHistory() }
        sample()
    }

    private func prefillDemoHistory() {
        func fill(_ h: inout History, _ values: [Double]) { values.forEach { h.push($0) } }
        fill(&cpuUser, Demo.series(base: 0.22, swing: 0.12, noise: 0.05))
        fill(&cpuSystem, Demo.series(base: 0.08, swing: 0.04, noise: 0.02, phase: 1))
        fill(&gpuHistory, Demo.series(base: 0.18, swing: 0.12, noise: 0.05, phase: 2))
        fill(&memoryHistory, Demo.series(base: 0.62, swing: 0.03, noise: 0.005))
        fill(&downloadHistory, Demo.series(base: 900_000, swing: 700_000, noise: 250_000, phase: 3))
        fill(&uploadHistory, Demo.series(base: 120_000, swing: 90_000, noise: 40_000, phase: 4))
        fill(&readHistory, Demo.series(base: 6_000_000, swing: 5_000_000, noise: 2_000_000, phase: 5))
        fill(&writeHistory, Demo.series(base: 2_500_000, swing: 2_000_000, noise: 800_000, phase: 6))
        fill(&cpuTempHistory, Demo.series(base: 49, swing: 4, noise: 0.6, phase: 7))
    }

    func panelOpened(_ module: Module) {
        openPanels.insert(module)
        if module != .network { sample() }
    }

    func panelClosed(_ module: Module) {
        openPanels.remove(module)
        if openPanels.isDisjoint(with: [.cpu, .memory]) {
            topCPU = []
            topMemory = []
        }
    }

    private func sample() {
        guard !inFlight else { return }
        inFlight = true
        tick += 1
        let request = Samplers.Request(
            sensors: tick % 2 == 1 || openPanels.contains(.sensors),
            sensorDetails: openPanels.contains(.sensors),
            battery: tick % 5 == 1 || openPanels.contains(.sensors),
            volumes: tick % 30 == 1 || openPanels.contains(.disk),
            processes: !openPanels.isDisjoint(with: [.cpu, .memory])
        )
        let samplers = samplers
        queue.async { [weak self] in
            let snapshot = samplers.sample(request)
            DispatchQueue.main.async {
                self?.apply(snapshot)
            }
        }
    }

    private func apply(_ s: Samplers.Snapshot) {
        var s = s
        if Demo.isEnabled {
            if s.processes != nil { s.processes = Demo.processes() }
            if s.network.ipv4 != nil { s.network.ipv4 = Demo.ipv4 }
            Demo.fakeTraffic(&s.network)
            s.volumes = s.volumes.map(Demo.volumes)
        }
        inFlight = false
        cpu = s.cpu
        cpuUser.push(s.cpu.user)
        cpuSystem.push(s.cpu.system)
        gpu = s.gpu
        gpuHistory.push(s.gpu.utilization ?? 0)
        memory = s.memory
        memoryHistory.push(s.memory.usedFraction)
        network = s.network
        downloadHistory.push(s.network.download)
        uploadHistory.push(s.network.upload)
        disk = s.disk
        readHistory.push(s.disk.read)
        writeHistory.push(s.disk.write)
        if let v = s.volumes, v != volumes { volumes = v }
        if let sensors = s.sensors {
            self.sensors = sensors
            if let t = sensors.cpu { cpuTempHistory.push(t) }
        }
        if let b = s.battery { battery = b }
        if let p = s.processes, !openPanels.isDisjoint(with: [.cpu, .memory]) {
            topCPU = p.byCPU
            topMemory = p.byMemory
        }
        onSample?()
    }
}

/// Owns the stateful samplers. Only ever touched from the monitor's serial queue.
final class Samplers: @unchecked Sendable {
    struct Request {
        var sensors: Bool
        var sensorDetails: Bool
        var battery: Bool
        var volumes: Bool
        var processes: Bool
    }

    struct Snapshot {
        var cpu: CPUReading
        var gpu: GPUReading
        var memory: MemoryReading
        var network: NetworkReading
        var disk: DiskReading
        var volumes: [Volume]?
        var sensors: SensorReading?
        var battery: BatteryReading??
        var processes: (byCPU: [ProcRow], byMemory: [ProcRow])?
    }

    private let cpu = CPUSampler()
    private let gpu = GPUSampler()
    private let network = NetworkSampler()
    private let disk = DiskSampler()
    private lazy var sensors = SensorSampler()
    private let processes = ProcessSampler()

    func sample(_ r: Request) -> Snapshot {
        Snapshot(
            cpu: cpu.sample(),
            gpu: gpu.sample(),
            memory: MemorySampler.sample(),
            network: network.sample(),
            disk: disk.sample(),
            volumes: r.volumes ? DiskSampler.volumes() : nil,
            sensors: r.sensors ? sensors.sample(detailed: r.sensorDetails) : nil,
            battery: r.battery ? .some(BatterySampler.sample()) : nil,
            processes: r.processes ? processes.sample() : nil
        )
    }
}
