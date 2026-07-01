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

    private let rowHeight: CGFloat = 18
    private let headerHeight: CGFloat = 22

    private var heightConstraint: NSLayoutConstraint?
    internal var onResize: (() -> Void)?

    private var titleField = NSTextField(labelWithString: localizedString("Proxy"))
    private var modeField = NSTextField(labelWithString: "")
    private var speedField = NSTextField(labelWithString: "")
    private let nodesStack = NSStackView()

    private var nodeRows: [String: ProxyNodeRow] = [:]
    private var currentNode: String = ""
    private var groupName: String = ""
    private var switchable: Bool = false

    private var speedTimer: Timer?
    private var testTimer: Timer?
    private var lastDownload: Int64?
    private var lastUpload: Int64?

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
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.layer?.cornerRadius = 3

        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = 2
        self.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        self.titleField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        self.modeField.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        self.modeField.textColor = .secondaryLabelColor
        self.speedField.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        self.speedField.textColor = .secondaryLabelColor
        self.speedField.alignment = .right

        let header = NSStackView()
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 6
        header.heightAnchor.constraint(equalToConstant: self.headerHeight).isActive = true
        header.addArrangedSubview(self.titleField)
        header.addArrangedSubview(self.modeField)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(self.speedField)
        self.addArrangedSubview(header)

        self.nodesStack.orientation = .vertical
        self.nodesStack.distribution = .fill
        self.nodesStack.alignment = .width
        self.nodesStack.spacing = 1
        self.addArrangedSubview(self.nodesStack)

        self.heightConstraint = self.heightAnchor.constraint(equalToConstant: self.headerHeight)
        self.heightConstraint?.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateLayer() {
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    internal func setWidth(_ width: CGFloat) {
        self.setFrameSize(NSSize(width: width, height: self.frame.height))
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
                self.rebuildNodes(all)
            }

            all.forEach { name in self.testDelay(name) }
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
            DispatchQueue.main.async { self?.refreshState() }
        }.resume()
    }

    private func testDelay(_ name: String) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: self.base + "/proxies/\(encoded)/delay?url=http://www.gstatic.com/generate_204&timeout=5000") else { return }
        self.session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            var delay = 0
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                delay = (json["delay"] as? NSNumber)?.intValue ?? 0
            }
            DispatchQueue.main.async { self.nodeRows[name]?.setDelay(delay) }
        }.resume()
    }

    // MARK: - layout

    private func rebuildNodes(_ names: [String]) {
        if Array(self.nodeRows.keys).sorted() != names.sorted() {
            self.nodesStack.subviews.forEach { $0.removeFromSuperview() }
            self.nodeRows = [:]
            names.forEach { name in
                let row = ProxyNodeRow(name: name, height: self.rowHeight)
                row.onClick = { [weak self] in self?.switchNode(name) }
                self.nodesStack.addArrangedSubview(row)
                self.nodeRows[name] = row
            }
        }
        self.nodeRows.forEach {
            $0.value.setClickable(self.switchable)
            $0.value.setCurrent($0.key == self.currentNode)
        }
        self.updateHeight(nodeCount: names.count)
    }

    private func updateHeight(nodeCount: Int) {
        let h = self.headerHeight + (nodeCount > 0 ? CGFloat(nodeCount) * (self.rowHeight + 1) + 4 : 0) + self.edgeInsets.top + self.edgeInsets.bottom
        self.heightConstraint?.constant = h
        self.setFrameSize(NSSize(width: self.frame.width, height: h))
        self.onResize?()
    }

    private func markReachable(_ state: Bool) {
        if self.reachable != state {
            self.reachable = state
            self.onResize?()
        }
    }
}

private class ProxyNodeRow: NSStackView {
    private let nameField: NSTextField
    private let delayField = NSTextField(labelWithString: "…")
    private let dot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))

    internal var onClick: (() -> Void)?
    private var clickable: Bool = false

    init(name: String, height: CGFloat) {
        self.nameField = NSTextField(labelWithString: name)

        super.init(frame: NSRect.zero)

        self.orientation = .horizontal
        self.distribution = .fill
        self.spacing = 6
        self.heightAnchor.constraint(equalToConstant: height).isActive = true

        let click = NSClickGestureRecognizer(target: self, action: #selector(self.handleClick))
        self.addGestureRecognizer(click)

        self.dot.wantsLayer = true
        self.dot.layer?.cornerRadius = 3
        self.dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        self.dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        self.dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        self.nameField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        self.nameField.lineBreakMode = .byTruncatingTail

        self.delayField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        self.delayField.alignment = .right
        self.delayField.textColor = .secondaryLabelColor

        self.addArrangedSubview(self.dot)
        self.addArrangedSubview(self.nameField)
        self.addArrangedSubview(NSView())
        self.addArrangedSubview(self.delayField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleClick() {
        guard self.clickable else { return }
        self.onClick?()
    }

    func setClickable(_ state: Bool) {
        self.clickable = state
        self.window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if self.clickable {
            self.addCursorRect(self.bounds, cursor: .pointingHand)
        }
    }

    func setCurrent(_ current: Bool) {
        self.dot.layer?.backgroundColor = (current ? NSColor.systemBlue : NSColor.tertiaryLabelColor).cgColor
        self.nameField.font = NSFont.systemFont(ofSize: 11, weight: current ? .semibold : .regular)
    }

    func setDelay(_ delay: Int) {
        if delay <= 0 {
            self.delayField.stringValue = localizedString("timeout")
            self.delayField.textColor = .systemRed
        } else {
            self.delayField.stringValue = "\(delay) ms"
            self.delayField.textColor = delay < 150 ? .systemGreen : (delay < 300 ? .systemOrange : .systemRed)
        }
    }
}
