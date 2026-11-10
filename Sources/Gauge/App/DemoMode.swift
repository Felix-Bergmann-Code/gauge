import AppKit

/// `Gauge --demo` keeps the live system numbers but replaces anything that says something about
/// you (the apps you run, your IP address, the names of your drives) with sample values, and
/// pre-fills the history graphs. Meant for screenshots:
///   Gauge --demo --open cpu
enum Demo {
    static let isEnabled = CommandLine.arguments.contains("--demo")

    /// Sample processes use negative pids so they never match a real process.
    private static let apps: [(name: String, path: String?, cpu: Double, memoryMB: Double)] = [
        ("Xcode", "/Applications/Xcode.app", 38.4, 2_150),
        ("WindowServer", nil, 21.7, 820),
        ("Safari", "/Applications/Safari.app", 12.9, 1_430),
        ("Music", "/System/Applications/Music.app", 6.2, 310),
        ("Finder", "/System/Library/CoreServices/Finder.app", 2.4, 240),
        ("kernel_task", nil, 1.8, 1_020),
    ]

    @MainActor static func icon(for pid: pid_t) -> NSImage? {
        guard pid < 0, apps.indices.contains(Int(-pid) - 1), let path = apps[Int(-pid) - 1].path,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    static func processes() -> (byCPU: [ProcRow], byMemory: [ProcRow]) {
        let rows = apps.enumerated().map { i, a in
            ProcRow(pid: pid_t(-(i + 1)), name: a.name, cpu: a.cpu * Double.random(in: 0.85...1.15),
                    memory: UInt64(a.memoryMB * 1_048_576))
        }
        return (rows.sorted { $0.cpu > $1.cpu }, rows.sorted { $0.memory > $1.memory })
    }

    static let ipv4 = "192.168.1.24"

    /// Sample transfer rates, so the network module doesn't sit at zero in a screenshot.
    static func fakeTraffic(_ n: inout NetworkReading) {
        n.download = Double.random(in: 600_000...2_400_000)
        n.upload = Double.random(in: 60_000...220_000)
        n.receivedSession = 1_840_000_000
        n.sentSession = 236_000_000
    }

    static func volumes(_ real: [Volume]) -> [Volume] {
        real.filter { $0.path == "/" }.map {
            Volume(path: $0.path, name: "Macintosh HD", total: $0.total, available: $0.available, isInternal: true)
        }
    }

    /// A smooth, plausible-looking series for pre-filling a history graph.
    static func series(base: Double, swing: Double, noise: Double, phase: Double = 0) -> [Double] {
        (0..<History.capacity).map { i in
            let t = Double(i) / 9 + phase
            return max(0, base + swing * (sin(t) * 0.6 + sin(t * 2.7) * 0.4) + Double.random(in: -noise...noise))
        }
    }
}
