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

// MARK: - grid

internal class MetricTilesGrid: NSStackView {
    static let tileHeight: CGFloat = 78

    private var tiles: [String: MetricTile] = [:]
    private var heightConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        self.orientation = .vertical
        self.spacing = 8
        self.distribution = .fill
        self.alignment = .width
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

        let columns = max(1, min(3, Int(width / 240), active.count))

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
        if value >= critical { return .systemRed }
        if value >= warn { return .systemOrange }
        return .systemBlue
    }

    func refresh() {
        if let tile = self.tiles["CPU"], let p = self.portal("CPU", as: CombinedCPUPortal.self) {
            let usage = (p.lastUsage ?? 0) * 100
            let color = self.threshold(usage, warn: 60, critical: 85)
            tile.set(
                value: "\(Int(usage.rounded()))%",
                valueColor: usage >= 60 ? color : .labelColor,
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
                valueColor: usage >= 75 ? color : .labelColor,
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
                valueColor: (p.lastPressure ?? .normal) != .normal ? color : .labelColor,
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
                valueColor: usage >= 85 ? color : .labelColor,
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
                valueColor: temp >= 75 ? color : .labelColor,
                fraction: min(temp / 100, 1), barColor: color,
                left: left,
                right: p.lastPower ?? ""
            )
        }
    }
}

// MARK: - tile

internal class MetricTile: NSStackView {
    enum Viz { case bar, sparkline }

    private let moduleName: String
    private let valueField = NSTextField(labelWithString: "–")
    private let leftField = NSTextField(labelWithString: "")
    private let rightField = NSTextField(labelWithString: "")
    private let bar = TileBarView()
    private let spark = TileSparklineView()

    init(module: String, symbol: String, viz: Viz) {
        self.moduleName = module

        super.init(frame: .zero)

        self.wantsLayer = true
        self.applyCardStyle()
        self.toolTip = localizedString(module)

        self.orientation = .vertical
        self.alignment = .leading
        self.distribution = .fill
        self.spacing = 3
        self.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 4
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: module)
        icon.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: localizedString(module))
        title.font = .systemFont(ofSize: 9, weight: .medium)
        title.textColor = .secondaryLabelColor
        header.addArrangedSubview(icon)
        header.addArrangedSubview(title)
        self.addArrangedSubview(header)

        self.valueField.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        self.addArrangedSubview(self.valueField)

        switch viz {
        case .bar:
            self.bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
            self.addArrangedSubview(self.bar)
            self.bar.widthAnchor.constraint(equalTo: self.widthAnchor, constant: -20).isActive = true
        case .sparkline:
            self.spark.heightAnchor.constraint(equalToConstant: 10).isActive = true
            self.addArrangedSubview(self.spark)
            self.spark.widthAnchor.constraint(equalTo: self.widthAnchor, constant: -20).isActive = true
        }

        let secondary = NSStackView()
        secondary.orientation = .horizontal
        secondary.distribution = .fill
        self.leftField.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        self.leftField.textColor = .tertiaryLabelColor
        self.leftField.lineBreakMode = .byTruncatingTail
        self.rightField.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        self.rightField.textColor = .tertiaryLabelColor
        self.rightField.alignment = .right
        self.rightField.lineBreakMode = .byTruncatingTail
        secondary.addArrangedSubview(self.leftField)
        secondary.addArrangedSubview(NSView())
        secondary.addArrangedSubview(self.rightField)
        self.addArrangedSubview(secondary)
        secondary.widthAnchor.constraint(equalTo: self.widthAnchor, constant: -20).isActive = true

        let click = NSClickGestureRecognizer(target: self, action: #selector(self.openModulePopup))
        self.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateLayer() {
        self.applyCardStyle()
    }

    public override func resetCursorRects() {
        self.addCursorRect(self.bounds, cursor: .pointingHand)
    }

    func set(value: String, valueColor: NSColor, fraction: Double?, barColor: NSColor, left: String, right: String) {
        self.valueField.stringValue = value
        self.valueField.textColor = valueColor
        if let fraction {
            self.bar.set(fraction: fraction, color: barColor)
        }
        self.leftField.stringValue = left
        self.rightField.stringValue = right
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
        let radius = self.bounds.height / 2
        let track = NSBezierPath(roundedRect: self.bounds, xRadius: radius, yRadius: radius)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.15).setFill()
        track.fill()

        let w = max(self.bounds.width * CGFloat(self.fraction), self.bounds.height)
        if self.fraction > 0 {
            let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: self.bounds.height), xRadius: radius, yRadius: radius)
            self.color.setFill()
            fill.fill()
        }
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

internal extension NSView {
    // unified card style for the combined overview: soft fill + hairline
    // border so cards stay visible on any popup backdrop, light or dark
    func applyCardStyle() {
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.layer?.borderColor = NSColor.separatorColor.cgColor
        self.layer?.borderWidth = 1
        self.layer?.cornerRadius = 6
    }
}
