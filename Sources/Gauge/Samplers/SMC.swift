import Foundation
import IOKit

/// Minimal read-only client for the System Management Controller (fans, power, temperatures).
///
/// The kernel interface takes an 80-byte `SMCKeyData_t`. It is filled by offset instead of
/// mirroring the C struct, so Swift's layout rules can't shift a field:
///   0 key · 28 keyInfo.dataSize · 32 keyInfo.dataType · 40 result · 42 data8 (command) · 44 data32 · 48 bytes[32]
final class SMC {
    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]

    private static let readBytes: UInt8 = 5
    private static let readKeyInfo: UInt8 = 9

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(connection) }

    /// The key's value as a number, or nil if the key doesn't exist on this Mac.
    func value(_ key: String) -> Double? {
        let code = Self.fourCC(key)
        guard let info = keyInfo(code) else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        Self.put(code, into: &input, at: 0)
        Self.put(info.size, into: &input, at: 28)
        input[42] = Self.readBytes
        guard let out = call(input) else { return nil }
        let bytes = Array(out[48..<(48 + min(32, Int(info.size)))])
        return Self.decode(bytes, type: info.type)
    }

    private func keyInfo(_ code: UInt32) -> (size: UInt32, type: UInt32)? {
        if let cached = infoCache[code] { return cached.size == 0 ? nil : cached }
        var input = [UInt8](repeating: 0, count: 80)
        Self.put(code, into: &input, at: 0)
        input[42] = Self.readKeyInfo
        guard let out = call(input) else {
            infoCache[code] = (0, 0) // remember misses; probing unknown keys is the expensive part
            return nil
        }
        let info = (size: Self.get(out, at: 28), type: Self.get(out, at: 32))
        infoCache[code] = info
        return info.size == 0 ? nil : info
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var input = input
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let r = IOConnectCallStructMethod(connection, 2, &input, 80, &output, &outputSize)
        return r == kIOReturnSuccess && output[40] == 0 ? output : nil
    }

    private static func decode(_ b: [UInt8], type: UInt32) -> Double? {
        func be(_ n: Int) -> UInt64 { b.prefix(n).reduce(0) { $0 << 8 | UInt64($1) } }
        switch type {
        case fourCC("flt "): return b.count >= 4 ? Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }) : nil
        case fourCC("ui8 "): return b.count >= 1 ? Double(b[0]) : nil
        case fourCC("ui16"): return b.count >= 2 ? Double(be(2)) : nil
        case fourCC("ui32"): return b.count >= 4 ? Double(be(4)) : nil
        case fourCC("fpe2"): return b.count >= 2 ? Double(be(2)) / 4 : nil
        case fourCC("sp78"): return b.count >= 2 ? Double(Int16(bitPattern: UInt16(be(2)))) / 256 : nil
        default: return nil
        }
    }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }

    private static func put(_ v: UInt32, into buf: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: v) { for i in 0..<4 { buf[offset + i] = $0[i] } }
    }

    private static func get(_ buf: [UInt8], at offset: Int) -> UInt32 {
        buf[offset..<(offset + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
}

/// Apple Silicon temperature sensors exposed through IOHIDEventSystem (the PMU die sensors,
/// NAND and battery gas gauge). These calls are exported by IOKit but not in its headers, so
/// they're looked up at runtime; if any is missing the reader just returns nothing.
final class HIDTemperatures {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias SetMatchingFn = @convention(c) (OpaquePointer, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (OpaquePointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
    private typealias GetFloatFn = @convention(c) (OpaquePointer, Int32) -> Double

    private let copyEvent: CopyEventFn?
    private let getFloat: GetFloatFn?
    private var services: [(name: String, service: AnyObject)] = []

    private static let temperatureEvent: Int64 = 15

    init() {
        func sym<T>(_ name: String, _: T.Type) -> T? {
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }
        }
        copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self)
        getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self)
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let client = create(kCFAllocatorDefault) else { return }
        // Vendor page 0xff00, usage 5 = temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let list = (copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        services = list.compactMap { s in
            let ptr = OpaquePointer(Unmanaged.passUnretained(s).toOpaque())
            guard let name = copyProperty(ptr, "Product" as CFString)?.takeRetainedValue() as? String else { return nil }
            return (name, s)
        }
        // The client must outlive its services; it's created once per app run, so keep it forever.
    }

    /// Current values grouped by sensor name (several sensors share a name).
    func read() -> [String: [Double]] {
        guard let copyEvent, let getFloat else { return [:] }
        var out: [String: [Double]] = [:]
        for (name, s) in services {
            let ptr = OpaquePointer(Unmanaged.passUnretained(s).toOpaque())
            guard let event = copyEvent(ptr, Self.temperatureEvent, 0, 0) else { continue }
            let v = getFloat(event, Int32(Self.temperatureEvent << 16))
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()
            if v > 0 && v < 150 { out[name, default: []].append(v) }
        }
        return out
    }
}
