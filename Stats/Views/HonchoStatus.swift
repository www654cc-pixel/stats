//
//  HonchoStatus.swift
//  Stats
//
//  Honcho (self-hosted memory system) status pill for the System Overview
//  hero card. Polls the local Honcho API on 127.0.0.1:8000 and surfaces
//  reachability, deriver queue backlog, and Hermes-side dialectic timeouts
//  (scanned from ~/.hermes/logs/errors.log) so a memory-system outage is
//  visible at a glance instead of hiding in logs.
//

import Cocoa
import Kit

// Honcho deployment constants — self-hosted instance on this machine.
//   API server : launchd `ai.honcho.api`, FastAPI on 127.0.0.1:8000
//                (AUTH_USE_AUTH=false, loopback only — no credentials needed)
//   Deriver    : launchd `ai.honcho.deriver`, cmdline contains "src.deriver"
//   Checkout   : ~/projects/honcho (version pill reads .git/HEAD directly)
//   Hermes log : ~/.hermes/logs/errors.log ("Honcho dialectic query failed"
//                lines mark a memory-context injection that timed out)
private enum HonchoEnv {
    static let baseURL = "http://127.0.0.1:8000"
    static let workspace = "personal"
    static let peer = "wangchangyu"
    static let repoPath = NSHomeDirectory() + "/projects/honcho"
    static let hermesErrorLog = NSHomeDirectory() + "/.hermes/logs/errors.log"
}

// MARK: - model

internal struct HonchoStatusModel {
    var reachable: Bool? = nil        // nil = not polled yet
    var queuePending: Int? = nil
    var sessions: Int? = nil
    var conclusions: Int? = nil
    var timeouts24h: Int? = nil
    var deriverRunning: Bool? = nil
    var version: String? = nil
}

// MARK: - monitor

internal final class HonchoStatusMonitor {
    internal var onUpdate: ((HonchoStatusModel) -> Void)?

    private(set) var model = HonchoStatusModel()
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        return URLSession(configuration: config)
    }()

    internal func start() {
        self.pollFast()
        self.pollSlow()
        self.fastTimer?.invalidate()
        self.slowTimer?.invalidate()
        self.fastTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.pollFast()
        }
        self.slowTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.pollSlow()
        }
    }

    internal func stop() {
        self.fastTimer?.invalidate()
        self.fastTimer = nil
        self.slowTimer?.invalidate()
        self.slowTimer = nil
    }

    private func emit() {
        let snapshot = self.model
        DispatchQueue.main.async { self.onUpdate?(snapshot) }
    }

    // MARK: fast poll — API reachability + deriver queue backlog

    private func pollFast() {
        self.getJSON("\(HonchoEnv.baseURL)/health") { [weak self] dict in
            guard let self = self else { return }
            let ok = (dict?["status"] as? String) == "ok"
            self.model.reachable = ok
            guard ok else {
                self.model.queuePending = nil
                self.emit()
                return
            }
            self.getJSON("\(HonchoEnv.baseURL)/v3/workspaces/\(HonchoEnv.workspace)/queue/status") { [weak self] queue in
                guard let self = self else { return }
                self.model.queuePending = queue?["pending_work_units"] as? Int
                self.emit()
            }
        }
    }

    // MARK: slow poll — counts, deriver liveness, repo version, log scan

    private func pollSlow() {
        let group = DispatchGroup()

        group.enter()
        self.postJSON("\(HonchoEnv.baseURL)/v3/workspaces/\(HonchoEnv.workspace)/sessions/list", body: ["size": 1]) { [weak self] dict in
            self?.model.sessions = dict?["total"] as? Int
            group.leave()
        }

        group.enter()
        self.postJSON("\(HonchoEnv.baseURL)/v3/workspaces/\(HonchoEnv.workspace)/conclusions/list", body: [
            "observer": HonchoEnv.peer, "observed": HonchoEnv.peer, "size": 1
        ]) { [weak self] dict in
            self?.model.conclusions = dict?["total"] as? Int
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { group.leave(); return }
            let timeouts = Self.scanTimeouts24h(path: HonchoEnv.hermesErrorLog)
            let deriver = Self.deriverAlive()
            let version = Self.repoVersion(at: HonchoEnv.repoPath)
            DispatchQueue.main.async {
                self.model.timeouts24h = timeouts
                self.model.deriverRunning = deriver
                self.model.version = version
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.emit()
        }
    }

    // MARK: probes

    /// Count "Honcho dialectic query failed" lines from the last 24h.
    /// Only the tail of the log is read; Hermes rotates this file and the
    /// failure burst we care about is always recent.
    static private func scanTimeouts24h(path: String) -> Int {
        guard let handle = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? handle.close() }
        let window: UInt64 = 512 * 1024
        let size = handle.seekToEndOfFile()
        if size > window { handle.seek(toFileOffset: size - window) }
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else { return 0 }

        let now = Date()
        let calendar = Calendar.current
        var count = 0
        for line in text.split(separator: "\n") where line.contains("Honcho dialectic query failed") {
            // line prefix: "07-28 10:13:06,783 ERROR ..."
            guard line.count > 17,
                  let month = Int(line.prefix(2)),
                  let day = Int(line.dropFirst(3).prefix(2)),
                  let hour = Int(line.dropFirst(6).prefix(2)),
                  let minute = Int(line.dropFirst(9).prefix(2)),
                  let second = Int(line.dropFirst(12).prefix(2)) else { continue }
            var components = DateComponents()
            components.year = calendar.component(.year, from: now)
            components.month = month; components.day = day
            components.hour = hour; components.minute = minute; components.second = second
            guard var date = calendar.date(from: components) else { continue }
            if date.timeIntervalSince(now) > 3600 {
                // year boundary: a Dec 31 line scanned on Jan 1
                components.year = (components.year ?? 0) - 1
                guard let adjusted = calendar.date(from: components) else { continue }
                date = adjusted
            }
            if now.timeIntervalSince(date) <= 24 * 3600, now.timeIntervalSince(date) >= -300 {
                count += 1
            }
        }
        return count
    }

    static private func deriverAlive() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "src.deriver"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Short HEAD sha of the Honcho checkout, resolved without spawning git
    /// (handles both loose refs and packed-refs, plus detached HEAD).
    static private func repoVersion(at repo: String) -> String? {
        let headPath = repo + "/.git/HEAD"
        guard let head = try? String(contentsOfFile: headPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard head.hasPrefix("ref: ") else { return String(head.prefix(7)) }

        let ref = String(head.dropFirst(5))
        if let sha = try? String(contentsOfFile: repo + "/.git/" + ref, encoding: .utf8) {
            return String(sha.trimmingCharacters(in: .whitespacesAndNewlines).prefix(7))
        }
        if let packed = try? String(contentsOfFile: repo + "/.git/packed-refs", encoding: .utf8) {
            for line in packed.split(separator: "\n") where line.hasSuffix(Substring(ref)) {
                return String(line.prefix(7))
            }
        }
        return nil
    }

    // MARK: http helpers

    private func getJSON(_ url: String, completion: @escaping ([String: Any]?) -> Void) {
        guard let endpoint = URL(string: url) else { completion(nil); return }
        self.session.dataTask(with: endpoint) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            DispatchQueue.main.async { completion(json) }
        }.resume()
    }

    private func postJSON(_ url: String, body: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        guard let endpoint = URL(string: url),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { completion(nil); return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        self.session.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            DispatchQueue.main.async { completion(json) }
        }.resume()
    }
}

// MARK: - pill (hero card header)

internal final class HonchoStatusPill: NSView {
    internal var onClick: (() -> Void)?
    private var expanded = false

    private let dot = NSView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.cornerRadius = 10
        self.layer?.borderWidth = Design.cardBorderWidth
        self.heightAnchor.constraint(equalToConstant: 20).isActive = true

        self.dot.wantsLayer = true
        self.dot.layer?.cornerRadius = 3.5
        self.dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            self.dot.widthAnchor.constraint(equalToConstant: 7),
            self.dot.heightAnchor.constraint(equalToConstant: 7)
        ])

        self.icon.image = NSImage(systemSymbolName: "brain", accessibilityDescription: "Honcho")
        self.icon.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        self.icon.contentTintColor = .systemPurple
        self.icon.setContentHuggingPriority(.required, for: .horizontal)

        self.label.font = Design.subFont
        self.label.textColor = Design.secondaryTextColor
        self.label.lineBreakMode = .byTruncatingTail
        self.label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [self.dot, self.icon, self.label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor)
        ])

        self.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(self.clicked)))
        self.toolTip = localizedString("Honcho memory status")
        self.render(HonchoStatusModel())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    @objc private func clicked() { self.onClick?() }

    internal func set(_ model: HonchoStatusModel, expanded: Bool) {
        self.expanded = expanded
        self.render(model)
    }

    private func render(_ model: HonchoStatusModel) {
        let reachable = model.reachable ?? false
        self.dot.layer?.backgroundColor = (model.reachable == nil
            ? NSColor.systemGray
            : reachable ? Design.good : Design.critical).cgColor

        var parts = [localizedString("Honcho memory")]
        switch model.reachable {
        case .none: parts.append("…")
        case .some(false): parts.append(localizedString("Offline"))
        case .some(true): parts.append(localizedString("Online"))
        }
        if reachable {
            parts.append("\(localizedString("Queue")) \(model.queuePending.map(String.init) ?? "–")")
            parts.append("\(localizedString("Timeouts")) \(model.timeouts24h.map(String.init) ?? "–")")
        }
        self.label.stringValue = parts.joined(separator: " · ")

        self.layer?.backgroundColor = (self.expanded ? Design.cardHoverFill : Design.cardFill).cgColor
        self.layer?.borderColor = Design.cardBorder.cgColor
    }

    override func updateLayer() {
        self.layer?.borderColor = Design.cardBorder.cgColor
        self.layer?.backgroundColor = (self.expanded ? Design.cardHoverFill : Design.cardFill).cgColor
        super.updateLayer()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        self.addCursorRect(self.bounds, cursor: .pointingHand)
    }
}

// MARK: - detail strip (expandable row under the hero header)

internal final class HonchoDetailStrip: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.heightAnchor.constraint(equalToConstant: 22).isActive = true

        self.label.font = Design.subFont
        self.label.textColor = Design.mutedTextColor
        self.label.lineBreakMode = .byTruncatingTail
        self.label.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.label)
        NSLayoutConstraint.activate([
            self.label.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.label.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 10),
            self.label.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    internal func set(_ model: HonchoStatusModel) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        func count(_ value: Int?) -> String {
            guard let value = value else { return "–" }
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }
        let deriver: String
        switch model.deriverRunning {
        case .none: deriver = "–"
        case .some(true): deriver = localizedString("Running")
        case .some(false): deriver = localizedString("Stopped")
        }
        self.label.stringValue = [
            "\(localizedString("Sessions")) \(count(model.sessions))",
            "\(localizedString("Conclusions")) \(count(model.conclusions))",
            "deriver \(deriver)",
            "\(localizedString("Version")) \(model.version ?? "–")"
        ].joined(separator: "  ·  ")
        self.updateLayer()
    }

    override func updateLayer() {
        self.layer?.backgroundColor = Design.cardFill.cgColor
        super.updateLayer()
    }
}
