import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

enum Palette {
    static let user = Color.blue
    static let system = Color.red
    static let gpu = Color.purple
    static let download = Color.blue
    static let upload = Color.orange
    static let read = Color.green
    static let write = Color.orange

    static func temperature(_ c: Double) -> Color {
        c < 60 ? .green : c < 80 ? .yellow : c < 95 ? .orange : .red
    }
}

struct PanelView: View {
    let modules: [Module]
    let monitor: Monitor
    @ObservedObject var settings: GaugeSettings
    var onSelect: (Module) -> Void
    @State private var module: Module

    init(modules: [Module], selection: Module, monitor: Monitor, settings: GaugeSettings,
         onSelect: @escaping (Module) -> Void) {
        self.modules = modules
        self.monitor = monitor
        self.settings = settings
        self.onSelect = onSelect
        _module = State(initialValue: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if modules.count > 1 {
                Picker("Stat", selection: $module) {
                    ForEach(modules) { Text($0.shortTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding([.horizontal, .top], 14)
                .onChange(of: module) { _, new in onSelect(new) }
            }
            Group {
                switch module {
                case .cpu: CPUPanel(monitor: monitor, settings: settings)
                case .gpu: GPUPanel(monitor: monitor, settings: settings)
                case .memory: MemoryPanel(monitor: monitor)
                case .disk: DiskPanel(monitor: monitor)
                case .network: NetworkPanel(monitor: monitor)
                case .sensors: SensorsPanel(monitor: monitor, settings: settings)
                }
            }
            .padding(14)
            Divider()
            PanelFooter(settings: settings)
        }
        .frame(width: 300)
        .font(.system(size: 12))
    }
}

struct PanelHeader: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var color: Color?
    var valueColor: Color?

    init(_ label: String, _ value: String, color: Color? = nil, valueColor: Color? = nil) {
        self.label = label
        self.value = value
        self.color = color
        self.valueColor = valueColor
    }

    var body: some View {
        HStack(spacing: 6) {
            if let color {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(valueColor ?? .primary)
        }
    }
}

struct HistoryChart: View {
    struct Series: Identifiable {
        let name: String
        let values: [Double]
        let color: Color
        var id: String { name }
    }

    let series: [Series]
    var stacked = true
    /// Fixed y range; nil scales to the visible peak.
    var range: ClosedRange<Double>?
    var minimumPeak: Double = 1
    var height: CGFloat = 60

    private var yDomain: ClosedRange<Double> {
        if let range { return range }
        let peaks = stacked
            ? (0..<(series.map(\.values.count).max() ?? 0)).map { i in series.reduce(0) { $0 + ($1.values.indices.contains(i) ? $1.values[i] : 0) } }
            : series.flatMap(\.values)
        return 0...max(minimumPeak, (peaks.max() ?? 0) * 1.15)
    }

    var body: some View {
        let cap = History.capacity
        Chart {
            ForEach(series) { s in
                ForEach(Array(s.values.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("Time", cap - s.values.count + i),
                             y: .value("Value", v),
                             stacking: stacked ? .standard : .unstacked)
                        .foregroundStyle(by: .value("Series", s.name))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.name),
                                   range: series.map { $0.color.opacity(stacked ? 0.8 : 0.55) })
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...(cap - 1))
        .chartYScale(domain: yDomain)
        .frame(height: height)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .animation(nil, value: series.first?.values.count)
    }
}

struct UsageBar: View {
    let fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if fraction > 0 {
                    Capsule().fill(color).frame(width: max(height, g.size.width * min(1, fraction)))
                }
            }
        }
        .frame(height: height)
    }
}

/// Horizontal bar split into proportional segments.
struct SegmentBar: View {
    let segments: [(value: Double, color: Color)]
    let total: Double

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    Rectangle().fill(s.color)
                        .frame(width: max(0, g.size.width * s.value / max(1, total) - 1))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 10)
    }
}

struct ProcessList: View {
    let rows: [ProcRow]
    let value: (ProcRow) -> String

    var body: some View {
        VStack(spacing: 5) {
            if rows.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Reading processes…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Image(nsImage: ProcessIcon.image(for: row.pid))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(value(row)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }
}

@MainActor
enum ProcessIcon {
    private static var cache: [pid_t: NSImage] = [:]
    private static let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    static func image(for pid: pid_t) -> NSImage {
        if let cached = cache[pid] { return cached }
        let image = Demo.icon(for: pid) ?? NSRunningApplication(processIdentifier: pid)?.icon ?? generic
        if cache.count > 200 { cache.removeAll() }
        cache[pid] = image
        return image
    }
}

struct PanelFooter: View {
    @ObservedObject var settings: GaugeSettings

    var body: some View {
        HStack {
            Button {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                    configuration: .init())
            } label: {
                Label("Activity Monitor", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(.borderless)

            Spacer()

            Menu {
                Picker("Menu bar", selection: $settings.combined) {
                    Text("One item that rotates").tag(true)
                    Text("One item per stat").tag(false)
                }
                if settings.combined {
                    Picker("Switch every", selection: $settings.rotation) {
                        Text("3 seconds").tag(3.0)
                        Text("5 seconds").tag(5.0)
                        Text("10 seconds").tag(10.0)
                        Text("Don't rotate").tag(0.0)
                    }
                }
                Section(settings.combined ? "Rotate through (right-click item to skip)" : "Show in menu bar") {
                    ForEach(Module.allCases) { m in
                        Toggle(m.title, isOn: Binding(get: { settings.enabled.contains(m) },
                                                      set: { settings.setEnabled(m, $0) }))
                    }
                }
                Divider()
                Picker("Update every", selection: $settings.interval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                }
                Picker("CPU in menu bar", selection: $settings.cpuStyle) {
                    ForEach(CPUStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Colorful graphs", isOn: $settings.colorful)
                Toggle("Fahrenheit", isOn: $settings.fahrenheit)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Divider()
                Button("Quit Gauge") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
