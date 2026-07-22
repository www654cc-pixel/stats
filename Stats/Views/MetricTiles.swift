//
//  MetricTiles.swift
//  Stats
//
//  Uniform metric tiles for the combined overview panel. Every tile shares one
//  skeleton — icon + label, one big value, one micro visualization (capacity
//  bar or sparkline) and two secondary values — so the grid reads as a single
//  system instead of six differently-styled module portals. Clicking a tile
//  opens the module's own detail popup.
//

import Cocoa
import Kit

// MARK: - design tokens

// A single source of truth for the macOS 26 liquid-glass overview: type scale,
// spacing and palette. Every component in the combined panel pulls from here
// so the whole surface reads as one system instead of independently-styled cards.
internal enum Design {
    // spacing — 16pt horizontal margin matches macOS grouped content
    static let padV: CGFloat = 13
    static let padH: CGFloat = 14
    static let gap: CGFloat = 12

    // type scale — macOS native hierarchy: 11pt labels, 13pt body, 20pt display
    static let sectionTitleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let labelFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let labelMediumFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
    static let subFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    static let subFontMono = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    // text colors
    static let titleColor = NSColor.secondaryLabelColor
    static let labelColor = NSColor.labelColor
    static let subColor = NSColor.tertiaryLabelColor

    // unified accent — reserved for "today", local clock, interactive emphasis
    static let accent = NSColor.systemBlue

    // semantic threshold colors
    static let good = NSColor.systemGreen
    static let warn = NSColor.systemOrange
    static let critical = NSColor.systemRed

    // neutral bar track shared by every progress bar in the panel
    static let track = NSColor.tertiaryLabelColor.withAlphaComponent(0.18)

    // hairline divider between major sections
    static let divider = NSColor.separatorColor.withAlphaComponent(0.25)

    // hover surface for clickable cards
    static let hover = NSColor.white.withAlphaComponent(0.06)

    // MARK: content-card material (macOS 26 grouped content on glass)
    // Cards float ABOVE the panel glass: a faint neutral fill separates them
    // from the background, a hairline top-lit border sells the "raised" look,
    // and a soft drop shadow grounds them. Values tuned for .menu material.
    static let cardFill = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.075)
            : NSColor(calibratedWhite: 1.0, alpha: 0.42)
    }
    static let cardHoverFill = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.125)
            : NSColor(calibratedWhite: 1.0, alpha: 0.62)
    }
    static let cardBorder = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.13)
            : NSColor(calibratedWhite: 1.0, alpha: 0.72)
    }
    static let cardShadow = NSColor.black.withAlphaComponent(0.16)
    static let cardRadius: CGFloat = 14
    static let cardBorderWidth: CGFloat = 0.5

    // per-module accent hues for tile icons — mirrors how macOS color-codes
    // system indicators (Activity Monitor, Battery, etc.)
    static func moduleAccent(_ module: String) -> NSColor {
        switch module {
        case "CPU": return NSColor.systemBlue
        case "GPU": return NSColor.systemPurple
        case "RAM": return NSColor.systemGreen
        case "Disk": return NSColor.systemOrange
        case "Network": return NSColor.systemTeal
        case "Sensors": return NSColor.systemPink
        default: return NSColor.systemBlue
        }
    }

    // liquid-glass optical constants (used by popup.swift)
    static let glassEdgeAlpha: CGFloat = 0.28       // border stroke opacity
    static let glassTopGlowMax: CGFloat = 0.07      // top reflection peak
}

// MARK: - grid

internal class MetricTilesGrid: NSStackView {
    // 88pt is the first size that fits the full native type hierarchy without
    // AppKit compressing/clipping the 11pt title row on localized builds.
    static let tileHeight: CGFloat = 96

    private var tiles: [String: MetricTile] = [:]
    private var heightConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        self.orientation = .vertical
        self.spacing = 8
        self.distribution = .fill
        self.alignment = .width
        self.wantsLayer = true
        self.applyClearStyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // (module name, symbol, micro-viz kind), in display order
    static private let specs: [(name: String, symbol: String, viz: MetricTile.Viz)] = [
        ("CPU", "cpu.fill", .bar),
        ("GPU", "square.grid.3x3.fill", .bar),
        ("RAM", "memorychip.fill", .bar),
        ("Disk", "internaldrive.fill", .bar),
        ("Network", "arrow.up.arrow.down", .sparkline),
        ("Sensors", "thermometer.medium", .bar)
    ]

    var isEmpty: Bool { self.tiles.isEmpty }

    func rebuild(width: CGFloat) {
        self.subviews.forEach { $0.removeFromSuperview() }
        self.tiles = [:]

        // the popup's stack alignment alone does not reliably stretch a nested
        // stack view, so pin the grid width explicitly (rows are pinned to it)
        if self.widthConstraint == nil {
            self.widthConstraint = self.widthAnchor.constraint(equalToConstant: width)
            self.widthConstraint?.isActive = true
        } else {
            self.widthConstraint?.constant = width
        }

        let active = MetricTilesGrid.specs.filter { spec in
            modules.contains(where: { $0.name == spec.name && $0.enabled })
        }
        guard !active.isEmpty else {
            self.heightConstraint?.constant = 0
            return
        }

        // classic popup (682px) and dashboard (1022px) both get a 3-column grid;
        // only the narrow single-module popups fall back to fewer columns
        let columns = max(1, min(3, Int(width / 220), active.count))

        var row: NSStackView? = nil
        for (i, spec) in active.enumerated() {
            if i % columns == 0 {
                row = NSStackView()
                row?.orientation = .horizontal
                row?.spacing = self.spacing
                row?.distribution = .fillEqually
                row?.heightAnchor.constraint(equalToConstant: MetricTilesGrid.tileHeight).isActive = true
                self.addArrangedSubview(row!)
                // force full-width rows: hugging tiles must not shrink the row
                row?.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
            }
            let tile = MetricTile(module: spec.name, symbol: spec.symbol, viz: spec.viz)
            self.tiles[spec.name] = tile
            row?.addArrangedSubview(tile)
        }
        // pad the last row so tiles keep a uniform width (fillEqually sizes the fillers)
        if active.count % columns != 0 {
            for _ in 0..<(columns - active.count % columns) {
                row?.addArrangedSubview(NSView())
            }
        }

        let rows = ceil(Double(active.count) / Double(columns))
        let height = CGFloat(rows) * MetricTilesGrid.tileHeight + CGFloat(rows - 1) * self.spacing
        if self.heightConstraint == nil {
            self.heightConstraint = self.heightAnchor.constraint(equalToConstant: height)
            self.heightConstraint?.isActive = true
        } else {
            self.heightConstraint?.constant = height
        }
    }

    private func portal<T>(_ name: String, as type: T.Type) -> T? {
        guard let m = modules.first(where: { $0.name == name && $0.enabled }) else { return nil }
        return m.portal as? T
    }

    private func threshold(_ value: Double, warn: Double, critical: Double) -> NSColor {
        if value >= critical { return Design.critical }
        if value >= warn { return Design.warn }
        return Design.accent
    }

    func refresh() {
        if let tile = self.tiles["CPU"], let p = self.portal("CPU", as: CombinedCPUPortal.self) {
            let usage = (p.lastUsage ?? 0) * 100
            let color = self.threshold(usage, warn: 60, critical: 85)
            tile.set(
                value: "\(Int(usage.rounded()))%",
                valueColor: .labelColor,
                fraction: usage / 100, barColor: color,
                left: "\(localizedString("System")) \(Int(((p.lastSystemLoad ?? 0) * 100).rounded()))%",
                right: "\(localizedString("User")) \(Int(((p.lastUserLoad ?? 0) * 100).rounded()))%"
            )
        }

        if let tile = self.tiles["GPU"], let p = self.portal("GPU", as: CombinedGPUPortal.self) {
            let usage = (p.lastUtilization ?? 0) * 100
            let color = self.threshold(usage, warn: 75, critical: 92)
            var right = ""
            if let ane = p.lastANEUtilization {
                right = "ANE \(Int((ane * 100).rounded()))%"
            }
            tile.set(
                value: "\(Int(usage.rounded()))%",
                valueColor: .labelColor,
                fraction: usage / 100, barColor: color,
                left: "Render \(Int(((p.lastRenderUtilization ?? 0) * 100).rounded()))%",
                right: right
            )
        }

        if let tile = self.tiles["RAM"], let p = self.portal("RAM", as: CombinedRAMPortal.self) {
            let usage = (p.lastUsage ?? 0) * 100
            var color = self.threshold(usage, warn: 80, critical: 92)
            if let pressure = p.lastPressure, pressure != .normal {
                color = pressure.pressureColor()
            }
            var left = ""
            if let used = p.lastUsedBytes, let total = p.lastTotalBytes {
                left = "\(Units(bytes: Int64(used)).getReadableMemory(style: .memory)) / \(Units(bytes: Int64(total)).getReadableMemory(style: .memory))"
            }
            tile.set(
                value: "\(Int(usage.rounded()))%",
                valueColor: .labelColor,
                fraction: usage / 100, barColor: color,
                left: left,
                right: p.lastPressure.map { localizedString($0.rawValue.capitalized) } ?? ""
            )
        }

        if let tile = self.tiles["Disk"], let p = self.portal("Disk", as: CombinedDiskPortal.self) {
            let usage = (p.lastPercentage ?? 0) * 100
            let color = self.threshold(usage, warn: 85, critical: 95)
            var left = ""
            if let free = p.lastFreeBytes {
                left = "\(localizedString("Free")) \(DiskSize(free).getReadableMemory())"
            }
            var right = ""
            if let read = p.lastReadBytes, let write = p.lastWriteBytes {
                right = "R \(Units(bytes: read).getReadableSpeed()) W \(Units(bytes: write).getReadableSpeed())"
            }
            tile.set(
                value: "\(Int(usage.rounded()))%",
                valueColor: .labelColor,
                fraction: usage / 100, barColor: color,
                left: left,
                right: right
            )
        }

        if let tile = self.tiles["Network"], let p = self.portal("Network", as: CombinedNetPortal.self) {
            let down = p.lastDownloadBytes ?? 0
            let up = p.lastUploadBytes ?? 0
            tile.push(down: Double(down), up: Double(up))
            tile.set(
                value: "↓ \(Units(bytes: down).getReadableSpeed())",
                valueColor: .labelColor,
                fraction: nil, barColor: .systemBlue,
                left: "↑ \(Units(bytes: up).getReadableSpeed())",
                right: p.lastPublicIP ?? ""
            )
        }

        if let tile = self.tiles["Sensors"], let p = self.portal("Sensors", as: CombinedSensorsPortal.self) {
            let temp = p.lastMaxTempValue ?? 0
            let color = self.threshold(temp, warn: 75, critical: 90)
            var left = ""
            if let fan = p.lastFanSpeed {
                left = "\(localizedString("Fan")) \(Int(fan)) RPM"
            }
            tile.set(
                value: p.lastMaxTemp ?? "–",
                valueColor: .labelColor,
                fraction: min(temp / 100, 1), barColor: color,
                left: left,
                right: p.lastPower ?? ""
            )
        }
    }
}

// MARK: - tile

// One metric card in the overview grid. The NSStackView subclass carries the
// visual card chrome itself (fill/border/shadow via applyCardStyle) so the
// grid's 8pt spacing reads as "gaps between floating cards", and content is
// laid out with native macOS metrics: 10pt symbol + 11pt label, 20pt display
// value, 10pt secondary row.
internal class MetricTile: NSStackView {
    enum Viz { case bar, sparkline }

    private let moduleName: String
    private let accent: NSColor
    private let valueField = NSTextField(labelWithString: "–")
    private let leftField = NSTextField(labelWithString: "")
    private let rightField = NSTextField(labelWithString: "")
    private let bar = TileBarView()
    private let spark = TileSparklineView()

    // cached last values — NSTextField.stringValue assignment triggers
    // layout even when the string is identical, so diffing here avoids
    // 6 tiles × 3 fields = 18 redundant assignments every second.
    private var lastValue: String = ""
    private var lastValueColor: NSColor = .clear
    private var lastLeft: String = ""
    private var lastRight: String = ""
    private var lastFraction: Double = -1
    private var lastBarColor: NSColor = .clear
    private var isHovered: Bool = false

    init(module: String, symbol: String, viz: Viz) {
        self.moduleName = module
        self.accent = Design.moduleAccent(module)

        super.init(frame: .zero)

        self.wantsLayer = true
        self.applyCardStyle()
        self.toolTip = localizedString(module)

        self.orientation = .vertical
        self.alignment = .leading
        self.distribution = .fill
        self.spacing = 0
        self.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)

        // header: colored SF Symbol + 11pt medium title — macOS control-header style
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 5
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: module)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = self.accent
        let title = NSTextField(labelWithString: localizedString(module))
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .labelColor
        header.addArrangedSubview(icon)
        header.addArrangedSubview(title)
        self.addArrangedSubview(header)
        self.setCustomSpacing(2, after: header)

        // display value: 20pt semibold tabular — the hero number
        self.valueField.font = Design.valueFont
        self.addArrangedSubview(self.valueField)
        self.setCustomSpacing(5, after: self.valueField)

        switch viz {
        case .bar:
            self.bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
            self.addArrangedSubview(self.bar)
            self.bar.widthAnchor.constraint(equalTo: self.widthAnchor, constant: -28).isActive = true
            self.setCustomSpacing(4, after: self.bar)
        case .sparkline:
            self.spark.heightAnchor.constraint(equalToConstant: 10).isActive = true
            self.addArrangedSubview(self.spark)
            self.spark.widthAnchor.constraint(equalTo: self.widthAnchor, constant: -28).isActive = true
            self.setCustomSpacing(4, after: self.spark)
        }

        // secondary row: 10pt tertiary, left/right split
        let secondary = NSStackView()
        secondary.orientation = .horizontal
        secondary.distribution = .fill
        secondary.alignment = .firstBaseline
        self.leftField.font = .systemFont(ofSize: 10.5, weight: .medium)
        self.leftField.textColor = .secondaryLabelColor
        self.leftField.lineBreakMode = .byTruncatingTail
        self.rightField.font = .systemFont(ofSize: 10.5, weight: .medium)
        self.rightField.textColor = .secondaryLabelColor
        self.rightField.alignment = .right
        self.rightField.lineBreakMode = .byTruncatingTail
        self.rightField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        secondary.addArrangedSubview(self.leftField)
        secondary.addArrangedSubview(NSView())
        secondary.addArrangedSubview(self.rightField)
        self.addArrangedSubview(secondary)
        secondary.widthAnchor.constraint(equalTo: self.widthAnchor, constant: -28).isActive = true

        let click = NSClickGestureRecognizer(target: self, action: #selector(self.openModulePopup))
        self.addGestureRecognizer(click)

        self.addTrackingArea(NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        self.trackingAreas.forEach { self.removeTrackingArea($0) }
        self.addTrackingArea(NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    public override func mouseEntered(with event: NSEvent) {
        self.isHovered = true
        if #unavailable(macOS 26.0) {
            self.animateSurface(to: Design.cardHoverFill)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        self.isHovered = false
        if #unavailable(macOS 26.0) {
            self.animateSurface(to: Design.cardFill)
        }
    }

    public override func updateLayer() {
        self.applyCardStyle()
        if #unavailable(macOS 26.0), self.isHovered {
            self.layer?.backgroundColor = Design.cardHoverFill.cgColor
        }
    }

    private func animateSurface(to color: NSColor) {
        guard let layer = self.layer else { return }
        let transition = CABasicAnimation(keyPath: "backgroundColor")
        transition.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        transition.toValue = color.cgColor
        transition.duration = 0.16
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(transition, forKey: "surface")
        layer.backgroundColor = color.cgColor
    }

    public override func resetCursorRects() {
        self.addCursorRect(self.bounds, cursor: .pointingHand)
    }

    func set(value: String, valueColor: NSColor, fraction: Double?, barColor: NSColor, left: String, right: String) {
        if value != self.lastValue {
            self.lastValue = value
            self.valueField.stringValue = value
        }
        if valueColor != self.lastValueColor {
            self.lastValueColor = valueColor
            self.valueField.textColor = valueColor
        }
        if let fraction, fraction != self.lastFraction || barColor != self.lastBarColor {
            self.lastFraction = fraction
            self.lastBarColor = barColor
            self.bar.set(fraction: fraction, color: barColor)
        }
        if left != self.lastLeft {
            self.lastLeft = left
            self.leftField.stringValue = left
        }
        if right != self.lastRight {
            self.lastRight = right
            self.rightField.stringValue = right
        }
    }

    func push(down: Double, up: Double) {
        self.spark.push(down: down, up: up)
    }

    @objc private func openModulePopup() {
        guard let window = self.window else { return }
        let rect = window.convertToScreen(self.convert(self.bounds, to: nil))
        NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: [
            "module": self.moduleName,
            "origin": rect.origin,
            "center": rect.width / 2
        ])
    }
}

// MARK: - micro visualizations

private class TileBarView: NSView {
    private var fraction: Double = 0
    private var color: NSColor = .systemBlue

    func set(fraction: Double, color: NSColor) {
        self.fraction = max(0, min(fraction, 1))
        self.color = color
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard self.bounds.height > 0 else { return }
        let radius = self.bounds.height / 2
        let track = NSBezierPath(roundedRect: self.bounds, xRadius: radius, yRadius: radius)
        Design.track.setFill()
        track.fill()

        guard self.fraction > 0 else { return }

        let w = max(self.bounds.width * CGFloat(self.fraction), self.bounds.height)
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: self.bounds.height), xRadius: radius, yRadius: radius)

        // A restrained highlight gives the meter depth while retaining the
        // quiet appearance of native macOS progress indicators.
        let lighter = self.color.highlight(withLevel: 0.22) ?? self.color
        let grad = NSGradient(starting: self.color, ending: lighter)
        grad?.draw(in: fill, angle: 90)
    }
}

private class TileSparklineView: NSView {
    private var down: [Double] = []
    private var up: [Double] = []
    private let capacity = 60

    func push(down: Double, up: Double) {
        self.down.append(down)
        self.up.append(up)
        if self.down.count > self.capacity {
            self.down.removeFirst(self.down.count - self.capacity)
            self.up.removeFirst(self.up.count - self.capacity)
        }
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard self.down.count > 1 else { return }
        let peak = max(self.down.max() ?? 1, self.up.max() ?? 1, 1)
        let h = self.bounds.height - 1
        let step = self.bounds.width / CGFloat(self.capacity - 1)
        let offset = CGFloat(self.capacity - self.down.count) * step

        func line(_ series: [Double], _ color: NSColor) {
            let path = NSBezierPath()
            for (i, v) in series.enumerated() {
                let point = NSPoint(x: offset + CGFloat(i) * step, y: 0.5 + h * CGFloat(v / peak))
                i == 0 ? path.move(to: point) : path.line(to: point)
            }
            path.lineWidth = 1
            color.setStroke()
            path.stroke()
        }

        line(self.up, NSColor.systemGray.withAlphaComponent(0.7))
        line(self.down, .systemBlue)
    }
}

// MARK: - shared card look

// A real AppKit glass surface used behind every dashboard card. It is strictly
// visual: input continues to the card's existing controls and gestures.
@available(macOS 26.0, *)
private final class LiquidGlassCardSurface: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

internal extension NSView {
    // macOS 26 grouped-content card: a faint neutral fill lifts the card off
    // the panel glass, a hairline light border catches the top edge, and a
    // soft shadow grounds it. Replaces the previous "everything transparent"
    // approach that made the panel read as one flat gray slab.
    func applyCardStyle() {
        let liquidRadius: CGFloat = {
            if self is MetricTile { return 22 }
            if self is ProxyPortal || self is LauncherPortal { return 20 }
            return 28
        }()

        if #available(macOS 26.0, *) {
            let surfaceID = NSUserInterfaceItemIdentifier("StatsLiquidGlassCardSurface")
            let surface: LiquidGlassCardSurface
            if let existing = self.subviews.first(where: { $0.identifier == surfaceID }) as? LiquidGlassCardSurface {
                surface = existing
            } else {
                surface = LiquidGlassCardSurface(frame: self.bounds)
                surface.identifier = surfaceID
                surface.autoresizingMask = [.width, .height]
                // Dense information cards use regular glass for dependable
                // contrast. Compact utility strips use clear glass, matching
                // the desktop-widget treatment without sacrificing legibility.
                surface.style = (self is ProxyPortal || self is LauncherPortal) ? .clear : .regular
                surface.cornerRadius = liquidRadius
                // No synthetic gray wash: the system glass renderer samples
                // and refracts the real scene behind the card by itself.
                surface.tintColor = nil
                if #available(macOS 27.0, *) {
                    surface.effectIsInteractive = self is MetricTile || self is ProxyPortal || self is LauncherPortal
                }
                self.addSubview(surface, positioned: .below, relativeTo: nil)
            }
            surface.frame = self.bounds
            surface.cornerRadius = liquidRadius
            self.layer?.backgroundColor = NSColor.clear.cgColor
            self.layer?.borderWidth = 0
        } else {
            self.layer?.backgroundColor = Design.cardFill.cgColor
            self.layer?.borderWidth = Design.cardBorderWidth
            self.layer?.borderColor = Design.cardBorder.cgColor
        }
        self.layer?.cornerRadius = liquidRadius
        self.layer?.masksToBounds = false
        if #available(macOS 26.0, *) {
            // NSGlassEffectView already supplies its own optical edge and
            // depth. A second CALayer shadow spills farther than the 10pt
            // dashboard gap, causing aligned cards to form a continuous
            // vertical line that reads as an outer frame.
            self.layer?.shadowOpacity = 0
            self.layer?.shadowRadius = 0
        } else {
            self.layer?.shadowColor = Design.cardShadow.cgColor
            self.layer?.shadowOffset = NSSize(width: 0, height: -2)
            self.layer?.shadowRadius = 5
            self.layer?.shadowOpacity = 1
        }
    }

    // Transparent variant: no fill/border/shadow. Used by containers that
    // manage their own card subviews (e.g. MetricTile wraps content itself).
    func applyClearStyle() {
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.layer?.borderWidth = 0
        self.layer?.cornerRadius = 0
        self.layer?.shadowOpacity = 0
    }
}
