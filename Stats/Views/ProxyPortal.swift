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
    // mihomo external-controller, overridable via Store
    private var controller: String {
        Store.shared.string(key: "CombinedProxy_controller", defaultValue: "127.0.0.1:9090")
    }
    private var base: String { "http://\(self.controller)" }

    private let headerHeight: CGFloat = 22

    private var heightConstraint: NSLayoutConstraint?
    internal var onResize: (() -> Void)?

    private var titleField = NSTextField(labelWithString: localizedString("Proxy"))
    private var modeField = NSTextField(labelWithString: "")
    private var speedField = NSTextField(labelWithString: "")
    private var currentField = NSTextField(labelWithString: "")
    private var currentDelayField = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let header = NSStackView()
    private weak var openNodesMenu: NSMenu?

    private var nodeNames: [String] = []
    private var nodeDelays: [String: Int] = [:]
    private var currentNode: String = ""
    private var groupName: String = ""
    private var switchable: Bool = false

    private var speedTimer: Timer?
    private var testTimer: Timer?
    private var lastDownload: Int64?
    private var lastUpload: Int64?
    // throttles full-list delay tests so we don't fire N concurrent HTTP
    // requests every 30 s — only the current node is tested on each refresh;
    // all nodes are tested lazily when the list is first expanded.
    private var allDelaysTestedAt: Date = .distantPast
    private let allDelayCacheInterval: TimeInterval = 300 // 5 min

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // becomes false when the controller cannot be reached
    internal private(set) var reachable: Bool = true

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: self.headerHeight))

        self.wantsLayer = true
        self.applyCardStyle()

        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = 4
        self.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        self.titleField.font = Design.labelMediumFont
        self.titleField.textColor = .labelColor
        self.modeField.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        self.modeField.textColor = .secondaryLabelColor
        self.speedField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        self.speedField.textColor = .secondaryLabelColor
        self.speedField.alignment = .right

        self.currentField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        self.currentField.lineBreakMode = .byTruncatingTail
        self.currentDelayField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        self.currentDelayField.textColor = .secondaryLabelColor

        self.chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        self.chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        self.chevron.contentTintColor = .tertiaryLabelColor

        self.header.orientation = .horizontal
        self.header.distribution = .fill
        self.header.alignment = .centerY
        self.header.spacing = 6
        self.header.heightAnchor.constraint(equalToConstant: self.headerHeight).isActive = true

        // native section icon: globe, macOS network-accent teal
        let globe = NSImageView()
        globe.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        globe.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        globe.contentTintColor = .systemTeal
        globe.setContentHuggingPriority(.required, for: .horizontal)
        self.header.addArrangedSubview(globe)
        self.header.addArrangedSubview(self.titleField)
        self.header.addArrangedSubview(self.modeField)
        self.header.addArrangedSubview(NSView())
        self.header.addArrangedSubview(self.currentField)
        self.header.addArrangedSubview(self.currentDelayField)
        self.header.addArrangedSubview(self.speedField)
        self.header.addArrangedSubview(self.chevron)
        let click = NSClickGestureRecognizer(target: self, action: #selector(self.showNodeMenu))
        self.header.addGestureRecognizer(click)
        self.addArrangedSubview(self.header)

        let compactHeight = self.headerHeight + self.edgeInsets.top + self.edgeInsets.bottom
        self.heightConstraint = self.heightAnchor.constraint(equalToConstant: compactHeight)
        self.heightConstraint?.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateLayer() {
        self.applyCardStyle()
    }

    private var widthConstraint: NSLayoutConstraint?

    internal func setWidth(_ width: CGFloat) {
        self.widthConstraint?.isActive = false
        self.widthConstraint = self.widthAnchor.constraint(equalToConstant: width)
        self.widthConstraint?.isActive = true
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

        // A real NSMenu tracks in its own surface. Unlike the old inline stack,
        // it never changes the dashboard's intrinsic height and AppKit flips or
        // scrolls it automatically when the proxy card is near the screen edge.
        let selected = menu.items.first(where: { $0.state == .on })
        let popupWindow = self.window as? PopupWindow
        popupWindow?.locked = true
        let didSelect = menu.popUp(
            positioning: selected,
            at: NSPoint(x: self.header.bounds.maxX - 18, y: self.header.bounds.minY),
            in: self.header
        )
        popupWindow?.locked = false
        if didSelect {
            // Re-arm the parent's resign-key auto-dismiss after menu tracking.
            popupWindow?.makeKey()
        } else {
            // Clicking outside the menu is also an outside click for the panel.
            popupWindow?.orderOut(nil)
        }
        self.openNodesMenu = nil
        self.chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
    }

    @objc private func selectNode(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        self.switchNode(name)
    }

    internal func start() {
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
        self.speedTimer?.invalidate()
        self.speedTimer = nil
        self.testTimer?.invalidate()
        self.testTimer = nil
        self.lastDownload = nil
        self.lastUpload = nil
    }

    // MARK: - networking

    private func get(_ path: String, _ completion: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: self.base + path) else { completion(nil); return }
        self.session.dataTask(with: url) { data, _, err in
            guard err == nil, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(json)
        }.resume()
    }

    private func refreshSpeed() {
        self.get("/connections") { [weak self] json in
            guard let self = self else { return }
            guard let json = json,
                  let down = (json["downloadTotal"] as? NSNumber)?.int64Value,
                  let up = (json["uploadTotal"] as? NSNumber)?.int64Value else { return }

            var text = ""
            if let ld = self.lastDownload, let lu = self.lastUpload {
                let d = max(down - ld, 0)
                let u = max(up - lu, 0)
                text = "↓ \(Units(bytes: d).getReadableSpeed())  ↑ \(Units(bytes: u).getReadableSpeed())"
            }
            self.lastDownload = down
            self.lastUpload = up

            DispatchQueue.main.async {
                self.markReachable(true)
                if !text.isEmpty { self.speedField.stringValue = text }
            }
        }
    }

    private func refreshState() {
        self.get("/configs") { [weak self] json in
            guard let self = self, let mode = json?["mode"] as? String else { return }
            DispatchQueue.main.async { self.modeField.stringValue = mode }
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
                self.titleField.stringValue = localizedString("Proxy") + (name.isEmpty ? "" : " · \(name)")
                self.currentField.stringValue = now
                self.rebuildNodes(all)
            }

            // only test the current node on each 30 s refresh; the full list
            // is tested lazily when the user expands the node list.
            if !now.isEmpty { self.testDelay(now) }
        }
    }

    /// Test all node delays in bounded batches (max 5 concurrent) to avoid
    /// hammering the proxy controller and the network when there are many nodes.
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
            DispatchQueue.main.async { self?.refreshState() }
        }.resume()
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
                self.nodeDelays[name] = delay
                if let item = self.openNodesMenu?.items.first(where: { ($0.representedObject as? String) == name }) {
                    item.title = self.menuTitle(name: name, delay: delay)
                }
                if name == self.currentNode {
                    let style = self.delayStyle(delay)
                    self.currentDelayField.stringValue = style.text
                    self.currentDelayField.textColor = style.color
                }
            }
        }.resume()
    }

    // MARK: - layout

    private func rebuildNodes(_ names: [String]) {
        self.nodeNames = names
        let validNames = Set(names)
        self.nodeDelays = self.nodeDelays.filter { validNames.contains($0.key) }
    }

    private func menuTitle(name: String, delay: Int?) -> String {
        guard let delay = delay else { return name }
        return "\(name)    \(self.delayStyle(delay).text)"
    }

    private func delayStyle(_ delay: Int) -> (text: String, color: NSColor) {
        if delay <= 0 {
            return (localizedString("timeout"), .systemRed)
        }
        return ("\(delay) ms", delay < 100 ? .systemGreen : (delay < 400 ? .secondaryLabelColor : .systemOrange))
    }

    private func markReachable(_ state: Bool) {
        if self.reachable != state {
            self.reachable = state
            self.onResize?()
        }
    }
}
