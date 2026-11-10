import Darwin
import Foundation

struct MemoryReading {
    enum Pressure { case normal, warning, critical }

    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: Pressure = .normal
    /// 0…1, from `kern.memorystatus_level` (the share the kernel considers available).
    var pressureLevel: Double = 0

    /// What Activity Monitor calls "Memory Used".
    var used: UInt64 { app + wired + compressed }
    var free: UInt64 { total > used + cached ? total - used - cached : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum MemorySampler {
    static func sample() -> MemoryReading {
        var r = MemoryReading()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if ok == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            r.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            r.wired = UInt64(stats.wire_count) * page
            r.compressed = UInt64(stats.compressor_page_count) * page
            r.cached = (UInt64(stats.external_page_count) + purgeable) * page
        }

        switch SysInfo.int("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 4: r.pressure = .critical
        case 2: r.pressure = .warning
        default: r.pressure = .normal
        }
        if let level = SysInfo.int("kern.memorystatus_level") {
            r.pressureLevel = Double(100 - min(100, max(0, level))) / 100
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            r.swapUsed = swap.xsu_used
            r.swapTotal = swap.xsu_total
        }
        return r
    }
}
