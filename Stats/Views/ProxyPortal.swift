//
//  ProxyPortal.swift
//  Stats
//
//  Shows mihomo/clash proxy status (current node, per-node latency, mode and
//  real-time traffic) inside the combined overview panel. Reads the data from
//  the mihomo REST API (external-controller), defaults to 127.0.0.1:9090.
//
//  A connection header above three task-focused areas: nodes, live traffic,
//  and server usage. Network control and collectors remain independent of layout.
//

import Cocoa
import Kit

// MARK: - layout

private enum ProxyLayout {
    static let cardHeight: CGFloat = 200
    static let padV: CGFloat = 12
    static let padH: CGFloat = 16
    // columns are pinned to this height so their first rows share a baseline
    static let contentHeight: CGFloat = 132
    static let headerHeight: CGFloat = 16
    static let headerGap: CGFloat = 8
    static let heroGap: CGFloat = 10
    static let chipHeight: CGFloat = 18
    static let nodeRowHeight: CGFloat = 20
    static let nodeRowSpacing: CGFloat = 2
    static let dividerInset: CGFloat = 22
    // the available width (minus three 0.5pt hairlines) split per column
    static let fractions: [CGFloat] = [0.40, 0.30, 0.30]
}

private enum ProxyFont {
    static let hero = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
    static let heroUnit = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let rowName = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let rowNameCurrent = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let rowValue = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    static let caption = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    static let micro = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
}

internal class ProxyPortal: NSStackView {
    private var controller: String {
        Store.shared.string(key: "CombinedProxy_controller", defaultValue: "127.0.0.1:9090")
    }
    private var base: String { "http://\(self.controller)" }

    private var heightConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    private var columnWidths: [NSLayoutConstraint] = []
    internal var onResize: (() -> Void)?

    // Column 1: current node
    private let currentField = NSTextField(labelWithString: "—")
    private let delayChip = ProxyChip()
    private let modeChip = ProxyChip()
    private let switchChip = ProxyChip(symbol: "chevron.down")

    // Column 2: inline top-5 node list
    private let nodeList = NSStackView()
    private var nodeRows: [ProxyNodeRow] = []
    private let chevron = NSImageView()

    // Column 3: speed + traffic
    private let downSpeedField = NSTextField(labelWithString: "")
    private let upSpeedField = NSTextField(labelWithString: "")
    private let spark = TileSparklineView()
    private let nodeTrafficField = NSTextField(labelWithString: "")

    // Column 4: VPS + connections
    private let updatedField = NSTextField(labelWithString: "")
    private let vpsMonthField = NSTextField(labelWithString: "")
    private let vpsDayField = NSTextField(labelWithString: "")
    private let connTotalField = NSTextField(labelWithString: "—")
    private let connDetailField = NSTextField(labelWithString: "")

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

        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = 12
        self.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        self.addArrangedSubview(self.buildConnectionHeader())
        let body = NSStackView(views: [self.buildNodesColumn(), self.makeDivider(),
                                      self.buildSpeedColumn(), self.makeDivider(),
                                      self.buildServerColumn()])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 0
        body.heightAnchor.constraint(equalToConstant: ProxyLayout.contentHeight).isActive = true
        self.addArrangedSubview(body)

        self.heightConstraint = self.heightAnchor.constraint(equalToConstant: ProxyLayout.cardHeight)
        self.heightConstraint?.isActive = true

        ProxyTrafficLedger.shared.start()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateLayer() {
        self.applyCardStyle()
    }

    // MARK: - column scaffolding

    private func makeColumn() -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .width
        column.distribution = .fill
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 0, left: ProxyLayout.padH, bottom: 0, right: ProxyLayout.padH)
        column.heightAnchor.constraint(equalToConstant: ProxyLayout.contentHeight).isActive = true
        let width = column.widthAnchor.constraint(equalToConstant: 240)
        width.isActive = true
        self.columnWidths.append(width)
        return column
    }

    /// Adds a row and the gap that follows it. Content rows hug vertically, so
    /// any surplus height lands in the trailing spacer instead of stretching a
    /// label (which used to push the traffic bar to the card's bottom edge).
    private func add(_ view: NSView, to column: NSStackView, spacingAfter: CGFloat) {
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        column.addArrangedSubview(view)
        column.setCustomSpacing(spacingAfter, after: view)
    }

    private func addSpacer(to column: NSStackView) {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        column.addArrangedSubview(spacer)
    }

    /// `[◧ icon] Title ................ trailing` — the one header shape shared
    /// by all four columns.
    private func makeHeader(symbol: String, title: String, trailing: NSView? = nil) -> NSStackView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 5
        header.heightAnchor.constraint(equalToConstant: ProxyLayout.headerHeight).isActive = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = .systemTeal
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor
        label.setContentHuggingPriority(.required, for: .horizontal)

        header.addArrangedSubview(icon)
        header.addArrangedSubview(label)
        header.addArrangedSubview(NSView())
        if let trailing { header.addArrangedSubview(trailing) }
        return header
    }

    /// Wraps hugging content (chips) so the column's `.width` alignment cannot
    /// stretch it edge to edge.
    private func huggingRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.addArrangedSubview(NSView())
        return row
    }

    private func makeDivider() -> NSView {
        let wrap = NSView()
        wrap.widthAnchor.constraint(equalToConstant: 1).isActive = true
        wrap.heightAnchor.constraint(equalToConstant: ProxyLayout.contentHeight).isActive = true

        let line = Hairline()
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 0.5),
            line.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            line.topAnchor.constraint(equalTo: wrap.topAnchor, constant: ProxyLayout.dividerInset),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -ProxyLayout.dividerInset),
        ])
        return wrap
    }

    // MARK: - column 1: current node

    private func buildConnectionHeader() -> NSStackView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)
        header.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        icon.contentTintColor = .systemTeal
        let title = NSTextField(labelWithString: localizedString("Proxy current connection"))
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = Design.secondaryTextColor
        self.currentField.font = .systemFont(ofSize: 17, weight: .semibold)
        self.currentField.lineBreakMode = .byTruncatingTail
        self.currentField.maximumNumberOfLines = 1
        self.currentField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for chip in [self.delayChip, self.modeChip, self.switchChip] {
            chip.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        self.delayChip.set(text: "—", tint: Design.mutedTextColor)
        self.switchChip.set(text: localizedString("Proxy switch node"), tint: .systemTeal)
        self.switchChip.toolTip = localizedString("Proxy switch hint")
        self.switchChip.makeInteractive { [weak self] in self?.showNodeMenu(from: self?.switchChip) }
        for view in [icon, title, self.currentField, self.delayChip, self.modeChip, NSView(), self.switchChip] {
            header.addArrangedSubview(view)
        }
        return header
    }

    // MARK: - column 2: top-5 node list

    private func buildNodesColumn() -> NSStackView {
        let column = self.makeColumn()

        self.chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        self.chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        self.chevron.contentTintColor = Design.mutedTextColor
        self.chevron.setContentHuggingPriority(.required, for: .horizontal)
        let header = self.makeHeader(symbol: "antenna.radiowaves.left.and.right",
                                     title: localizedString("Proxy nodes"),
                                     trailing: self.chevron)
        header.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(self.showNodeMenuFromChevron)))
        header.toolTip = localizedString("Proxy switch hint")
        self.add(header, to: column, spacingAfter: ProxyLayout.headerGap)

        self.nodeList.orientation = .vertical
        self.nodeList.alignment = .width
        self.nodeList.spacing = ProxyLayout.nodeRowSpacing
        self.add(self.nodeList, to: column, spacingAfter: 0)
        self.nodeList.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * ProxyLayout.padH).isActive = true

        self.addSpacer(to: column)
        return column
    }

    // MARK: - column 3: speed + node traffic

    private func buildSpeedColumn() -> NSStackView {
        let column = self.makeColumn()

        self.add(self.makeHeader(symbol: "arrow.up.arrow.down", title: localizedString("Proxy speed")),
                 to: column, spacingAfter: ProxyLayout.headerGap)

        self.downSpeedField.lineBreakMode = .byTruncatingTail
        self.add(self.downSpeedField, to: column, spacingAfter: ProxyLayout.heroGap)

        self.upSpeedField.lineBreakMode = .byTruncatingTail
        self.add(self.upSpeedField, to: column, spacingAfter: 8)

        self.spark.downColor = .systemTeal
        self.spark.heightAnchor.constraint(equalToConstant: 20).isActive = true
        self.add(self.spark, to: column, spacingAfter: 6)

        self.nodeTrafficField.lineBreakMode = .byTruncatingTail
        self.nodeTrafficField.maximumNumberOfLines = 1
        self.add(self.nodeTrafficField, to: column, spacingAfter: 0)

        self.addSpacer(to: column)
        return column
    }

    // MARK: - column 4: VPS + connections

    private func buildServerColumn() -> NSStackView {
        let column = self.makeColumn()

        self.updatedField.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        self.updatedField.textColor = Design.mutedTextColor
        self.updatedField.alignment = .right
        self.updatedField.setContentHuggingPriority(.required, for: .horizontal)
        self.add(self.makeHeader(symbol: "server.rack",
                                 title: localizedString("Proxy server monthly"),
                                 trailing: self.updatedField),
                 to: column, spacingAfter: ProxyLayout.headerGap)

        self.vpsMonthField.lineBreakMode = .byTruncatingTail
        self.vpsMonthField.maximumNumberOfLines = 1
        self.add(self.vpsMonthField, to: column, spacingAfter: ProxyLayout.heroGap)

        self.add(self.vpsDayField, to: column, spacingAfter: 10)

        let rule = Hairline()
        rule.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        self.add(rule, to: column, spacingAfter: 10)

        let connLabel = NSTextField(labelWithString: localizedString("Proxy connections"))
        connLabel.font = .systemFont(ofSize: 10, weight: .regular)
        connLabel.textColor = Design.mutedTextColor
        connLabel.setContentHuggingPriority(.required, for: .horizontal)
        self.connTotalField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        self.connTotalField.textColor = .labelColor
        let connections = NSStackView(views: [connLabel, self.connTotalField])
        connections.orientation = .horizontal
        connections.alignment = .firstBaseline
        connections.spacing = 6
        self.add(connections, to: column, spacingAfter: 3)

        self.connDetailField.font = ProxyFont.micro
        self.connDetailField.textColor = Design.secondaryTextColor
        self.connDetailField.lineBreakMode = .byTruncatingTail
        self.add(self.connDetailField, to: column, spacingAfter: 0)

        self.addSpacer(to: column)
        return column
    }

    // MARK: - layout

    internal func setWidth(_ width: CGFloat) {
        self.widthConstraint?.isActive = false
        self.widthConstraint = self.widthAnchor.constraint(equalToConstant: width)
        self.widthConstraint?.isActive = true
        let available = width - CGFloat(ProxyLayout.fractions.count - 1)
        for (constraint, fraction) in zip(self.columnWidths, ProxyLayout.fractions) {
            constraint.constant = available * fraction
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

        let downText = Units(bytes: speed.down).getReadableSpeed()
        let upText = Units(bytes: speed.up).getReadableSpeed()

        let monthNode = Units(bytes: usage.0 + usage.1).getReadableMemory()
        let todayNode = Units(bytes: usage.2 + usage.3).getReadableMemory()
        let trafficText = localizedString("Proxy traffic month").replacingOccurrences(of: "%0", with: monthNode)
            + " · "
            + localizedString("Proxy traffic today").replacingOccurrences(of: "%0", with: todayNode)

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
            vpsMonthText = Units(bytes: vps.monthRx + vps.monthTx).getReadableMemory()
            vpsDayText = localizedString("Proxy traffic today")
                .replacingOccurrences(of: "%0", with: Units(bytes: vps.dayRx + vps.dayTx).getReadableMemory())
            vpsLive = true
        }

        let connTotal = "\(conns.total)"
        let connDetail = localizedString("Proxy conn detail")
            .replacingOccurrences(of: "%0", with: "\(conns.direct)")
            .replacingOccurrences(of: "%1", with: "\(conns.proxied)")

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let updated = localizedString("Proxy updated", fmt.string(from: Date()))

        DispatchQueue.main.async {
            self.spark.push(down: Double(speed.down), up: Double(speed.up))

            self.downSpeedField.attributedStringValue = self.hero(downText, lead: "↓")
            self.upSpeedField.attributedStringValue = self.caption(upText, lead: "↑")
            self.nodeTrafficField.attributedStringValue = self.caption(trafficText)

            if vpsLive {
                self.vpsMonthField.attributedStringValue = self.hero(vpsMonthText)
                self.vpsDayField.attributedStringValue = self.caption(vpsDayText)
            } else {
                self.vpsMonthField.attributedStringValue = NSAttributedString(string: vpsMonthText, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: Design.mutedTextColor,
                ])
                self.vpsDayField.stringValue = ""
            }
            self.connTotalField.stringValue = connTotal
            self.connDetailField.stringValue = connDetail
            self.updatedField.stringValue = ""
            self.vpsMonthField.toolTip = updated
        }
    }

    private func refreshState() {
        self.get("/configs") { [weak self] json in
            guard let self = self, let mode = json?["mode"] as? String else { return }
            let text = localizedString("Proxy mode " + mode.lowercased())
            DispatchQueue.main.async { self.modeChip.set(text: text, tint: Design.secondaryTextColor) }
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

        // Keep the current connection visible and the remaining choices stable.
        let stable = self.nodeNames.filter { $0 != self.currentNode }
        let top5 = Array(([self.currentNode].filter { !$0.isEmpty } + stable).prefix(5))

        for name in top5 {
            let row = ProxyNodeRow(name: name, isCurrent: name == self.currentNode)
            let usage = ProxyTrafficLedger.shared.usage(node: name)
            let monthDown = MetricTilesGrid.compactBytes(Units(bytes: usage.1).getReadableMemory())
            let monthTotal = Units(bytes: usage.0 + usage.1).getReadableMemory()
            let todayTotal = Units(bytes: usage.2 + usage.3).getReadableMemory()
            let tooltip = localizedString("Proxy node traffic")
                .replacingOccurrences(of: "%0", with: monthTotal)
                .replacingOccurrences(of: "%1", with: todayTotal)
            row.update(delay: self.nodeDelays[name], monthTraffic: "↓\(monthDown)", tooltip: tooltip)
            row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(self.switchViaRow(_:))))
            self.nodeList.addArrangedSubview(row)
            // the stack's .width alignment does not stretch a nested stack, and
            // a shorter node name would otherwise center its own row
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

    @objc private func showNodeMenuFromChevron(_ sender: NSClickGestureRecognizer) {
        self.showNodeMenu(from: self.chevron, alignTrailing: true)
    }

    private func showNodeMenu(from anchor: NSView?, alignTrailing: Bool = false) {
        guard !self.nodeNames.isEmpty, let anchor else { return }

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
        let x = alignTrailing ? anchor.bounds.maxX : anchor.bounds.minX
        let didSelect = menu.popUp(
            positioning: selected,
            at: NSPoint(x: x, y: anchor.bounds.minY),
            in: anchor
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
                    self.delayChip.set(text: style.text, tint: style.color)
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

    /// 20pt hero value; a trailing unit ("GB", "KB/s") stays on the baseline at
    /// 13pt so the measurement, not the unit, carries the weight.
    private func hero(_ value: String, lead: String? = nil) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let lead {
            text.append(NSAttributedString(string: lead + " ", attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: NSColor.systemTeal,
            ]))
        }
        let body = NSMutableAttributedString(string: value, attributes: [
            .font: ProxyFont.hero,
            .foregroundColor: NSColor.labelColor,
        ])
        if let suffix = value.range(of: "[A-Za-z%/]+$", options: .regularExpression) {
            body.addAttribute(.font, value: ProxyFont.heroUnit, range: NSRange(suffix, in: value))
        }
        text.append(body)
        return text
    }

    private func caption(_ value: String, lead: String? = nil) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let lead {
            text.append(NSAttributedString(string: lead + " ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.systemTeal,
            ]))
        }
        text.append(NSAttributedString(string: value, attributes: [
            .font: ProxyFont.caption,
            .foregroundColor: Design.secondaryTextColor,
        ]))
        return text
    }

    private func markReachable(_ state: Bool) {
        if self.reachable != state {
            self.reachable = state
            self.onResize?()
        }
    }
}

// MARK: - pill chip

/// Small rounded pill used for the node's latency (semantic tint), the mihomo
/// mode (neutral) and the switch action (accent, clickable).
private class ProxyChip: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var tint: NSColor = Design.secondaryTextColor
    private var hovered = false
    private var onClick: (() -> Void)?

    func makeInteractive(_ action: @escaping () -> Void) {
        self.onClick = action
        self.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    init(symbol: String? = nil) {
        super.init(frame: .zero)
        self.wantsLayer = true

        self.label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        self.label.setContentHuggingPriority(.required, for: .horizontal)

        let content = NSStackView()
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        if let symbol {
            self.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            self.icon.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
            content.addArrangedSubview(self.label)
            content.addArrangedSubview(self.icon)
        } else {
            content.addArrangedSubview(self.label)
        }
        self.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            content.topAnchor.constraint(equalTo: self.topAnchor),
            content.bottomAnchor.constraint(equalTo: self.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(text: String, tint: NSColor) {
        self.tint = tint
        self.label.stringValue = text
        self.label.textColor = tint
        self.icon.contentTintColor = tint
        self.needsDisplay = true
    }

    override func updateLayer() {
        self.layer?.cornerRadius = 6
        let alpha: CGFloat = self.onClick == nil ? 0.13 : (self.hovered ? 0.26 : 0.15)
        self.layer?.backgroundColor = self.tint.withAlphaComponent(alpha).cgColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.needsDisplay = true
    }

    public override func mouseEntered(with event: NSEvent) {
        guard self.onClick != nil else { return }
        self.hovered = true
        self.needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        self.hovered = false
        self.needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        guard self.onClick != nil, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return }
        self.onClick?()
    }

    public override func resetCursorRects() {
        guard self.onClick != nil else { return }
        self.addCursorRect(self.bounds, cursor: .pointingHand)
    }
}

// MARK: - hairline

/// 0.5pt rule that re-resolves its dynamic color on appearance changes.
private class Hairline: NSView {
    var color: NSColor = .separatorColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        self.layer?.backgroundColor = self.color.cgColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.needsDisplay = true
    }
}

// MARK: - inline node row

private class ProxyNodeRow: NSStackView {
    let name: String
    private let isCurrent: Bool
    private let indicator = NSTextField(labelWithString: "○")
    private let nameField = NSTextField(labelWithString: "")
    private let delayBar = TileBarView()
    private let delayField = NSTextField(labelWithString: "")
    private let trafficField = NSTextField(labelWithString: "")
    private var hovered = false

    private static let hoverFill = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(calibratedWhite: dark ? 1.0 : 0.0, alpha: 0.06)
    }

    init(name: String, isCurrent: Bool) {
        self.name = name
        self.isCurrent = isCurrent
        super.init(frame: .zero)

        self.orientation = .horizontal
        self.alignment = .centerY
        self.spacing = 8
        self.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 7)
        self.distribution = .fill
        self.wantsLayer = true

        self.indicator.font = NSFont.systemFont(ofSize: 8, weight: .medium)
        self.indicator.textColor = isCurrent ? .systemTeal : Design.mutedTextColor
        self.indicator.stringValue = isCurrent ? "●" : "○"
        self.indicator.setContentHuggingPriority(.required, for: .horizontal)
        self.indicator.widthAnchor.constraint(equalToConstant: 8).isActive = true

        self.nameField.font = isCurrent ? ProxyFont.rowNameCurrent : ProxyFont.rowName
        self.nameField.textColor = isCurrent ? .labelColor : Design.secondaryTextColor
        self.nameField.lineBreakMode = .byTruncatingTail
        self.nameField.cell?.truncatesLastVisibleLine = true
        self.nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        self.delayBar.set(fraction: 0, color: Design.track)
        self.delayBar.widthAnchor.constraint(equalToConstant: 44).isActive = true
        self.delayBar.heightAnchor.constraint(equalToConstant: 4).isActive = true
        self.delayBar.setContentHuggingPriority(.required, for: .horizontal)

        self.delayField.font = ProxyFont.rowValue
        self.delayField.textColor = Design.mutedTextColor
        self.delayField.alignment = .right
        self.delayField.widthAnchor.constraint(equalToConstant: 38).isActive = true
        self.delayField.setContentHuggingPriority(.required, for: .horizontal)

        self.trafficField.font = ProxyFont.rowValue
        self.trafficField.textColor = Design.mutedTextColor
        self.trafficField.alignment = .right
        self.trafficField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        self.trafficField.setContentHuggingPriority(.required, for: .horizontal)

        self.addArrangedSubview(self.indicator)
        self.addArrangedSubview(self.nameField)
        self.addArrangedSubview(self.delayField)

        self.nameField.stringValue = name
        self.heightAnchor.constraint(equalToConstant: ProxyLayout.nodeRowHeight).isActive = true
        self.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        self.layer?.cornerRadius = 5
        if self.isCurrent {
            self.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.12).cgColor
        } else if self.hovered {
            self.layer?.backgroundColor = Self.hoverFill.cgColor
        } else {
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        self.hovered = true
        self.needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        self.hovered = false
        self.needsDisplay = true
    }

    public override func resetCursorRects() {
        self.addCursorRect(self.bounds, cursor: .pointingHand)
    }

    func update(delay: Int?, monthTraffic: String, tooltip: String) {
        self.toolTip = self.name + "\n" + tooltip
        if let delay = delay {
            if delay <= 0 {
                self.delayField.stringValue = localizedString("timeout")
                self.delayField.textColor = .systemRed
                self.delayBar.set(fraction: 1, color: .systemRed)
            } else {
                let color = delay < 100
                    ? NSColor.systemGreen
                    : (delay < 400 ? Design.secondaryTextColor : NSColor.systemOrange)
                self.delayField.stringValue = "\(delay)ms"
                self.delayField.textColor = color
                // 0–440 ms maps to the full bar; slower nodes cap out red/orange
                self.delayBar.set(fraction: min(CGFloat(delay) / 440, 1), color: color)
            }
        } else {
            self.delayField.stringValue = "—"
            self.delayField.textColor = Design.mutedTextColor
            self.delayBar.set(fraction: 0, color: Design.track)
        }
        self.trafficField.stringValue = monthTraffic
    }
}
