import Darwin
import Foundation
import IOKit

enum SysInfo {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // Some keys are 32-bit; sysctl writes only `size` bytes into the low end.
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static let chip: String = string("machdep.cpu.brand_string") ?? "Apple Silicon"

    /// 1 for M1, 2 for M2, … (nil on Intel or unknown names).
    static let chipGeneration: Int? = {
        guard let r = chip.range(of: #"M(\d+)"#, options: .regularExpression) else { return nil }
        return Int(chip[r].dropFirst())
    }()

    static let coreCount = int("hw.ncpu") ?? ProcessInfo.processInfo.processorCount

    enum CoreKind { case efficiency, performance }

    /// Per logical CPU, read from the device tree (`cluster-type` = "E" / "P").
    static let coreKinds: [CoreKind] = {
        var kinds: [CoreKind] = []
        for i in 0..<coreCount {
            let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus/cpu\(i)")
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard let data = IORegistryEntryCreateCFProperty(entry, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data, let c = data.first else { break }
            kinds.append(c == UInt8(ascii: "E") ? .efficiency : .performance)
        }
        if kinds.count == coreCount { return kinds }
        // Fallback: efficiency cores come first on Apple Silicon.
        let e = int("hw.perflevel1.logicalcpu") ?? 0
        return (0..<coreCount).map { $0 < e ? .efficiency : .performance }
    }()

    static var performanceCores: Int { coreKinds.filter { $0 == .performance }.count }
    static var efficiencyCores: Int { coreKinds.filter { $0 == .efficiency }.count }

    /// Iterates IOKit services of a class, handing each one to `body`.
    static func forEachService(_ className: String, _ body: (io_object_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            body(s)
            IOObjectRelease(s)
        }
    }

    static func property(_ entry: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
