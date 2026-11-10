import Foundation

struct Fan: Identifiable, Equatable {
    let id: Int
    let rpm: Double
    let min: Double
    let max: Double
    var fraction: Double { max > min ? Swift.max(0, Swift.min(1, (rpm - min) / (max - min))) : 0 }
    var isSpinning: Bool { rpm > 1 }
}

struct SensorReading {
    var cpu: Double?
    var cpuHottest: Double?
    var efficiencyCores: Double?
    var performanceCores: Double?
    var gpu: Double?
    var ssd: Double?
    var battery: Double?
    var fans: [Fan] = []
    var systemPower: Double? // watts
}

final class SensorSampler {
    private let smc = SMC()
    private let hid = HIDTemperatures()
    private lazy var keys = Self.keyTable()

    /// `detailed` adds the HID sensors (SSD, battery gauge). Reading those costs ~7 ms of CPU,
    /// so it's done only while the Sensors panel is open, or when SMC has no CPU temperature.
    func sample(detailed: Bool) -> SensorReading {
        var r = SensorReading()

        if let smc {
            let e = keys.efficiency.compactMap(validTemp)
            let p = keys.performance.compactMap(validTemp)
            let all = e + p
            if !all.isEmpty {
                r.cpu = all.reduce(0, +) / Double(all.count)
                r.cpuHottest = all.max()
            }
            if !e.isEmpty { r.efficiencyCores = e.reduce(0, +) / Double(e.count) }
            if !p.isEmpty { r.performanceCores = p.reduce(0, +) / Double(p.count) }
            let g = keys.gpu.compactMap(validTemp)
            if !g.isEmpty { r.gpu = g.reduce(0, +) / Double(g.count) }
            r.battery = validTemp("TB0T")

            let fanCount = Int(smc.value("FNum") ?? 0)
            r.fans = (0..<min(fanCount, 4)).compactMap { i in
                guard let rpm = smc.value("F\(i)Ac") else { return nil }
                return Fan(id: i, rpm: max(0, rpm), min: smc.value("F\(i)Mn") ?? 0, max: smc.value("F\(i)Mx") ?? 0)
            }
            if let watts = smc.value("PSTR"), watts > 0, watts < 1000 { r.systemPower = watts }
        }

        guard detailed || r.cpu == nil else { return r }
        let hidValues = hid.read()
        // Chips without a key table (or Macs where SMC is closed): fall back to the PMU die sensors.
        if r.cpu == nil {
            let dies = hidValues.filter { $0.key.contains("tdie") }.flatMap(\.value)
            if !dies.isEmpty {
                r.cpu = dies.reduce(0, +) / Double(dies.count)
                r.cpuHottest = dies.max()
            }
        }
        if let nand = hidValues.first(where: { $0.key.hasPrefix("NAND") })?.value, !nand.isEmpty {
            r.ssd = nand.max()
        }
        if r.battery == nil, let gauge = hidValues["gas gauge battery"], !gauge.isEmpty {
            r.battery = gauge.reduce(0, +) / Double(gauge.count)
        }
        return r
    }

    /// Keys of a power-gated cluster report constant junk (4–7 °C on an M2 Pro), so anything
    /// below room temperature is treated as "no reading".
    private func validTemp(_ key: String) -> Double? {
        guard let v = smc?.value(key), v > 15, v < 130 else { return nil }
        return v
    }

    /// SMC temperature keys per Apple Silicon generation. Keys missing on a given Mac are skipped.
    private static func keyTable() -> (efficiency: [String], performance: [String], gpu: [String]) {
        switch SysInfo.chipGeneration {
        case 1:
            return (["Tp09", "Tp0T"],
                    ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
                    ["Tg05", "Tg0D", "Tg0L", "Tg0T"])
        case 2:
            return (["Tp1h", "Tp1t", "Tp1p", "Tp1l"],
                    ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
                    ["Tg0f", "Tg0j"])
        case 3:
            return (["Te05", "Te0L", "Te0P", "Te0S"],
                    ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
                    ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"])
        case 4:
            return (["Te05", "Te0S", "Te09", "Te0H"],
                    ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
                    ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])
        default:
            return ([], [], [])
        }
    }
}
