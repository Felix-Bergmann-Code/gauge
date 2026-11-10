import AppKit

/// What one menu bar item draws.
enum StatusContent {
    /// Histogram of the last samples (stacked series, bottom first) plus a label and value.
    case graph(label: String, value: String, series: [[Double]], colors: [NSColor])
    /// One bar per core, efficiency cores first.
    case cores([Double], [SysInfo.CoreKind])
    /// Vertical level bar plus a label and value.
    case meter(label: String, value: String, fraction: Double, color: NSColor)
    /// Two stacked lines of small text; `reference` fixes the width so it doesn't jitter.
    case lines(top: String, bottom: String, reference: String)
    /// Label-over-value blocks side by side.
    case pairs([(label: String, value: String, reference: String)])
}

/// Drawn with Core Graphics inside the status item's button: crisp, cheap, and it follows the
/// menu bar's light/dark appearance because colors resolve at draw time.
final class StatusView: NSView {
    var content: StatusContent = .pairs([]) { didSet { needsDisplay = true } }
    var colorful = true { didSet { needsDisplay = true } }

    private static let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .bold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let lineFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let graphSize = NSSize(width: 26, height: 16)
    private static let padding: CGFloat = 4
    private static let gap: CGFloat = 4

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the button

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    var preferredWidth: CGFloat { Self.width(of: content) }

    /// Slides the next content change in vertically, like a ticker.
    func slideNextChange() {
        wantsLayer = true
        let t = CATransition()
        t.type = .push
        t.subtype = .fromTop
        t.duration = 0.35
        t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(t, forKey: "slide")
    }

    static func width(of content: StatusContent) -> CGFloat {
        let p = padding * 2
        switch content {
        case let .graph(label, _, _, _):
            return p + Self.graphSize.width + Self.gap + Self.blockWidth(label: label, reference: "100%")
        case let .cores(values, kinds):
            return p + Self.coresWidth(values.count, kinds)
        case let .meter(label, _, _, _):
            return p + 5 + Self.gap + Self.blockWidth(label: label, reference: "100%")
        case let .lines(_, _, reference):
            return p + ceil(Self.size(reference, Self.lineFont).width)
        case let .pairs(pairs):
            let blocks = pairs.map { Self.blockWidth(label: $0.label, reference: $0.reference) }
            return p + blocks.reduce(0, +) + CGFloat(max(0, pairs.count - 1)) * 6
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.drawContent() }
    }

    private func drawContent() {
        // Centered, so a fixed-width item (the rotating one) doesn't hug its left edge.
        var x = max(Self.padding, (bounds.width - preferredWidth) / 2 + Self.padding)
        let midY = bounds.midY
        switch content {
        case let .graph(label, value, series, colors):
            let rect = NSRect(x: x, y: midY - Self.graphSize.height / 2, width: Self.graphSize.width, height: Self.graphSize.height)
            drawHistogram(series, colors: colors, in: rect)
            x = rect.maxX + Self.gap
            drawBlock(label: label, value: value, x: x)

        case let .cores(values, kinds):
            let h = Self.graphSize.height
            for (i, v) in values.enumerated() {
                if i > 0, i < kinds.count, kinds[i] != kinds[i - 1] { x += 2 }
                let kind = i < kinds.count ? kinds[i] : .performance
                let track = NSRect(x: x, y: midY - h / 2, width: 3, height: h)
                NSColor.labelColor.withAlphaComponent(0.15).setFill()
                track.fill()
                let fillH = max(v > 0.01 ? 1 : 0, h * CGFloat(min(1, v)))
                color(for: kind).setFill()
                NSRect(x: x, y: track.maxY - fillH, width: 3, height: fillH).fill()
                x += 4
            }

        case let .meter(label, value, fraction, tint):
            let h = Self.graphSize.height
            let track = NSRect(x: x, y: midY - h / 2, width: 5, height: h)
            NSColor.labelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            let fillH = h * CGFloat(min(1, max(0, fraction)))
            (colorful ? tint : NSColor.labelColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: track.maxY - fillH, width: 5, height: fillH), xRadius: 1.5, yRadius: 1.5).fill()
            drawBlock(label: label, value: value, x: track.maxX + Self.gap)

        case let .lines(top, bottom, _):
            let attrs = Self.attributes(Self.lineFont, .labelColor)
            let lineH = Self.size("8", Self.lineFont).height
            let topY = midY - lineH + 0.5
            (top as NSString).draw(at: NSPoint(x: x, y: topY), withAttributes: attrs)
            (bottom as NSString).draw(at: NSPoint(x: x, y: topY + lineH - 1), withAttributes: attrs)

        case let .pairs(pairs):
            for pair in pairs {
                drawBlock(label: pair.label, value: pair.value, x: x)
                x += Self.blockWidth(label: pair.label, reference: pair.reference) + 6
            }
        }
    }

    /// A tiny label above a value, both left-aligned at `x`, vertically centered as one unit.
    private func drawBlock(label: String, value: String, x: CGFloat) {
        let labelH = Self.labelFont.ascender - Self.labelFont.descender
        let valueH = Self.valueFont.ascender - Self.valueFont.descender
        let total = labelH + valueH - 2
        let top = bounds.midY - total / 2
        (label as NSString).draw(at: NSPoint(x: x, y: top - 0.5),
                                 withAttributes: Self.attributes(Self.labelFont, NSColor.labelColor.withAlphaComponent(0.8)))
        (value as NSString).draw(at: NSPoint(x: x, y: top + labelH - 2),
                                 withAttributes: Self.attributes(Self.valueFont, .labelColor))
    }

    /// One-pixel columns, newest on the right; series stack from the bottom.
    private func drawHistogram(_ series: [[Double]], colors: [NSColor], in rect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        let columns = Int(rect.width)
        let count = series.map(\.count).max() ?? 0
        guard count > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).addClip()
        for col in 0..<min(columns, count) {
            let sampleIndex = count - 1 - col
            let x = rect.maxX - CGFloat(col + 1)
            var base: CGFloat = 0
            for (s, values) in series.enumerated() {
                let offset = values.count - count
                guard sampleIndex + offset >= 0 else { continue }
                let v = CGFloat(min(1, max(0, values[sampleIndex + offset])))
                let h = v * rect.height
                guard h > 0 else { continue }
                seriesColor(s, colors).setFill()
                NSRect(x: x, y: rect.maxY - base - h, width: 1, height: h).fill()
                base += h
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func seriesColor(_ index: Int, _ colors: [NSColor]) -> NSColor {
        if colorful, index < colors.count { return colors[index] }
        return NSColor.labelColor.withAlphaComponent(index == 0 ? 0.85 : 0.45)
    }

    private func color(for kind: SysInfo.CoreKind) -> NSColor {
        guard colorful else { return .labelColor }
        return kind == .efficiency ? .systemTeal : .systemBlue
    }

    private static func coresWidth(_ count: Int, _ kinds: [SysInfo.CoreKind]) -> CGFloat {
        let switches = zip(kinds, kinds.dropFirst()).filter { $0 != $1 }.count
        return CGFloat(count) * 4 - 1 + CGFloat(switches) * 2
    }

    private static func blockWidth(label: String, reference: String) -> CGFloat {
        ceil(max(size(label, labelFont).width, size(reference, valueFont).width))
    }

    private static func size(_ s: String, _ font: NSFont) -> NSSize {
        (s as NSString).size(withAttributes: [.font: font])
    }

    private static func attributes(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }
}
