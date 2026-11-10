import AppKit
import Darwin

struct ProcRow: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let cpu: Double // percent of one core, as Activity Monitor shows it
    let memory: UInt64
    var id: pid_t { pid }
}

/// Top processes by CPU and memory.
///
/// `ps` is setuid root, so it sees processes this app can't read itself (WindowServer,
/// kernel_task, other users). Memory is upgraded to the physical footprint (what Activity
/// Monitor shows) wherever libproc allows it; elsewhere it stays the resident size.
final class ProcessSampler {
    private var names: [pid_t: String] = [:]

    func sample(limit: Int = 6) -> (byCPU: [ProcRow], byMemory: [ProcRow]) {
        guard let output = Self.run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm="]) else { return ([], []) }
        var rows: [(pid: pid_t, cpu: Double, rss: UInt64, comm: String)] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = pid_t(parts[0]), let cpu = Double(parts[1]),
                  let rss = UInt64(parts[2]) else { continue }
            rows.append((pid, cpu, rss * 1024, String(parts[3])))
        }

        func row(_ r: (pid: pid_t, cpu: Double, rss: UInt64, comm: String)) -> ProcRow {
            ProcRow(pid: r.pid, name: name(r.pid, fallback: r.comm), cpu: r.cpu, memory: Self.footprint(r.pid) ?? r.rss)
        }
        let byCPU = rows.sorted { $0.cpu > $1.cpu }.prefix(limit).map(row)
        // Sort a wider slice by footprint, since rss and footprint can rank differently.
        let byMemory = rows.sorted { $0.rss > $1.rss }.prefix(limit * 3).map(row)
            .sorted { $0.memory > $1.memory }.prefix(limit)

        let alive = Set(rows.map(\.pid))
        names = names.filter { alive.contains($0.key) }
        return (Array(byCPU), Array(byMemory))
    }

    private func name(_ pid: pid_t, fallback: String) -> String {
        if let cached = names[pid] { return cached }
        var name = fallback
        if pid == 0 {
            name = "kernel_task"
        } else if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName {
            name = n
        } else {
            // `comm` is cut at 16 characters; the executable path has the full name when readable.
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
                name = (String(cString: buf) as NSString).lastPathComponent
            }
        }
        names[pid] = name
        return name
    }

    private static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 && info.ri_phys_footprint > 0 ? info.ri_phys_footprint : nil
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
