//
//  ProxyPortal.swift
//  Stats
//
//  Shows mihomo/clash proxy status (current node, per-node latency, mode and
//  real-time traffic) inside the combined overview panel. Reads the data from
//  the mihomo REST API (external-controller), defaults to 127.0.0.1:9090.
//

import Cocoa
import Kit

internal class ProxyPortal: NSStackView {
    private var controller: String {
        Store.shared.string(key: "CombinedProxy_controller", defaultValue: "127.0.0.1:9090")
    }
    private var base: String { "http://\(self.controller)" }

    private var heightConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    private var columnWidths: [NSLayoutConstraint] = []
    internal var onResize: (() -> Void)?

    // Zone A: current node
    private let titleField = NSTextField(labelWithString: localizedString("Proxy overview title"))
    private let modeField = NSTextField(labelWithString: "")
    private let currentField = NSTextField(labelWithString: "—")
    private let delayChip = DelayChip()
    private let switchHint = NSTextField(labelWithString: "")

    // Zone B: inline top-5 node list
    private let nodeList = NSStackView()
    private var nodeRows: [ProxyNodeRow] = []
    private let chevron = NSImageView()

    // Zone C: speed + traffic
    private let downSpeedField = NSTextField(labelWithString: "↓ —")
    private let upSpeedField = NSTextField(labelWithString: "↑ —")
    private let nodeTrafficField = NSTextField(labelWithString: "")
    private let trafficBar = TrafficBar()

    // Zone D: VPS + connections
    private let vpsMonthField = NSTextField(labelWithString: "")
    private let vpsDayField = NSTextField(labelWithString: "")
    private let connTotalField = NSTextField(labelWithString: "—")
    private let connDetailField = NSTextField(labelWithString: "")
    private let updatedField = NSTextField(labelWithString: "")

    private weak var openNodesMenu: NSMenu?

    private var nodeNames: [String] = []
    private var nodeDelays: [String: Int] = [:]
    private var currentNode: String = ""
    private var groupName: String = ""
    private var switchable: Bool = false

    private var speedTimer: Timer?
    private var testTimer: Timer?
    private var allDelaysTestedAt: Date = .distantPast
    private let allDelayCacheInterval: TimeInterval = 300

    private static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }
    private var session: URLSession = ProxyPortal.makeSession()
    private var active = false

    internal private(set) var reachable: Bool = true

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))

        self.wantsLayer = true
        self.applyCardStyle()

        self.orientation = .horizontal
        self.distribution = .fill
        self.alignment = .top
        self.spacing = 0
        self.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)

        self.buildZoneA()
        self.buildZoneB()
        self.buildZoneC()
        self.buildZoneD()

        self.heightConstraint = self.heightAnchor.constraint(equalToConstant: 144)
        self.heightConstraint?.isActive = true

        ProxyTrafficLedger.shared.start()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateLayer() {
        self.applyCardStyle()
    }

    // MARK: - Zone A: Current node

    private func buildZoneA() {
        let zone = NSStackView()
        zone.orientation = .vertical
        zone.alignment = .leading
        zone.spacing = 6
        zone.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 5
        let globe = NSImageView()
        globe.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        globe.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        globe.contentTintColor = .systemTeal
        globe.setContentHuggingPriority(.required, for: .horizontal)
        self.titleField.font = Design.labelMediumFont
        self.titleField.textColor = .labelColor
        self.modeField.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        self.modeField.textColor = Design.secondaryTextColor
        header.addArrangedSubview(globe)
        header.addArrangedSubview(self.titleField)
        header.addArrangedSubview(self.modeField)
        zone.addArrangedSubview(header)

        self.currentField.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        self.currentField.lineBreakMode = .byTruncatingTail
        self.currentField.maximumNumberOfLines = 1
        self.currentField.cell?.truncatesLastVisibleLine = true
        zone.addArrangedSubview(self.currentField)

        self.delayChip.setContentHuggingPriority(.required, for: .horizontal)
        zone.addArrangedSubview(self.delayChip)

        self.switchHint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        self.switchHint.textColor = Design.mutedTextColor
        self.switchHint.stringValue = localizedString("Proxy switch hint")
        zone.addArrangedSubview(self.switchHint)

        self.sizeColumn(zone, initial: 190)
        self.addArrangedSubview(zone)

        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        self.addArrangedSubview(divider)
    }

    // MARK: - Zone B: Top-5 node list

    private func buildZoneB() {
        let zone = NSStackView()
        zone.orientation = .vertical
        zone.alignment = .leading
        zone.spacing = 6
        zone.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 5
        let label = NSTextField(labelWithString: localizedString("Proxy nodes"))
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = Design.secondaryTextColor
        header.addArrangedSubview(label)
        header.addArrangedSubview(NSView())
        self.chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        self.chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        self.chevron.contentTintColor = Design.mutedTextColor
        self.chevron.setContentHuggingPriority(.required, for: .horizontal)
        let chevronClick = NSClickGestureRecognizer(target: self, action: #selector(self.showNodeMenu))
        header.addGestureRecognizer(chevronClick)
        header.addArrangedSubview(self.chevron)
        zone.addArrangedSubview(header)

        self.nodeList.orientation = .vertical
        self.nodeList.alignment = .width
        self.nodeList.spacing = 2
        zone.addArrangedSubview(self.nodeList)

        // This is the flexible column: distribute surplus width through the
        // node names instead of leaving a blank area after the list.
        self.sizeColumn(zone, initial: 320)
        header.widthAnchor.constraint(equalTo: zone.widthAnchor, constant: -32).isActive = true
        self.nodeList.widthAnchor.constraint(equalTo: zone.widthAnchor, constant: -32).isActive = true
        self.addArrangedSubview(zone)

        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        self.addArrangedSubview(divider)
    }

    // MARK: - Zone C: Speed + node traffic

    private func buildZoneC() {
        let zone = NSStackView()
        zone.orientation = .vertical
        zone.alignment = .leading
        zone.spacing = 6
        zone.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)

        let label = NSTextField(labelWithString: localizedString("Proxy speed"))
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = Design.secondaryTextColor
        zone.addArrangedSubview(label)

        self.downSpeedField.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        self.downSpeedField.textColor = .labelColor
        zone.addArrangedSubview(self.downSpeedField)

        self.upSpeedField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        self.upSpeedField.textColor = Design.secondaryTextColor
        zone.addArrangedSubview(self.upSpeedField)

        self.nodeTrafficField.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        self.nodeTrafficField.textColor = Design.secondaryTextColor
        self.nodeTrafficField.lineBreakMode = .byTruncatingTail
        zone.addArrangedSubview(self.nodeTrafficField)

        self.trafficBar.heightAnchor.constraint(equalToConstant: 3).isActive = true
        zone.addArrangedSubview(self.trafficBar)

        self.sizeColumn(zone, initial: 250)
        self.addArrangedSubview(zone)

        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        self.addArrangedSubview(divider)
    }

    // MARK: - Zone D: VPS + connections

    private func buildZoneD() {
        let zone = NSStackView()
        zone.orientation = .vertical
        zone.alignment = .leading
        zone.spacing = 6
        zone.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)

        let label = NSTextField(labelWithString: localizedString("Proxy server monthly"))
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = Design.secondaryTextColor
        zone.addArrangedSubview(label)

        self.vpsMonthField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        self.vpsMonthField.textColor = .labelColor
        self.vpsMonthField.lineBreakMode = .byTruncatingTail
        self.vpsMonthField.maximumNumberOfLines = 1
        zone.addArrangedSubview(self.vpsMonthField)

        self.vpsDayField.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        self.vpsDayField.textColor = Design.secondaryTextColor
        self.vpsDayField.lineBreakMode = .byTruncatingTail
        self.vpsDayField.maximumNumberOfLines = 1
        zone.addArrangedSubview(self.vpsDayField)

        let connLabel = NSTextField(labelWithString: localizedString("Proxy connections"))
        connLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        connLabel.textColor = Design.mutedTextColor

        self.connTotalField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        self.connTotalField.textColor = .labelColor
        let connections = NSStackView(views: [connLabel, self.connTotalField])
        connections.orientation = .horizontal
        connections.alignment = .firstBaseline
        connections.spacing = 8
        zone.addArrangedSubview(connections)

        self.connDetailField.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        self.connDetailField.textColor = Design.secondaryTextColor
        self.connDetailField.lineBreakMode = .byTruncatingTail
        self.connDetailField.maximumNumberOfLines = 1
        zone.addArrangedSubview(self.connDetailField)

        self.updatedField.font = NSFont.systemFont(ofSize: 8, weight: .regular)
        self.updatedField.textColor = Design.mutedTextColor
        zone.addArrangedSubview(self.updatedField)

        self.sizeColumn(zone, initial: 210)
        self.addArrangedSubview(zone)
    }

    // MARK: - layout

    internal func setWidth(_ width: CGFloat) {
        self.widthConstraint?.isActive = false
        self.widthConstraint = self.widthAnchor.constraint(equalToConstant: width)
        self.widthConstraint?.isActive = true
        let fractions: [CGFloat] = [0.20, 0.33, 0.26, 0.21]
        for (constraint, fraction) in zip(self.columnWidths, fractions) {
            constraint.constant = (width - 1.5) * fraction
        }
    }

    private func sizeColumn(_ column: NSStackView, initial: CGFloat) {
        let constraint = column.widthAnchor.constraint(equalToConstant: initial)
        constraint.isActive = true
        self.columnWidths.append(constraint)
        // Explicit content widths keep AppKit gravity stacks from drifting.
        for child in column.arrangedSubviews where !(child is NSBox) {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor, constant: -32).isActive = true
        }
    }

    // MARK: - lifecycle

    internal func start() {
        self.active = true
        ProxyTrafficLedger.shared.start()
        ProxyRemoteTraffic.shared.start()
        self.refreshState()
        self.refreshSpeed()
        self.speedTimer?.invalidate()
        self.speedTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshSpeed()
        }
        self.testTimer?.invalidate()
        self.testTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
    }

    internal func stop() {
        self.active = false
        self.speedTimer?.invalidate()
        self.speedTimer = nil
        self.testTimer?.invalidate()
        self.testTimer = nil
        self.session.invalidateAndCancel()
        self.session = Self.makeSession()
        ProxyRemoteTraffic.shared.stop()
    }

    // MARK: - networking

    private func get(_ path: String, _ completion: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: self.base + path) else { completion(nil); return }
        self.session.dataTask(with: url) { [weak self] data, _, err in
            let json: [String: Any]?
            if err == nil, let data,
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = parsed
            } else {
                json = nil
            }
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                completion(json)
            }
        }.resume()
    }

    private func refreshSpeed() {
        let speed = ProxyTrafficLedger.shared.currentSpeed()
        let usage = ProxyTrafficLedger.shared.usage(node: self.currentNode)
        let conns = ProxyTrafficLedger.shared.connectionCount()
        let vps = ProxyRemoteTraffic.shared.snapshot()

        let downText = "↓ \(Units(bytes: speed.down).getReadableSpeed())"
        let upText = "↑ \(Units(bytes: speed.up).getReadableSpeed())"
        let monthNode = Units(bytes: usage.0 + usage.1).getReadableMemory()
        let todayNode = Units(bytes: usage.2 + usage.3).getReadableMemory()
        let trafficText = localizedString("Proxy node traffic")
            .replacingOccurrences(of: "%0", with: monthNode)
            .replacingOccurrences(of: "%1", with: todayNode)

        let vpsMonthText: String
        let vpsDayText: String
        let vpsLive: Bool
        if vps.totalsState != .live {
            let key: String
            if vps.totalsState == .loading { key = "VPS traffic loading" }
            else if vps.totalsState == .stale { key = "VPS traffic stale" }
            else { key = "VPS traffic unavailable" }
            vpsMonthText = localizedString(key)
            vpsDayText = ""
            vpsLive = false
        } else {
            vpsMonthText = "\(Units(bytes: vps.monthRx + vps.monthTx).getReadableMemory())"
            vpsDayText = localizedString("Proxy VPS day", Units(bytes: vps.dayRx + vps.dayTx).getReadableMemory())
            vpsLive = true
        }

        let connTotal = "\(conns.total)"
        let connDetail = localizedString("Proxy conn detail")
            .replacingOccurrences(of: "%0", with: "\(conns.direct)")
            .replacingOccurrences(of: "%1", with: "\(conns.proxied)")

        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let updated = localizedString("Proxy updated", fmt.string(from: now))

        // traffic bar: today vs month ratio
        let monthBytes = usage.0 + usage.1
        let todayBytes = usage.2 + usage.3
        let ratio = monthBytes > 0 ? min(Double(todayBytes) / Double(monthBytes), 1.0) : 0

        DispatchQueue.main.async {
            self.downSpeedField.stringValue = downText
            self.upSpeedField.stringValue = upText
            self.nodeTrafficField.stringValue = trafficText
            self.trafficBar.set(fraction: ratio)
            self.vpsMonthField.stringValue = vpsMonthText
            self.vpsMonthField.font = NSFont.monospacedDigitSystemFont(ofSize: vpsLive ? 13 : 9, weight: vpsLive ? .semibold : .regular)
            self.vpsMonthField.textColor = vpsLive ? .labelColor : Design.mutedTextColor
            self.vpsDayField.stringValue = vpsDayText
            self.connTotalField.stringValue = connTotal
            self.connDetailField.stringValue = connDetail
            self.updatedField.stringValue = updated
        }
    }

    private func refreshState() {
        self.get("/configs") { [weak self] json in
            guard let self = self, let mode = json?["mode"] as? String else { return }
            DispatchQueue.main.async { self.modeField.stringValue = localizedString("Proxy mode " + mode.lowercased()) }
        }

        self.get("/proxies") { [weak self] json in
            guard let self = self else { return }
            guard let proxies = json?["proxies"] as? [String: Any] else {
                DispatchQueue.main.async { self.markReachable(false) }
                return
            }

            guard let g = self.detectGroup(proxies), let all = g["all"] as? [String] else { return }
            let now = g["now"] as? String ?? ""
            let name = g["name"] as? String ?? ""
            let switchable = (g["type"] as? String) == "Selector"

            DispatchQueue.main.async {
                self.markReachable(true)
                self.currentNode = now
                self.groupName = name
                self.switchable = switchable
                self.titleField.stringValue = localizedString("Proxy overview title")
                self.currentField.stringValue = now
                self.rebuildNodes(all)
                self.refreshInlineNodeRows()
            }

            if !now.isEmpty { self.testDelay(now) }
            if Date().timeIntervalSince(self.allDelaysTestedAt) > self.allDelayCacheInterval {
                self.testAllDelays()
            }
        }
    }

    // pick the switchable selector group to control: a manual (Selector) group with the
    // most members, excluding GLOBAL; overridable via Store. Falls back to a URLTest group.
    private func detectGroup(_ proxies: [String: Any]) -> [String: Any]? {
        let groups = proxies.values.compactMap { $0 as? [String: Any] }
        let selectors = groups.filter {
            ($0["type"] as? String) == "Selector" &&
            ($0["name"] as? String) != "GLOBAL" &&
            !(($0["all"] as? [String]) ?? []).isEmpty
        }

        let override = Store.shared.string(key: "CombinedProxy_group", defaultValue: "")
        if !override.isEmpty, let g = selectors.first(where: { ($0["name"] as? String) == override }) {
            return g
        }

        let sorted = selectors.sorted {
            let a = ($0["all"] as? [String])?.count ?? 0
            let b = ($1["all"] as? [String])?.count ?? 0
            if a != b { return a > b }
            return (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "")
        }
        if let best = sorted.first { return best }

        return groups.first(where: { ($0["type"] as? String) == "URLTest" && $0["all"] != nil })
    }

    private func switchNode(_ name: String) {
        guard self.switchable, !self.groupName.isEmpty,
              let g = self.groupName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: self.base + "/proxies/\(g)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])
        self.session.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                self.refreshState()
            }
        }.resume()
    }

    // MARK: - node list (inline + menu)

    private func rebuildNodes(_ names: [String]) {
        self.nodeNames = names
        let validNames = Set(names)
        self.nodeDelays = self.nodeDelays.filter { validNames.contains($0.key) }
    }

    private func refreshInlineNodeRows() {
        self.nodeList.subviews.forEach { $0.removeFromSuperview() }
        self.nodeRows = []

        // Top-5 by delay (known delays first, sorted ascending; unknowns after, in list order)
        let withDelays = self.nodeNames.compactMap { name -> (String, Int)? in
            guard let d = self.nodeDelays[name] else { return nil }
            return (name, d)
        }.sorted { $0.1 > 0 && $1.1 > 0 ? $0.1 < $1.1 : $0.1 > 0 }

        let withoutDelays = self.nodeNames.filter { self.nodeDelays[$0] == nil }
        let ordered = (withDelays.map { $0.0 } + withoutDelays)
        let top5 = Array(ordered.prefix(5))

        for name in top5 {
            let row = ProxyNodeRow(name: name, isCurrent: name == self.currentNode)
            let delay = self.nodeDelays[name]
            let usage = ProxyTrafficLedger.shared.usage(node: name)
            let monthDown = Units(bytes: usage.1).getReadableMemory()
            row.update(delay: delay, monthTraffic: monthDown)
            let click = NSClickGestureRecognizer(target: self, action: #selector(self.switchViaRow(_:)))
            row.addGestureRecognizer(click)
            self.nodeList.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: self.nodeList.widthAnchor).isActive = true
            self.nodeRows.append(row)
        }
        if top5.isEmpty {
            let empty = NSTextField(labelWithString: "—")
            empty.font = Design.subFont
            empty.textColor = Design.mutedTextColor
            self.nodeList.addArrangedSubview(empty)
        }
    }

    @objc private func switchViaRow(_ sender: NSClickGestureRecognizer) {
        guard let row = sender.view as? ProxyNodeRow else { return }
        self.switchNode(row.name)
    }

    @objc private func showNodeMenu() {
        guard !self.nodeNames.isEmpty else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false
        self.nodeNames.forEach { name in
            let item = NSMenuItem(
                title: self.menuTitle(name: name, delay: self.nodeDelays[name]),
                action: #selector(self.selectNode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = name
            item.state = name == self.currentNode ? .on : .off
            item.isEnabled = self.switchable
            menu.addItem(item)
        }

        self.openNodesMenu = menu
        self.chevron.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)
        if Date().timeIntervalSince(self.allDelaysTestedAt) > self.allDelayCacheInterval {
            self.testAllDelays()
        }

        let selected = menu.items.first(where: { $0.state == .on })
        let popupWindow = self.window as? PopupWindow
        popupWindow?.locked = true
        let didSelect = menu.popUp(
            positioning: selected,
            at: NSPoint(x: self.chevron.bounds.maxX, y: self.chevron.bounds.minY),
            in: self.chevron
        )
        popupWindow?.locked = false
        if didSelect {
            popupWindow?.makeKey()
        } else {
            popupWindow?.orderOut(nil)
        }
        self.openNodesMenu = nil
        self.chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
    }

    @objc private func selectNode(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        self.switchNode(name)
    }

    // MARK: - delay testing

    private func testAllDelays() {
        let names = self.nodeNames
        guard !names.isEmpty else { return }
        self.allDelaysTestedAt = Date()
        let batchSize = 5
        var index = 0
        func nextBatch() {
            let end = min(index + batchSize, names.count)
            guard index < end else { return }
            let group = DispatchGroup()
            for i in index..<end {
                group.enter()
                let name = names[i]
                self.testDelay(name) { group.leave() }
            }
            group.notify(queue: .global(qos: .utility)) {
                index = end
                if index < names.count { nextBatch() }
            }
        }
        nextBatch()
    }

    private func testDelay(_ name: String, _ completion: (() -> Void)? = nil) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: self.base + "/proxies/\(encoded)/delay?url=http://www.gstatic.com/generate_204&timeout=5000") else {
            completion?()
            return
        }
        self.session.dataTask(with: url) { [weak self] data, _, _ in
            defer { completion?() }
            guard let self = self else { return }
            var delay = 0
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                delay = (json["delay"] as? NSNumber)?.intValue ?? 0
            }
            DispatchQueue.main.async {
                guard self.active else { return }
                self.nodeDelays[name] = delay
                if let item = self.openNodesMenu?.items.first(where: { ($0.representedObject as? String) == name }) {
                    item.title = self.menuTitle(name: name, delay: delay)
                }
                if name == self.currentNode {
                    let style = self.delayStyle(delay)
                    self.delayChip.set(text: style.text, color: style.color)
                }
                self.refreshInlineNodeRows()
            }
        }.resume()
    }

    // MARK: - helpers

    private func menuTitle(name: String, delay: Int?) -> String {
        guard let delay = delay else { return name }
        return "\(name)    \(self.delayStyle(delay).text)"
    }

    private func delayStyle(_ delay: Int) -> (text: String, color: NSColor) {
        if delay <= 0 {
            return (localizedString("timeout"), .systemRed)
        }
        return ("\(delay) ms", delay < 100 ? .systemGreen : (delay < 400 ? Design.secondaryTextColor : .systemOrange))
    }

    private func markReachable(_ state: Bool) {
        if self.reachable != state {
            self.reachable = state
            self.onResize?()
        }
    }
}

// MARK: - Delay chip

private class DelayChip: NSView {
    private var text: String = "—"
    private var color: NSColor = Design.mutedTextColor

    func set(text: String, color: NSColor) {
        self.text = text
        self.color = color
        self.needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.widthAnchor.constraint(equalToConstant: 50).isActive = true
        self.heightAnchor.constraint(equalToConstant: 16).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        self.layer?.backgroundColor = self.color.withAlphaComponent(0.15).cgColor
        self.layer?.cornerRadius = 4
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        self.layer?.backgroundColor = self.color.withAlphaComponent(0.15).cgColor
        self.layer?.cornerRadius = 4
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: self.color,
            .paragraphStyle: style
        ]
        let str = NSAttributedString(string: self.text, attributes: attrs)
        let size = str.size()
        let origin = NSPoint(x: (self.bounds.width - size.width) / 2, y: (self.bounds.height - size.height) / 2)
        str.draw(at: origin)
    }
}

// MARK: - Inline node row

private class ProxyNodeRow: NSStackView {
    let name: String
    private let indicator = NSTextField(labelWithString: "○")
    private let nameField = NSTextField(labelWithString: "")
    private let delayBar = NSView()
    private let delayBarFill = NSView()
    private let delayField = NSTextField(labelWithString: "")
    private let trafficField = NSTextField(labelWithString: "")
    private var delayBarWidth: NSLayoutConstraint?

    init(name: String, isCurrent: Bool) {
        self.name = name
        super.init(frame: .zero)

        self.orientation = .horizontal
        self.alignment = .centerY
        self.spacing = 4
        self.distribution = .fill

        self.indicator.font = NSFont.systemFont(ofSize: 8, weight: .medium)
        self.indicator.textColor = isCurrent ? .systemTeal : Design.mutedTextColor
        self.indicator.stringValue = isCurrent ? "●" : "○"
        self.indicator.setContentHuggingPriority(.required, for: .horizontal)
        self.indicator.widthAnchor.constraint(equalToConstant: 8).isActive = true

        self.nameField.font = NSFont.systemFont(ofSize: 9, weight: isCurrent ? .semibold : .regular)
        self.nameField.textColor = isCurrent ? .labelColor : Design.secondaryTextColor
        self.nameField.lineBreakMode = .byTruncatingTail
        self.nameField.cell?.truncatesLastVisibleLine = true
        self.nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        self.delayBar.wantsLayer = true
        self.delayBar.layer?.backgroundColor = Design.track.cgColor
        self.delayBar.layer?.cornerRadius = 1.5
        self.delayBar.widthAnchor.constraint(equalToConstant: 50).isActive = true
        self.delayBar.heightAnchor.constraint(equalToConstant: 3).isActive = true
        self.delayBarFill.wantsLayer = true
        self.delayBarFill.layer?.cornerRadius = 1.5
        self.delayBar.addSubview(self.delayBarFill)
        self.delayBarFill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            self.delayBarFill.leadingAnchor.constraint(equalTo: self.delayBar.leadingAnchor),
            self.delayBarFill.centerYAnchor.constraint(equalTo: self.delayBar.centerYAnchor),
            self.delayBarFill.heightAnchor.constraint(equalTo: self.delayBar.heightAnchor),
        ])
        self.delayBarWidth = self.delayBarFill.widthAnchor.constraint(equalToConstant: 0)
        self.delayBarWidth?.isActive = true

        self.delayField.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        self.delayField.textColor = Design.mutedTextColor
        self.delayField.alignment = .right
        self.delayField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        self.delayField.setContentHuggingPriority(.required, for: .horizontal)

        self.trafficField.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        self.trafficField.textColor = Design.mutedTextColor
        self.trafficField.alignment = .right
        self.trafficField.widthAnchor.constraint(equalToConstant: 54).isActive = true
        self.trafficField.setContentHuggingPriority(.required, for: .horizontal)

        self.addArrangedSubview(self.indicator)
        self.addArrangedSubview(self.nameField)
        self.addArrangedSubview(self.delayBar)
        self.addArrangedSubview(self.delayField)
        self.addArrangedSubview(self.trafficField)

        self.nameField.stringValue = name
        self.heightAnchor.constraint(equalToConstant: 18).isActive = true

        if isCurrent {
            self.wantsLayer = true
            self.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.08).cgColor
            self.layer?.cornerRadius = 3
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(delay: Int?, monthTraffic: String) {
        if let delay = delay {
            if delay <= 0 {
                self.delayField.stringValue = "timeout"
                self.delayField.textColor = .systemRed
                self.delayBarFill.layer?.backgroundColor = NSColor.systemRed.cgColor
                self.delayBarWidth?.constant = 50
            } else {
                self.delayField.stringValue = "\(delay)ms"
                if delay < 100 {
                    self.delayField.textColor = .systemGreen
                    self.delayBarFill.layer?.backgroundColor = NSColor.systemGreen.cgColor
                } else if delay < 400 {
                    self.delayField.textColor = Design.secondaryTextColor
                    self.delayBarFill.layer?.backgroundColor = Design.secondaryTextColor.cgColor
                } else {
                    self.delayField.textColor = .systemOrange
                    self.delayBarFill.layer?.backgroundColor = NSColor.systemOrange.cgColor
                }
                self.delayBarWidth?.constant = max(3, min(50, CGFloat(delay) / 10))
            }
        } else {
            self.delayField.stringValue = "—"
            self.delayField.textColor = Design.mutedTextColor
            self.delayBarFill.layer?.backgroundColor = Design.track.cgColor
            self.delayBarWidth?.constant = 0
        }
        self.trafficField.stringValue = "↓\(monthTraffic)"
    }
}

// MARK: - Traffic bar

private class TrafficBar: NSView {
    private var fraction: CGFloat = 0

    func set(fraction: Double) {
        self.fraction = CGFloat(max(0, min(fraction, 1)))
        self.needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = self.bounds.height / 2
        let track = NSBezierPath(roundedRect: self.bounds, xRadius: radius, yRadius: radius)
        Design.track.setFill()
        track.fill()

        guard self.fraction > 0 else { return }
        let w = max(self.bounds.width * self.fraction, self.bounds.height)
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: self.bounds.height), xRadius: radius, yRadius: radius)
        NSColor.systemTeal.setFill()
        fill.fill()
    }
}
