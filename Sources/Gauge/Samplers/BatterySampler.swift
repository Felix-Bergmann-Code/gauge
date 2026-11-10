import Foundation
import IOKit

struct BatteryReading {
    var percent: Double = 0
    var isCharging = false
    var isPluggedIn = false
    var isFull = false
    var minutesRemaining: Int?
    var cycles: Int?
    var health: Double?
    /// Watts flowing into (+) or out of (−) the battery.
    var power: Double?
    var adapterWatts: Int?
}

enum BatterySampler {
    /// nil on Macs without a battery.
    static func sample() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func num(_ key: String) -> NSNumber? { SysInfo.property(service, key) as? NSNumber }

        guard num("BatteryInstalled")?.boolValue != false else { return nil }
        var r = BatteryReading()
        let current = num("CurrentCapacity")?.doubleValue ?? 0
        let max = num("MaxCapacity")?.doubleValue ?? 100
        r.percent = max > 0 ? min(1, current / max) : 0
        r.isCharging = num("IsCharging")?.boolValue ?? false
        r.isPluggedIn = num("ExternalConnected")?.boolValue ?? false
        r.isFull = num("FullyCharged")?.boolValue ?? false
        if let t = num("TimeRemaining")?.intValue, t > 0, t < 6000, !r.isFull { r.minutesRemaining = t }
        r.cycles = num("CycleCount")?.intValue
        // Same figure as System Settings' "Maximum Capacity": nominal full charge / design capacity.
        // Newer macOS versions keep some of these only inside `BatteryData`.
        let data = SysInfo.property(service, "BatteryData") as? [String: Any]
        func capacity(_ key: String) -> Double? {
            ((data?[key] as? NSNumber) ?? num(key))?.doubleValue
        }
        if let design = capacity("DesignCapacity"), design > 0,
           let full = capacity("NominalChargeCapacity") ?? capacity("AppleRawMaxCapacity"), full > 0 {
            r.health = min(1, full / design)
        }
        // Amperage is a signed value the registry stores as an unsigned 64-bit number.
        if let mv = num("Voltage")?.doubleValue, let ma = num("Amperage") {
            let amps = Double(Int64(bitPattern: ma.uint64Value)) / 1000
            r.power = mv / 1000 * amps
        }
        if let adapter = SysInfo.property(service, "AdapterDetails") as? [String: Any],
           let w = adapter["Watts"] as? NSNumber, w.intValue > 0 {
            r.adapterWatts = w.intValue
        }
        return r
    }
}
