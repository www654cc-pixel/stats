//
//  PowerFlowPortal.swift
//  Stats
//
//  Power-flow (sankey) card for the combined overview panel. Visualizes where
//  the energy comes from (adapter / battery) and where it goes (battery
//  charging, CPU, GPU, display, everything else), plus the most power-hungry
//  processes. Battery state is read directly from IOKit; rail wattages come
//  from the Sensors module portal (SMC + IOReport).
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

// MARK: - portal

internal class PowerFlowPortal: NSStackView {
    private let headerHeight: CGFloat = 20
    private let barHeight: CGFloat = 13
    private let sankeyHeight: CGFloat = 176
    private let processesTitleHeight: CGFloat = 15
    private let processRowHeight: CGFloat = 17
    private let processesCount: Int = 3

    internal var onResize: (() -> Void)?
    // false when there is neither a battery nor any power sensor data
    internal private(set) var available: Bool = true

    private let titleField = NSTextField(labelWithString: localizedString("Power flow"))
    private let statusChip = PowerChip()
    private let healthChip = PowerChip()
    private let levelBar = BatteryLevelBar()
    private let sankey = PowerSankeyView()
    private var processRows: [PowerProcessRow] = []

    private var refreshTimer: Timer?
    private var topTicker: Int = 0
    private var topIsRunning: Bool = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))

        self.wantsLayer = true
        self.applyCardStyle()

        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = 4
        self.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 6, right: 10)

        self.titleField.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        let header = NSStackView()
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 4
        header.heightAnchor.constraint(equalToConstant: self.headerHeight).isActive = true
        header.addArrangedSubview(self.titleField)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(self.healthChip)
        header.addArrangedSubview(self.statusChip)
        self.addArrangedSubview(header)

        self.levelBar.heightAnchor.constraint(equalToConstant: self.barHeight).isActive = true
        self.addArrangedSubview(self.levelBar)

        self.sankey.heightAnchor.constraint(equalToConstant: self.sankeyHeight).isActive = true
        self.addArrangedSubview(self.sankey)

        let processesTitle = NSTextField(labelWithString: localizedString("High power"))
        processesTitle.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        processesTitle.textColor = .secondaryLabelColor
        let processesHeader = NSStackView()
        processesHeader.orientation = .horizontal
        processesHeader.heightAnchor.constraint(equalToConstant: self.processesTitleHeight).isActive = true
        processesHeader.addArrangedSubview(processesTitle)
        processesHeader.addArrangedSubview(NSView())
        self.addArrangedSubview(processesHeader)

        for _ in 0..<self.processesCount {
            let row = PowerProcessRow(height: self.processRowHeight)
            self.processRows.append(row)
            self.addArrangedSubview(row)
        }

        let height = self.edgeInsets.top + self.edgeInsets.bottom
            + self.headerHeight + self.barHeight + self.sankeyHeight + self.processesTitleHeight
            + CGFloat(self.processesCount) * self.processRowHeight
            + self.spacing * CGFloat(4 + self.processesCount - 1)
        self.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateLayer() {
        self.applyCardStyle()
    }

    internal func setWidth(_ width: CGFloat) {
        self.setFrameSize(NSSize(width: width, height: self.frame.height))
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
        self.sankey.model = model
        self.sankey.needsDisplay = true

        // resample the per-process energy impact every third tick (~6s)
        if self.topTicker % 3 == 0 { self.sampleTopProcesses() }
        self.topTicker += 1
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
            // Apple Silicon reports capacities inside BatteryData (in mAh);
            // the top-level MaxCapacity is just a percentage there
            if let raw = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0),
               let data = raw.takeRetainedValue() as? [String: Any],
               let nominal = data["NominalChargeCapacity"] as? Int,
               let design = data["DesignCapacity"] as? Int, design > 0 {
                model.health = Int((Double(nominal * 100) / Double(design)).rounded())
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
            let list = PowerFlowPortal.readTopProcesses(count: self?.processesCount ?? 3)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.topIsRunning = false
                for (i, row) in self.processRows.enumerated() {
                    if i < list.count {
                        row.set(list[i])
                    } else {
                        row.clear()
                    }
                }
            }
        }
    }

    static private func readTopProcesses(count: Int) -> [TopProcess] {
        let task = Process()
        task.launchPath = "/usr/bin/top"
        task.arguments = ["-o", "power", "-l", "2", "-n", "\(count)", "-stats", "pid,command,power"]

        let outputPipe = Pipe()
        defer { outputPipe.fileHandleForReading.closeFile() }
        task.standardOutput = outputPipe

        do {
            try task.run()
        } catch {
            return []
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard !outputData.isEmpty,
              let output = String(data: outputData.advanced(by: outputData.count/2), encoding: .utf8) else { return [] }

        var processes: [TopProcess] = []
        output.enumerateLines { (line, _) in
            if line.matches("^\\d+ *[^(\\d)]*\\d+\\.*\\d* *$") {
                let str = line.trimmingCharacters(in: .whitespaces)
                let pidFind = str.findAndCrop(pattern: "^\\d+")
                let usageFind = pidFind.remain.findAndCrop(pattern: " +[0-9]+.*[0-9]*$")
                let command = usageFind.remain.trimmingCharacters(in: .whitespaces)
                let pid = Int(pidFind.cropped) ?? 0
                guard let usage = Double(usageFind.cropped.filter("01234567890.".contains)) else { return }

                var name: String = command
                if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let n = app.localizedName {
                    name = n
                }
                processes.append(TopProcess(pid: pid, name: name, usage: usage))
            }
        }

        return Array(processes.suffix(count).sorted(by: { $0.usage > $1.usage }))
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
        self.spacing = 3
        self.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        self.wantsLayer = true
        self.layer?.cornerRadius = 7

        self.icon.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        self.label.font = NSFont.systemFont(ofSize: 9, weight: .semibold)

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
        self.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
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
        NSColor.tertiaryLabelColor.withAlphaComponent(0.15).setFill()
        track.fill()

        let fillW = max(h, w * CGFloat(self.level))
        let color = self.level.batteryColorV2()
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: fillW, height: h), xRadius: radius, yRadius: radius)
        color.setFill()
        fill.fill()

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
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        var x = fillW - size.width - 5
        var textColor = NSColor.white
        if x < 4 { // fill too small, draw next to it in the track
            x = fillW + 5
            textColor = NSColor.secondaryLabelColor
        }
        let colored = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: textColor
        ])
        colored.draw(at: NSPoint(x: x, y: (h - size.height) / 2))
    }
}

// MARK: - sankey

private class PowerSankeyView: NSView {
    fileprivate var model = PowerFlowModel()

    override var isFlipped: Bool { true }

    private struct Endpoint {
        var x: CGFloat
        var top: CGFloat
        var height: CGFloat
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        guard bounds.width > 220, bounds.height > 80 else { return }
        let m = self.model

        let compact = bounds.width < 420
        let leftNodeW: CGFloat = compact ? 46 : 56
        let rightBlockW: CGFloat = compact ? 78 : 104
        let macSize = NSSize(width: compact ? 38 : 44, height: 40)
        let macCenterX = bounds.width * (compact ? 0.44 : 0.47)
        let leftX: CGFloat = 2

        let charge = m.charge
        let discharge = m.discharge
        // when on external power the system consumption is only known through PSTR
        let systemKnown = (m.systemTotal ?? 0) >= 1 || !m.externalConnected
        let system = max(m.system, 0.1)

        // watt -> px scale, sized so the busiest side fills the band
        let scaleBase = max(system + charge, 22)
        let band = bounds.height - 66
        let pxPerWatt = band / CGFloat(scaleBase)
        func thickness(_ watts: Double) -> CGFloat { max(CGFloat(watts) * pxPerWatt, watts > 0.05 ? 2.5 : 1) }

        guard systemKnown else {
            // sensors unavailable: only the adapter -> battery charge flow is known
            let nodeRect = NSRect(x: leftX, y: (bounds.height - 64)/2, width: leftNodeW, height: 64)
            let rated = m.acRatedWatts > 0 ? "\(m.acRatedWatts) W" : "AC"
            self.node(rect: nodeRect, symbol: "powerplug.fill", title: rated, color: .systemGray)
            if charge > 0.3 {
                let pill = NSRect(x: bounds.width * 0.6, y: (bounds.height - 20)/2, width: 44, height: 20)
                let t = thickness(charge)
                let tEnd = min(t, pill.height - 4)
                self.ribbon(
                    from: Endpoint(x: nodeRect.maxX, top: nodeRect.midY - t/2, height: t),
                    to: Endpoint(x: pill.minX, top: pill.midY - tEnd/2, height: tEnd),
                    color: .systemGreen, alpha: 0.5,
                    label: self.watts(charge)
                )
                self.pill(rect: pill, symbol: "battery.100.bolt", color: .systemGreen)
            }
            return
        }

        // ---- consumers (right side) ----
        var consumers: [(name: String, symbol: String, watts: Double, color: NSColor)] = []
        if m.cpu != nil || m.gpu != nil {
            consumers.append(("CPU", "cpu.fill", m.cpu ?? 0, .systemBlue))
            consumers.append(("GPU", "square.grid.3x3.fill", m.gpu ?? 0, .systemPurple))
        }
        if let d = m.display {
            consumers.append((localizedString("Display"), "sun.max.fill", d, .systemTeal))
        }
        let others = consumers.isEmpty ? system : m.others
        let othersIsTop = others >= consumers.map({ $0.watts }).max() ?? 0
        consumers.append((localizedString("Others"), "ellipsis", others, othersIsTop && others > 10 ? .systemOrange : .systemGray))

        // ---- flows into the mac node ----
        let adapterToSystem = m.externalConnected ? max(system - discharge, 0) : 0
        let chargeT = (m.externalConnected && charge > 0.3) ? thickness(charge) : 0
        let adapterT = m.externalConnected ? thickness(adapterToSystem) : 0
        let assistT = (m.externalConnected && discharge > 0.3) ? thickness(discharge) : 0
        let batteryT = m.externalConnected ? 0 : thickness(max(discharge, system))

        // ---- mac node ----
        let outSum = consumers.reduce(CGFloat(0)) { $0 + thickness($1.watts) }
        let inSum = adapterT + assistT + batteryT
        let macH = max(macSize.height, max(outSum, inSum) + 10)
        let macRect = NSRect(x: macCenterX - macSize.width/2, y: (bounds.height - macH)/2, width: macSize.width, height: macH)

        // ---- right endpoints: evenly spread rows, thickness capped to the row ----
        let endX = bounds.width - rightBlockW
        let rowH = (bounds.height - 8) / CGFloat(consumers.count)
        var rightEnds: [Endpoint] = []
        for (i, c) in consumers.enumerated() {
            let centerY = 4 + rowH * (CGFloat(i) + 0.5)
            let t = min(thickness(c.watts), rowH - 8)
            rightEnds.append(Endpoint(x: endX, top: centerY - t/2, height: t))
        }

        // ---- right ribbons out of the mac node ----
        var outCursor = macRect.midY - outSum/2
        for (i, c) in consumers.enumerated() {
            let t = thickness(c.watts)
            self.ribbon(from: Endpoint(x: macRect.maxX, top: outCursor, height: t), to: rightEnds[i], color: c.color, alpha: 0.42)
            outCursor += t
        }

        // ---- left sources ----
        var inCursor = macRect.midY - inSum/2
        if m.externalConnected {
            // adapter node: feeds the battery (when charging) and the system
            let outH = chargeT + adapterT
            let aH = max(56, outH + 24)
            let bH: CGFloat = assistT > 0 ? max(40, assistT + 16) : 0
            let totalH = aH + (bH > 0 ? bH + 10 : 0)
            let aRect = NSRect(x: leftX, y: (bounds.height - totalH)/2, width: leftNodeW, height: aH)
            let rated = m.acRatedWatts > 0 ? "\(m.acRatedWatts) W" : String(format: "%.0f W", m.dcIn ?? (system + charge))
            self.node(rect: aRect, symbol: "powerplug.fill", title: rated, color: .systemGray)

            var srcCursor = aRect.midY - outH/2
            if chargeT > 0 {
                // battery pill above the mac node
                let pill = NSRect(x: macRect.midX - 40, y: 6, width: 44, height: 20)
                let tEnd = min(chargeT, pill.height - 4)
                self.ribbon(
                    from: Endpoint(x: aRect.maxX, top: srcCursor, height: chargeT),
                    to: Endpoint(x: pill.minX, top: pill.midY - tEnd/2, height: tEnd),
                    color: .systemGreen, alpha: 0.5,
                    label: self.watts(charge)
                )
                self.pill(rect: pill, symbol: "battery.100.bolt", color: .systemGreen)
                srcCursor += chargeT
            }
            if adapterT > 0 {
                self.ribbon(
                    from: Endpoint(x: aRect.maxX, top: srcCursor, height: adapterT),
                    to: Endpoint(x: macRect.minX, top: inCursor, height: adapterT),
                    color: .systemYellow, alpha: 0.5,
                    label: self.watts(adapterToSystem)
                )
                inCursor += adapterT
            }
            // battery drains alongside the adapter when it cannot keep up
            if assistT > 0 {
                let bRect = NSRect(x: leftX, y: aRect.maxY + 10, width: leftNodeW, height: bH)
                self.node(
                    rect: bRect,
                    symbol: "battery.100", title: "\(Int((m.level * 100).rounded()))%",
                    color: .systemOrange
                )
                self.ribbon(
                    from: Endpoint(x: bRect.maxX, top: bRect.midY - assistT/2, height: assistT),
                    to: Endpoint(x: macRect.minX, top: inCursor, height: assistT),
                    color: .systemOrange, alpha: 0.5,
                    label: self.watts(discharge)
                )
                inCursor += assistT
            }
        } else {
            // battery is the only source
            let nodeH = max(56, batteryT + 24)
            let nodeRect = NSRect(x: leftX, y: (bounds.height - nodeH)/2, width: leftNodeW, height: nodeH)
            self.node(
                rect: nodeRect,
                symbol: "battery.100", title: "\(Int((m.level * 100).rounded()))%",
                color: m.level > 0.15 ? .systemGreen : .systemRed
            )
            self.ribbon(
                from: Endpoint(x: nodeRect.maxX, top: nodeRect.midY - batteryT/2, height: batteryT),
                to: Endpoint(x: macRect.minX, top: inCursor, height: batteryT),
                color: .systemGreen, alpha: 0.45,
                label: self.watts(discharge > 0.3 ? discharge : system)
            )
        }

        // mac node on top of ribbons
        self.node(rect: macRect, symbol: "laptopcomputer", title: nil, color: .secondaryLabelColor)

        // ---- right icons and labels ----
        for (i, c) in consumers.enumerated() {
            let end = rightEnds[i]
            let centerY = end.top + end.height/2
            let iconRect = NSRect(x: endX + 6, y: centerY - 10, width: 20, height: 20)
            let box = NSBezierPath(roundedRect: iconRect, xRadius: 6, yRadius: 6)
            NSColor.tertiaryLabelColor.withAlphaComponent(0.15).setFill()
            box.fill()
            self.drawSymbol(c.symbol, in: iconRect.insetBy(dx: 4, dy: 4), color: .secondaryLabelColor)

            let textX = iconRect.maxX + 5
            self.text(c.name, at: NSPoint(x: textX, y: centerY - 10), font: .systemFont(ofSize: 8), color: .secondaryLabelColor)
            self.text(self.watts(c.watts), at: NSPoint(x: textX, y: centerY - 1), font: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold), color: .labelColor)
        }
    }

    // MARK: drawing helpers

    private func watts(_ value: Double) -> String {
        value >= 10 ? String(format: "%.1f W", value) : String(format: "%.2f W", value)
    }

    private func ribbon(from: Endpoint, to: Endpoint, color: NSColor, alpha: CGFloat, label: String? = nil) {
        let path = NSBezierPath()
        let c = (from.x + to.x) / 2
        path.move(to: NSPoint(x: from.x, y: from.top))
        path.curve(to: NSPoint(x: to.x, y: to.top), controlPoint1: NSPoint(x: c, y: from.top), controlPoint2: NSPoint(x: c, y: to.top))
        path.line(to: NSPoint(x: to.x, y: to.top + to.height))
        path.curve(to: NSPoint(x: from.x, y: from.top + from.height), controlPoint1: NSPoint(x: c, y: to.top + to.height), controlPoint2: NSPoint(x: c, y: from.top + from.height))
        path.close()

        if let gradient = NSGradient(starting: color.withAlphaComponent(alpha * 0.75), ending: color.withAlphaComponent(alpha)) {
            gradient.draw(in: path, angle: 0)
        } else {
            color.withAlphaComponent(alpha).setFill()
            path.fill()
        }

        if let label {
            let midY = (from.top + from.height/2 + to.top + to.height/2) / 2
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
            let str = NSAttributedString(string: label, attributes: attrs)
            let size = str.size()
            str.draw(at: NSPoint(x: c - size.width/2, y: midY - size.height/2))
        }
    }

    private func node(rect: NSRect, symbol: String, title: String?, color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.tertiaryLabelColor.withAlphaComponent(0.2).setFill()
        path.fill()
        NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1
        path.stroke()

        let hasTitle = title != nil
        let iconSide: CGFloat = min(rect.width - 20, 22)
        let iconY = hasTitle ? rect.midY - iconSide + 2 : rect.midY - iconSide/2
        self.drawSymbol(symbol, in: NSRect(x: rect.midX - iconSide/2, y: iconY, width: iconSide, height: iconSide), color: color)

        if let title {
            self.textCentered(title, at: NSPoint(x: rect.midX, y: rect.midY + 4), font: .systemFont(ofSize: 10, weight: .semibold), color: .labelColor)
        }
    }

    private func pill(rect: NSRect, symbol: String, color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height/2, yRadius: rect.height/2)
        color.withAlphaComponent(0.22).setFill()
        path.fill()
        self.drawSymbol(symbol, in: rect.insetBy(dx: 12, dy: 4), color: color)
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        var config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .medium)
        config = config.applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        image.isTemplate = false
        let size = image.size
        let scale = min(rect.width / size.width, rect.height / size.height, 1)
        let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
        image.draw(
            in: NSRect(
                x: rect.midX - drawSize.width/2, y: rect.midY - drawSize.height/2,
                width: drawSize.width, height: drawSize.height
            ),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
    }

    private func text(_ string: String, at point: NSPoint, font: NSFont, color: NSColor) {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
    }

    private func textCentered(_ string: String, at point: NSPoint, font: NSFont, color: NSColor) {
        let str = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = str.size()
        str.draw(at: NSPoint(x: point.x - size.width/2, y: point.y))
    }
}

// MARK: - process row

private class PowerProcessRow: NSStackView {
    private let icon = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")

    init(height: CGFloat) {
        super.init(frame: .zero)

        self.orientation = .horizontal
        self.alignment = .centerY
        self.spacing = 5
        self.heightAnchor.constraint(equalToConstant: height).isActive = true

        self.icon.widthAnchor.constraint(equalToConstant: 13).isActive = true
        self.icon.heightAnchor.constraint(equalToConstant: 13).isActive = true

        self.nameField.font = NSFont.systemFont(ofSize: 10)
        self.nameField.lineBreakMode = .byTruncatingTail
        self.valueField.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        self.valueField.textColor = .secondaryLabelColor
        self.valueField.alignment = .right

        self.addArrangedSubview(self.icon)
        self.addArrangedSubview(self.nameField)
        self.addArrangedSubview(NSView())
        self.addArrangedSubview(self.valueField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(_ process: TopProcess) {
        self.icon.image = process.icon
        self.nameField.stringValue = process.name
        self.valueField.stringValue = String(format: "%.1f", process.usage)
    }

    func clear() {
        self.icon.image = nil
        self.nameField.stringValue = ""
        self.valueField.stringValue = ""
    }
}
