import Foundation

enum Fmt {
    static func percent(_ f: Double) -> String { "\(Int((max(0, f) * 100).rounded()))%" }

    /// Binary units, like Activity Monitor.
    static func memory(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: gb >= 100 ? "%.0f GB" : "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    /// Decimal units, like Finder.
    static func storage<T: BinaryInteger>(_ bytes: T) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Short and width-stable: "0.4 KB/s", "312 KB/s", "1.2 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        let units = ["KB/s", "MB/s", "GB/s"]
        var v = max(0, bytesPerSecond) / 1000
        var i = 0
        while v >= 999.5 && i < units.count - 1 { v /= 1000; i += 1 }
        return String(format: v < 9.95 ? "%.1f %@" : "%.0f %@", v, units[i])
    }

    static func temperature(_ celsius: Double, fahrenheit: Bool) -> String {
        "\(Int((fahrenheit ? celsius * 9 / 5 + 32 : celsius).rounded()))°"
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m % 60)m" }
        return "\(m)m"
    }

    static func minutes(_ total: Int) -> String {
        total >= 60 ? "\(total / 60) h \(total % 60) min" : "\(total) min"
    }

    static func watts(_ w: Double) -> String { String(format: abs(w) < 10 ? "%.1f W" : "%.0f W", w) }
}
