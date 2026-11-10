import Darwin
import Foundation
import IOKit

struct CPUReading {
    var user = 0.0
    var system = 0.0
    var cores: [Double] = []
    var load: [Double] = [0, 0, 0]
    var uptime: TimeInterval = 0
    var total: Double { min(1, user + system) }
}

/// Usage from per-core tick counters (`host_processor_info`), as deltas between two samples.
final class CPUSampler {
    private struct Ticks { var user, system, idle, nice: UInt32 }
    private var previous: [Ticks] = []

    func sample() -> CPUReading {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return CPUReading() }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stride = Int(CPU_STATE_MAX)
        let current: [Ticks] = (0..<Int(count)).map { i in
            let b = i * stride
            return Ticks(user: UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]),
                         system: UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                         idle: UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]),
                         nice: UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
        }
        defer { previous = current }

        var reading = CPUReading()
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        reading.load = load
        reading.uptime = ProcessInfo.processInfo.systemUptime
        guard previous.count == current.count else {
            reading.cores = Array(repeating: 0, count: current.count)
            return reading
        }

        var sumUser = 0.0, sumSystem = 0.0, sumAll = 0.0
        for (now, before) in zip(current, previous) {
            // Counters are 32-bit and wrap; wrapping subtraction keeps the delta right.
            let user = Double(now.user &- before.user) + Double(now.nice &- before.nice)
            let system = Double(now.system &- before.system)
            let idle = Double(now.idle &- before.idle)
            let all = user + system + idle
            reading.cores.append(all > 0 ? (user + system) / all : 0)
            sumUser += user; sumSystem += system; sumAll += all
        }
        if sumAll > 0 {
            reading.user = sumUser / sumAll
            reading.system = sumSystem / sumAll
        }
        return reading
    }
}

struct GPUReading {
    var utilization: Double?
    var name = SysInfo.chip
    var cores: Int?
}

/// GPU busy % from the accelerator's `PerformanceStatistics` (same source as Activity Monitor's GPU history).
final class GPUSampler {
    func sample() -> GPUReading {
        var reading = GPUReading()
        SysInfo.forEachService("IOAccelerator") { s in
            if let stats = SysInfo.property(s, "PerformanceStatistics") as? [String: Any],
               let u = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber {
                reading.utilization = max(reading.utilization ?? 0, u.doubleValue / 100)
            }
            if let model = SysInfo.property(s, "model") as? String { reading.name = model }
            if let cores = SysInfo.property(s, "gpu-core-count") as? NSNumber { reading.cores = cores.intValue }
        }
        return reading
    }
}
