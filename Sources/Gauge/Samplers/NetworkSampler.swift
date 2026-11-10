import Darwin
import Foundation
import SystemConfiguration

struct NetworkReading {
    var download = 0.0 // bytes/s
    var upload = 0.0
    var interface: String?
    var interfaceName: String?
    var ipv4: String?
    var receivedSession: UInt64 = 0
    var sentSession: UInt64 = 0
}

/// Rates for the primary interface, from 64-bit counters (`NET_RT_IFLIST2`).
final class NetworkSampler {
    private let store = SCDynamicStoreCreate(nil, "Gauge" as CFString, nil, nil)
    private var previous: (iface: String, rx: UInt64, tx: UInt64, time: TimeInterval)?
    private var session: (rx: UInt64, tx: UInt64) = (0, 0)
    private var displayNames: [String: String] = [:]
    /// Interface and address change rarely; look them up every few samples instead of every one.
    private var cachedInterface: (name: String?, ipv4: String?, age: Int) = (nil, nil, .max)

    func sample() -> NetworkReading {
        var r = NetworkReading()
        r.receivedSession = session.rx
        r.sentSession = session.tx
        if cachedInterface.age >= 10 {
            let name = primaryInterface()
            cachedInterface = (name, name.flatMap(Self.ipv4(of:)), 0)
        }
        cachedInterface.age += 1
        guard let iface = cachedInterface.name, let counters = Self.counters(of: iface) else {
            previous = nil
            cachedInterface.age = .max // offline: check again next time
            return r
        }
        let now = ProcessInfo.processInfo.systemUptime
        r.interface = iface
        r.interfaceName = displayName(iface)
        r.ipv4 = cachedInterface.ipv4

        if let p = previous, p.iface == iface, now > p.time,
           let drx = Self.delta(counters.rx, p.rx), let dtx = Self.delta(counters.tx, p.tx) {
            let dt = now - p.time
            r.download = Double(drx) / dt
            r.upload = Double(dtx) / dt
            session.rx += drx
            session.tx += dtx
            r.receivedSession = session.rx
            r.sentSession = session.tx
        }
        previous = (iface, counters.rx, counters.tx, now)
        return r
    }

    /// Unprivileged apps get these counters truncated to 32 bits (and rounded to 1 KiB), so
    /// they wrap every 4 GiB. Treat a drop as one wrap; anything else is a reset and is skipped.
    private static func delta(_ now: UInt64, _ before: UInt64) -> UInt64? {
        if now >= before { return now - before }
        let wrap: UInt64 = 1 << 32
        guard before < wrap, now < wrap else { return nil }
        return now + wrap - before
    }

    private func primaryInterface() -> String? {
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = dict["PrimaryInterface"] as? String { return name }
        }
        return nil
    }

    private func displayName(_ bsd: String) -> String {
        if let cached = displayNames[bsd] { return cached }
        var name = bsd
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
           let match = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == bsd }),
           let display = SCNetworkInterfaceGetLocalizedDisplayName(match) as String? {
            name = display
        } else if bsd.hasPrefix("utun") || bsd.hasPrefix("ipsec") {
            name = "VPN"
        }
        displayNames[bsd] = name
        return name
    }

    /// Byte counters of one interface (asking for its index keeps the sysctl small).
    static func counters(of iface: String) -> (rx: UInt64, tx: UInt64)? {
        let index = if_nametoindex(iface)
        guard index > 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

        var result: (UInt64, UInt64)?
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard hdr.ifm_msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let m = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(m.ifm_index) == index {
                        result = (m.ifm_data.ifi_ibytes, m.ifm_data.ifi_obytes)
                    }
                }
                offset += Int(hdr.ifm_msglen)
            }
        }
        return result
    }

    static func ipv4(of iface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: p.pointee.ifa_name) == iface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
