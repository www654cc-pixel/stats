//
//  PowerFlowPortal.swift
//  Stats
//

import Cocoa
import Kit
import IOKit.ps

// MARK: - model

internal struct PowerFlowModel {
    var hasBattery: Bool = false
    var level: Double = 0            // 0...1
    var isCharging: Bool = false
    var externalConnected: Bool = false
    var isCharged: Bool = false
    var optimizedCharging: Bool = false
    var batteryWatts: Double = 0     // signed: >0 flows into the battery
    var acRatedWatts: Int = 0
    var timeToEmpty: Int = 0         // minutes
    var timeToFull: Int = 0          // minutes
    var health: Int? = nil

    var systemTotal: Double? = nil   // PSTR
    var dcIn: Double? = nil          // PDTR
    var cpu: Double? = nil
    var gpu: Double? = nil
    var display: Double? = nil       // PBLR (backlight)

    // derived, all in watts and non-negative
    var charge: Double { max(self.batteryWatts, 0) }
    var discharge: Double { max(-self.batteryWatts, 0) }
    var system: Double {
        if let v = self.systemTotal, v > 0.1 { return v }
        // PSTR unavailable: reconstruct from what the battery/adapter deliver
        let adapter = max(self.dcIn ?? 0, 0)
        return max(adapter - self.charge, 0) + self.discharge
    }
    var others: Double {
        max(self.system - (self.cpu ?? 0) - (self.gpu ?? 0) - (self.display ?? 0), 0)
    }
}

// MARK: - compact portal (status bar)

internal class PowerFlowPortal: NSStackView {
    private let headerHeight: CGFloat = 22
    private let barHeight: CGFloat = 16
    private let heroHeight: CGFloat = 60

    internal var onResize: (() -> Void)?
    // false when there is neither a battery nor any power sensor data
    internal private(set) var available: Bool = true

    private let titleField = NSTextField(labelWithString: localizedString("System Overview"))
    private let statusChip = PowerChip()
    private let healthChip = PowerChip()
    private let levelBar = BatteryLevelBar()
    private let infoField = NSTextField(labelWithString: "")
    private let totalField = NSTextField(labelWithString: "–")
    private let sourceField = NSTextField(labelWithString: "")
    private let breakdown = PowerBreakdownView()
    private let heroGrid = NSGridView()

    private var refreshTimer: Timer?
    private var topTicker: Int = 0
    private var topIsRunning: Bool = false
    // EMA state for battery watts: raw Amperage×Voltage samples are instantaneous
    // and jittery (2-3x PSTR at times); smooth them to the same time scale as the
    // SMC power rails so the reading roughly conserves energy.
    private var batteryWattsEMA: Double? = nil
    private var topProcessName: String?
    private var topProcessUsage: Double = 0

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))

        self.wantsLayer = true
        self.applyCardStyle()

        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = 10
        self.edgeInsets = NSEdgeInsets(top: 13, left: 16, bottom: 13, right: 16)

        self.titleField.font = Design.labelMediumFont
        self.titleField.textColor = Design.titleColor

        let header = NSStackView()
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 6
        header.heightAnchor.constraint(equalToConstant: self.headerHeight).isActive = true

        // native macOS section-header: small colored bolt icon + 11pt medium title
        let boltIcon = NSImageView()
        boltIcon.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
        boltIcon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        boltIcon.contentTintColor = .systemYellow
        boltIcon.setContentHuggingPriority(.required, for: .horizontal)
        header.addArrangedSubview(boltIcon)
        header.addArrangedSubview(self.titleField)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(self.healthChip)
        header.addArrangedSubview(self.statusChip)
        header.addArrangedSubview(self.headerButton(symbol: "chart.bar.fill", tooltip: localizedString("Open Activity Monitor"), action: #selector(self.openActivityMonitor)))
        header.addArrangedSubview(self.headerButton(symbol: "gearshape", tooltip: localizedString("Open module"), action: #selector(self.openCombinedSettings)))
        self.addArrangedSubview(header)

        // Hero body: a large total-power readout, battery state, then a live
        // component breakdown. The unequal visual weights make the card read
        // as a system overview instead of another full-width progress row.
        let summary = NSStackView()
        summary.orientation = .vertical
        summary.alignment = .leading
        summary.spacing = 0
        let summaryLabel = NSTextField(labelWithString: localizedString("System Power"))
        summaryLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        summaryLabel.textColor = .secondaryLabelColor
        self.totalField.font = NSFont.monospacedDigitSystemFont(ofSize: 25, weight: .semibold)
        self.totalField.textColor = .labelColor
        self.sourceField.font = .systemFont(ofSize: 10.5, weight: .regular)
        self.sourceField.textColor = .secondaryLabelColor
        summary.addArrangedSubview(summaryLabel)
        summary.addArrangedSubview(self.totalField)
        summary.addArrangedSubview(self.sourceField)

        let battery = NSStackView()
        battery.orientation = .vertical
        battery.alignment = .width
        battery.spacing = 7
        let batteryLabel = NSTextField(labelWithString: localizedString("Battery"))
        batteryLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        batteryLabel.textColor = .secondaryLabelColor
        battery.addArrangedSubview(batteryLabel)
        self.levelBar.heightAnchor.constraint(equalToConstant: self.barHeight).isActive = true
        battery.addArrangedSubview(self.levelBar)
        self.infoField.font = .systemFont(ofSize: 10.5, weight: .regular)
        self.infoField.textColor = .secondaryLabelColor
        self.infoField.lineBreakMode = .byTruncatingTail
        battery.addArrangedSubview(self.infoField)
        self.heroGrid.addRow(with: [summary, PowerDivider(), battery, PowerDivider(), self.breakdown])
        self.heroGrid.columnSpacing = 14
        self.heroGrid.rowSpacing = 0
        self.heroGrid.row(at: 0).height = self.heroHeight
        self.heroGrid.row(at: 0).yPlacement = .center
        for index in 0..<self.heroGrid.numberOfColumns {
            self.heroGrid.column(at: index).xPlacement = .fill
        }
        self.addArrangedSubview(self.heroGrid)

        let height = self.edgeInsets.top + self.edgeInsets.bottom
            + self.headerHeight + self.heroHeight + self.spacing
        self.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateLayer() {
        self.applyCardStyle()
    }

    private func headerButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.isBordered = false
        button.focusRingType = .none
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    @objc private func openActivityMonitor() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.open([], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openCombinedSettings() {
        NotificationCenter.default.post(name: .toggleSettings, object: nil, userInfo: ["module": localizedString("System Overview")])
    }

    private var widthConstraint: NSLayoutConstraint?

    internal func setWidth(_ width: CGFloat) {
        // frames are advisory under NSStackView layout; pin an explicit
        // constraint like the other cards or the hero collapses to its
        // fitting width
        self.widthConstraint?.isActive = false
        self.widthConstraint = self.widthAnchor.constraint(equalToConstant: width)
        self.widthConstraint?.isActive = true

        // Explicit 20 / 34 / 46 composition. NSGridView owns the widths, so
        // AppKit cannot center the intrinsic content and leave a blank lead-in.
        let gaps = self.heroGrid.columnSpacing * 4
        let dividers: CGFloat = 2
        let content = max(width - self.edgeInsets.left - self.edgeInsets.right - gaps - dividers, 0)
        let summary = content * 0.22
        let battery = content * 0.36
        self.heroGrid.column(at: 0).width = summary
        self.heroGrid.column(at: 1).width = 1
        self.heroGrid.column(at: 2).width = battery
        self.heroGrid.column(at: 3).width = 1
        self.heroGrid.column(at: 4).width = max(content - summary - battery, 0)
    }

    internal func start() {
        self.refresh()
        self.refreshTimer?.invalidate()
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    internal func stop() {
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
    }

    // MARK: - data

    private func sensorsPortal() -> CombinedSensorsPortal? {
        guard let m = modules.first(where: { $0.name == "Sensors" && $0.enabled }) else { return nil }
        return m.portal as? CombinedSensorsPortal
    }

    private func refresh() {
        var model = PowerFlowModel()
        self.readBattery(into: &model)

        // smooth battery watts with an EMA (~10 s time constant at a 2 s tick);
        // reset when the flow direction flips (charge <-> discharge)
        let rawWatts = model.batteryWatts
        if let ema = self.batteryWattsEMA, ema * rawWatts >= 0 {
            self.batteryWattsEMA = 0.3 * rawWatts + 0.7 * ema
        } else {
            self.batteryWattsEMA = rawWatts
        }
        model.batteryWatts = self.batteryWattsEMA ?? rawWatts

        if let flow = self.sensorsPortal()?.lastPowerFlow {
            model.systemTotal = flow.systemTotal
            model.dcIn = flow.dcIn
            model.cpu = flow.cpu
            model.gpu = flow.gpu
            model.display = flow.display
            // the IOReport energy-model CPU channel is dead on M5 (macOS 27):
            // fall back to the SMC supply rails when a reading is missing/zero
            if (model.cpu ?? 0) < 0.05, let rail = flow.cpuRail { model.cpu = rail }
            if (model.gpu ?? 0) < 0.05, let rail = flow.gpuRail { model.gpu = rail }
        }

        let wasAvailable = self.available
        self.available = model.hasBattery || model.systemTotal != nil
        if self.available != wasAvailable {
            self.isHidden = !self.available
            self.onResize?()
        }
        guard self.available else { return }

        self.updateChips(model)
        self.levelBar.update(model)
        self.levelBar.isHidden = !model.hasBattery
        self.totalField.stringValue = model.system > 0.05 ? self.watts(model.system) : "–"
        self.sourceField.stringValue = model.externalConnected
            ? localizedString("External Power")
            : localizedString("On battery")
        self.breakdown.update(model)
        self.updateInfo(model)

        // resample the top process every third tick (~6s)
        if self.topTicker % 3 == 0 { self.sampleTopProcesses() }
        self.topTicker += 1
    }

    private func updateInfo(_ model: PowerFlowModel) {
        var parts: [String] = []
        if let sys = model.systemTotal, sys > 0.1 {
            parts.append("\(localizedString("System")) \(self.watts(sys))")
        } else if let dc = model.dcIn, dc > 0.1 {
            parts.append("适配器 \(self.watts(dc))")
        }
        if let cpu = model.cpu, cpu > 0.05 {
            parts.append("CPU \(self.watts(cpu))")
        }
        if let gpu = model.gpu, gpu > 0.05 {
            parts.append("GPU \(self.watts(gpu))")
        }
        if let name = self.topProcessName, self.topProcessUsage >= 1 {
            parts.append("\(name) \(String(format: "%.0f%%", self.topProcessUsage))")
        }
        self.infoField.stringValue = parts.joined(separator: "   ")
    }

    private func readBattery(into model: inout PowerFlowModel) {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps).takeUnretainedValue() as? [String: Any] else { continue }
            model.hasBattery = true
            model.level = Double(desc[kIOPSCurrentCapacityKey] as? Int ?? 0) / 100
            model.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            model.externalConnected = (desc[kIOPSPowerSourceStateKey] as? String ?? "") != "Battery Power"
            model.isCharged = desc[kIOPSIsChargedKey] as? Bool ?? false
            model.optimizedCharging = desc["Optimized Battery Charging Engaged"] as? Int == 1
            model.timeToEmpty = desc[kIOPSTimeToEmptyKey] as? Int ?? 0
            model.timeToFull = desc[kIOPSTimeToFullChargeKey] as? Int ?? 0
        }

        if let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            model.acRatedWatts = details[kIOPSPowerAdapterWattsKey] as? Int ?? 0
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func intProp(_ key: String) -> Int? {
                guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
                return raw.takeRetainedValue() as? Int
            }
            if let amperage = intProp("Amperage"), let voltage = intProp("Voltage") {
                model.batteryWatts = Double(amperage) * Double(voltage) / 1_000_000 // mA x mV -> W
            }
            // macOS 27 reports "(no estimate)" via IOPS, so the keys above read 0;
            // the battery gas gauge still computes smoothed averages — fall back to them.
            // 65535 (0xFFFF) is the gauge's "invalid" placeholder.
            if model.timeToEmpty <= 0, let t = intProp("AvgTimeToEmpty"), t > 0, t < 65535 {
                model.timeToEmpty = t
            }
            if model.timeToFull <= 0, let t = intProp("AvgTimeToFull"), t > 0, t < 65535 {
                model.timeToFull = t
            }
            // Apple Silicon reports capacities inside BatteryData (in mAh);
            // the top-level MaxCapacity is just a percentage there.
            // Health uses FullChargeCapacity (actual full-charge), not the
            // optimistic NominalChargeCapacity.
            if let raw = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0),
               let data = raw.takeRetainedValue() as? [String: Any],
               let full = data["FullChargeCapacity"] as? Int,
               let design = data["DesignCapacity"] as? Int, design > 0 {
                model.health = Int((Double(full * 100) / Double(design)).rounded())
            } else if let maxCap = intProp("AppleRawMaxCapacity"),
                      let design = intProp("DesignCapacity"), design > 0, maxCap > 100 {
                model.health = Int((Double(maxCap * 100) / Double(design)).rounded())
            }
        }
    }

    private func updateChips(_ model: PowerFlowModel) {
        guard model.hasBattery else {
            self.statusChip.isHidden = true
            self.healthChip.isHidden = true
            return
        }

        var text: String
        var color: NSColor = .systemGray
        var symbol: String = "powerplug.fill"
        var minutes: Int = 0

        if !model.externalConnected {
            text = localizedString("On battery")
            symbol = "battery.100"
            color = model.level > 0.15 ? .systemGray : .systemRed
            minutes = model.timeToEmpty
        } else if model.isCharging {
            text = localizedString("Charging")
            symbol = "bolt.fill"
            color = .systemGreen
            minutes = model.timeToFull
        } else if model.isCharged || model.level >= 1 {
            text = localizedString("Fully charged")
        } else if model.optimizedCharging {
            text = localizedString("On hold")
        } else {
            text = localizedString("Plugged in")
        }

        if minutes > 0 {
            text += " · " + Double(minutes * 60).printSecondsToHoursMinutesSeconds(short: true)
        }
        self.statusChip.set(text: text, symbol: symbol, color: color)
        self.statusChip.isHidden = false

        if let health = model.health {
            self.healthChip.set(text: "\(localizedString("Health")) \(health)%", symbol: "heart.fill", color: health >= 80 ? .systemGray : .systemOrange)
            self.healthChip.isHidden = false
        } else {
            self.healthChip.isHidden = true
        }
    }

    // MARK: - top processes

    private func sampleTopProcesses() {
        guard !self.topIsRunning else { return }
        self.topIsRunning = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = PowerFlowPortal.readTopProcesses(count: 1)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.topIsRunning = false
                if let p = list.first, p.usage >= 1.0 {
                    self.topProcessName = p.name
                    self.topProcessUsage = p.usage
                } else {
                    self.topProcessName = nil
                    self.topProcessUsage = 0
                }
            }
        }
    }

    /// Top processes by CPU%, sampled via libproc (proc_pid_rusage) instead of
    /// forking `top`. Two samples 200 ms apart on this background thread, then
    /// the CPU-time delta is converted to a percentage of one core. This avoids
    /// the 3-8 % CPU spike that `top -l 2` caused every 6 seconds.
    static private func readTopProcesses(count: Int) -> [TopProcess] {
        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(pidCount))
        let actualCount = proc_listallpids(&pids, pidCount)
        guard actualCount > 0 else { return [] }

        let all = Array(pids.prefix(Int(actualCount)))
        let intervalNs: Double = 200_000_000 // 200 ms

        func cpuTime(_ pid: pid_t) -> UInt64? {
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: (rusage_info_t?.self), capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            return result == -1 ? nil : usage.ri_user_time + usage.ri_system_time
        }

        var t1: [pid_t: UInt64] = [:]
        for pid in all { if let v = cpuTime(pid) { t1[pid] = v } }

        usleep(200_000) // 200 ms — far cheaper than top's multi-second run

        var deltas: [(pid: pid_t, pct: Double)] = []
        for pid in all {
            guard let a = t1[pid], let b = cpuTime(pid) else { continue }
            let delta = b > a ? Double(b - a) : 0
            deltas.append((pid, delta / intervalNs * 100))
        }
        deltas.sort { $0.pct > $1.pct }

        return deltas.prefix(count).map { d in
            var name = "pid \(d.pid)"
            if let app = NSRunningApplication(processIdentifier: d.pid), let n = app.localizedName {
                name = n
            }
            return TopProcess(pid: Int(d.pid), name: name, usage: d.pct)
        }
    }

    private func watts(_ value: Double) -> String {
        String(format: "%.1f W", value)
    }
}

// MARK: - hero details

private final class PowerDivider: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = Design.divider.cgColor
        self.widthAnchor.constraint(equalToConstant: 1).isActive = true
        self.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }
}

private final class PowerBreakdownView: NSStackView {
    private var values: [NSTextField] = []

    init() {
        super.init(frame: .zero)
        self.orientation = .horizontal
        self.alignment = .centerY
        self.distribution = .fillEqually
        self.spacing = 12

        let items: [(String, String, NSColor)] = [
            ("CPU", "cpu", .systemBlue),
            ("GPU", "square.grid.3x3.fill", .systemPurple),
            (localizedString("Display"), "display", .systemTeal),
            (localizedString("Other"), "ellipsis.circle", .systemGray)
        ]
        for item in items {
            let cell = NSStackView()
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 2

            let header = NSStackView()
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = 4
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: item.1, accessibilityDescription: item.0)
            icon.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
            icon.contentTintColor = item.2
            let label = NSTextField(labelWithString: item.0)
            label.font = .systemFont(ofSize: 10.5, weight: .medium)
            label.textColor = .secondaryLabelColor
            header.addArrangedSubview(icon)
            header.addArrangedSubview(label)

            let value = NSTextField(labelWithString: "–")
            value.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            value.textColor = .labelColor
            cell.addArrangedSubview(header)
            cell.addArrangedSubview(value)
            self.values.append(value)
            self.addArrangedSubview(cell)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:)") }

    func update(_ model: PowerFlowModel) {
        let readings = [model.cpu, model.gpu, model.display, model.others]
        for (index, reading) in readings.enumerated() where index < self.values.count {
            if let value = reading, value > 0.01 {
                self.values[index].stringValue = String(format: "%.1f W", value)
            } else {
                self.values[index].stringValue = "–"
            }
        }
    }
}

// MARK: - chip

private class PowerChip: NSStackView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        self.orientation = .horizontal
        self.alignment = .centerY
        self.spacing = 4
        self.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        self.wantsLayer = true
        self.layer?.cornerRadius = 8

        self.icon.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        self.label.font = NSFont.systemFont(ofSize: 10, weight: .medium)

        self.addArrangedSubview(self.icon)
        self.addArrangedSubview(self.label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(text: String, symbol: String, color: NSColor) {
        self.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        self.icon.contentTintColor = color
        self.label.stringValue = text
        self.label.textColor = color
        self.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
    }
}

// MARK: - battery level bar

private class BatteryLevelBar: NSView {
    private var level: Double = 0
    private var charging: Bool = false
    private var limited: Bool = false

    func update(_ model: PowerFlowModel) {
        self.level = max(0, min(model.level, 1))
        self.charging = model.isCharging
        self.limited = model.optimizedCharging
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = self.bounds.width
        let h = self.bounds.height
        guard w > 20, h > 4 else { return }
        let radius = h / 2

        let track = NSBezierPath(roundedRect: self.bounds, xRadius: radius, yRadius: radius)
        Design.track.setFill()
        track.fill()

        let fillW = max(h, w * CGFloat(self.level))
        let color = self.level.batteryColorV2()
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: fillW, height: h), xRadius: radius, yRadius: radius)

        // Native progress indicators use a quiet highlight rather than a neon
        // halo; the glass surface around the bar supplies the optical depth.
        let lighter = color.highlight(withLevel: 0.2) ?? color
        let grad = NSGradient(starting: color, ending: lighter)
        grad?.draw(in: fill, angle: 90)

        // optimized charging keeps the battery around 80%: mark that spot
        if self.limited {
            let x = w * 0.8
            let notch = NSBezierPath(rect: NSRect(x: x - 0.5, y: 1, width: 1.5, height: h - 2))
            NSColor.labelColor.withAlphaComponent(0.35).setFill()
            notch.fill()
        }

        // percent riding on the filled part
        let text = "\(Int((self.level * 100).rounded()))%"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        var x = fillW - size.width - 6
        var textColor = NSColor.white
        if x < 5 { // fill too small, draw next to it in the track
            x = fillW + 6
            textColor = NSColor.secondaryLabelColor
        }
        let colored = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: textColor
        ])
        colored.draw(at: NSPoint(x: x, y: (h - size.height) / 2))
    }
}
