import AppKit
import SwiftUI

struct CPUPanel: View {
    let monitor: Monitor
    @ObservedObject var settings: GaugeSettings

    var body: some View {
        let c = monitor.cpu
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "CPU", value: Fmt.percent(c.total),
                        detail: "\(SysInfo.chip) · \(SysInfo.performanceCores)P + \(SysInfo.efficiencyCores)E")
            HistoryChart(series: [.init(name: "User", values: monitor.cpuUser.values, color: Palette.user),
                                  .init(name: "System", values: monitor.cpuSystem.values, color: Palette.system)],
                         range: 0...1)
            VStack(spacing: 4) {
                InfoRow("User", Fmt.percent(c.user), color: Palette.user)
                InfoRow("System", Fmt.percent(c.system), color: Palette.system)
                InfoRow("Idle", Fmt.percent(1 - c.total), color: Color.primary.opacity(0.15))
            }
            SectionLabel("Cores")
            CoreBars(values: c.cores, kinds: SysInfo.coreKinds)
            VStack(spacing: 4) {
                InfoRow("Load average", c.load.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                if let t = monitor.sensors.cpu {
                    InfoRow("Temperature", Fmt.temperature(t, fahrenheit: settings.fahrenheit))
                }
                InfoRow("Uptime", Fmt.uptime(c.uptime))
            }
            SectionLabel("Top processes")
            ProcessList(rows: monitor.topCPU) { String(format: "%.1f%%", $0.cpu) }
        }
    }
}

struct CoreBars: View {
    let values: [Double]
    let kinds: [SysInfo.CoreKind]

    private let spacing: CGFloat = 12

    var body: some View {
        GeometryReader { g in
            let available = g.size.width - spacing
            HStack(alignment: .top, spacing: spacing) {
                group("Efficiency", .efficiency, .teal, available)
                group("Performance", .performance, Palette.user, available)
            }
        }
        .frame(height: 50)
    }

    /// Each group gets width in proportion to its core count, so every bar is the same width.
    @ViewBuilder
    private func group(_ title: String, _ kind: SysInfo.CoreKind, _ color: Color, _ available: CGFloat) -> some View {
        let indices = values.indices.filter { $0 < kinds.count && kinds[$0] == kind }
        if !indices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(indices, id: \.self) { i in
                        GeometryReader { g in
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                                RoundedRectangle(cornerRadius: 2).fill(color)
                                    .frame(height: g.size.height * min(1, values[i]))
                            }
                        }
                    }
                }
                .frame(height: 34)
                Text("\(title) · \(Fmt.percent(indices.map { values[$0] }.reduce(0, +) / Double(indices.count)))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: max(0, available * CGFloat(indices.count) / CGFloat(max(1, values.count))), alignment: .leading)
        }
    }
}

struct GPUPanel: View {
    let monitor: Monitor
    @ObservedObject var settings: GaugeSettings

    var body: some View {
        let g = monitor.gpu
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "GPU", value: g.utilization.map(Fmt.percent) ?? "–",
                        detail: g.cores.map { "\(g.name) · \($0) cores" } ?? g.name)
            HistoryChart(series: [.init(name: "GPU", values: monitor.gpuHistory.values, color: Palette.gpu)],
                         range: 0...1)
            VStack(spacing: 4) {
                InfoRow("Utilization", g.utilization.map(Fmt.percent) ?? "Unavailable", color: Palette.gpu)
                InfoRow("Peak (last \(History.capacity) samples)", Fmt.percent(monitor.gpuHistory.peak))
                if let t = monitor.sensors.gpu {
                    InfoRow("Temperature", Fmt.temperature(t, fahrenheit: settings.fahrenheit))
                }
            }
        }
    }
}

struct MemoryPanel: View {
    let monitor: Monitor

    var body: some View {
        let m = monitor.memory
        let (pressure, pressureColor): (String, Color) = switch m.pressure {
        case .normal: ("Normal", .green)
        case .warning: ("Warning", .yellow)
        case .critical: ("Critical", .red)
        }
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Memory", value: Fmt.percent(m.usedFraction),
                        detail: "\(Fmt.memory(m.used)) of \(Fmt.memory(m.total)) used")
            HistoryChart(series: [.init(name: "Used", values: monitor.memoryHistory.values, color: pressureColor)],
                         range: 0...1)
            SegmentBar(segments: [(Double(m.app), .blue), (Double(m.wired), .orange),
                                  (Double(m.compressed), .purple), (Double(m.cached), .gray.opacity(0.6))],
                       total: Double(m.total))
            VStack(spacing: 4) {
                InfoRow("App memory", Fmt.memory(m.app), color: .blue)
                InfoRow("Wired", Fmt.memory(m.wired), color: .orange)
                InfoRow("Compressed", Fmt.memory(m.compressed), color: .purple)
                InfoRow("Cached files", Fmt.memory(m.cached), color: .gray.opacity(0.6))
                InfoRow("Free", Fmt.memory(m.free), color: Color.primary.opacity(0.15))
            }
            VStack(spacing: 4) {
                InfoRow("Pressure", pressure, valueColor: pressureColor)
                InfoRow("Swap used", m.swapTotal > 0 ? "\(Fmt.memory(m.swapUsed)) of \(Fmt.memory(m.swapTotal))" : "None")
            }
            SectionLabel("Top processes")
            ProcessList(rows: monitor.topMemory) { Fmt.memory($0.memory) }
        }
    }
}

struct DiskPanel: View {
    let monitor: Monitor

    var body: some View {
        let d = monitor.disk
        let root = monitor.volumes.first { $0.path == "/" }
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Disk", value: root.map { Fmt.storage($0.available) } ?? "–",
                        detail: root.map { "free on \($0.name)" })
            HistoryChart(series: [.init(name: "Read", values: monitor.readHistory.values, color: Palette.read),
                                  .init(name: "Write", values: monitor.writeHistory.values, color: Palette.write)],
                         stacked: false, minimumPeak: 1_000_000)
            VStack(spacing: 4) {
                InfoRow("Read", Fmt.rate(d.read), color: Palette.read)
                InfoRow("Write", Fmt.rate(d.write), color: Palette.write)
            }
            SectionLabel("Volumes")
            VStack(spacing: 10) {
                ForEach(monitor.volumes) { v in
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: v.path))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: v.isInternal ? "internaldrive" : "externaldrive")
                                    .foregroundStyle(.secondary)
                                Text(v.name).lineLimit(1)
                                Spacer()
                                Text("\(Fmt.storage(v.available)) free").monospacedDigit().foregroundStyle(.secondary)
                            }
                            UsageBar(fraction: v.usedFraction, color: v.usedFraction > 0.9 ? .red : .accentColor)
                            Text("\(Fmt.storage(v.used)) of \(Fmt.storage(v.total)) used")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in Finder")
                }
            }
            VStack(spacing: 4) {
                InfoRow("Read since boot", Fmt.storage(d.readSinceBoot))
                InfoRow("Written since boot", Fmt.storage(d.writtenSinceBoot))
            }
        }
    }
}

struct NetworkPanel: View {
    let monitor: Monitor

    var body: some View {
        let n = monitor.network
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Network", value: n.interface == nil ? "Offline" : "",
                        detail: n.interface.map { "\(n.interfaceName ?? $0) (\($0))" } ?? "No active connection")
            HStack(spacing: 0) {
                rate("Download", n.download, "arrow.down", Palette.download)
                rate("Upload", n.upload, "arrow.up", Palette.upload)
            }
            HistoryChart(series: [.init(name: "Download", values: monitor.downloadHistory.values, color: Palette.download),
                                  .init(name: "Upload", values: monitor.uploadHistory.values, color: Palette.upload)],
                         stacked: false, minimumPeak: 50_000)
            VStack(spacing: 4) {
                if let ip = n.ipv4 { InfoRow("IP address", ip) }
                InfoRow("Received this session", Fmt.storage(n.receivedSession))
                InfoRow("Sent this session", Fmt.storage(n.sentSession))
            }
        }
    }

    private func rate(_ title: String, _ value: Double, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(color)
            Text(Fmt.rate(value)).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SensorsPanel: View {
    let monitor: Monitor
    @ObservedObject var settings: GaugeSettings

    var body: some View {
        let s = monitor.sensors
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Sensors", value: s.cpu.map(temp) ?? "–", detail: "\(SysInfo.chip) · CPU average")
            HistoryChart(series: [.init(name: "CPU", values: monitor.cpuTempHistory.values,
                                        color: Palette.temperature(s.cpu ?? 0))],
                         range: 20...110)

            SectionLabel("Temperatures")
            VStack(spacing: 6) {
                tempRow("CPU average", s.cpu)
                tempRow("CPU hottest", s.cpuHottest)
                tempRow("Performance cores", s.performanceCores)
                tempRow("Efficiency cores", s.efficiencyCores)
                tempRow("GPU", s.gpu)
                tempRow("SSD", s.ssd)
                tempRow("Battery", s.battery)
            }

            if !s.fans.isEmpty {
                SectionLabel("Fans")
                VStack(spacing: 6) {
                    ForEach(s.fans) { fan in
                        meterRow(s.fans.count > 1 ? (fan.id == 0 ? "Left fan" : "Right fan") : "Fan",
                                 fraction: fan.fraction,
                                 value: fan.isSpinning ? "\(Int(fan.rpm)) rpm" : "Off",
                                 color: .cyan)
                    }
                }
            }

            SectionLabel("Power")
            VStack(spacing: 4) {
                if let w = s.systemPower { InfoRow("System power", Fmt.watts(w)) }
                if let b = monitor.battery {
                    InfoRow("Battery", "\(Fmt.percent(b.percent)) · \(batteryState(b))")
                    if let w = b.power, abs(w) > 0.05 {
                        InfoRow(w > 0 ? "Charging at" : "Discharging at", Fmt.watts(abs(w)))
                    }
                    if let h = b.health { InfoRow("Battery health", Fmt.percent(h)) }
                    if let c = b.cycles { InfoRow("Charge cycles", "\(c)") }
                    if let a = b.adapterWatts, b.isPluggedIn { InfoRow("Power adapter", "\(a) W") }
                }
            }
        }
    }

    private func temp(_ c: Double) -> String { Fmt.temperature(c, fahrenheit: settings.fahrenheit) }

    @ViewBuilder
    private func tempRow(_ label: String, _ value: Double?) -> some View {
        if let value {
            meterRow(label, fraction: (value - 20) / 85, value: temp(value), color: Palette.temperature(value))
        }
    }

    private func meterRow(_ label: String, fraction: Double, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 118, alignment: .leading)
            UsageBar(fraction: max(0, fraction), color: color, height: 5)
            Text(value).monospacedDigit().frame(width: 62, alignment: .trailing)
        }
    }

    private func batteryState(_ b: BatteryReading) -> String {
        if b.isFull { return "Fully charged" }
        if b.isCharging {
            return b.minutesRemaining.map { "Charging, full in \(Fmt.minutes($0))" } ?? "Charging"
        }
        if b.isPluggedIn { return "Plugged in, not charging" }
        return b.minutesRemaining.map { "\(Fmt.minutes($0)) left" } ?? "On battery"
    }
}
