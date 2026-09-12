//
//  LocalServerControl.swift
//  Stats
//
//  Start/stop switches for the local "web UI" servers that run as per-user
//  LaunchAgents — the Kimi Code server (`com.kimi.server`, 127.0.0.1:58627)
//  and the DeepSeek Harness server (`com.deepseek.server`, 127.0.0.1:58628) —
//  rendered at the trailing edge of the combined panel's navigation bar.
//
//  The jobs are declared with KeepAlive=true, so a process cannot be stopped
//  by signalling it: launchd would bring it back within a second. Toggling
//  therefore goes through launchctl — stop is `disable` + `bootout`, start is
//  `enable` + `bootstrap` — and no admin rights are involved because both the
//  plist and the gui domain belong to the current user.
//

import Cocoa
import Kit

/// Everything that differs between the servers the panel can steer.
internal struct LocalServerSpec {
    /// How a server proves it is alive.
    enum ProbeStyle {
        /// GET `/<probePath>` answers 200 with a body (Kimi's meta API).
        case jsonAPI
        /// Any HTTP status means the port answers — DeepSeek's token fence
        /// replies 401 to an unauthenticated `GET /`.
        case anyResponse
    }

    let label: String
    let port: Int
    let titleKey: String
    let startKey: String
    let stopKey: String
    let openKey: String
    let startingKey: String
    let stoppingKey: String
    let failedKey: String
    let probePath: String
    let probeStyle: ProbeStyle
    /// Servers that rotate their access token per launch print the Web UI
    /// URL (including `?token=`) into this LaunchAgent log — the open button
    /// reads the newest link from there instead of guessing.
    let tokenLinkLogPath: String?

    var baseURL: URL { URL(string: "http://127.0.0.1:\(self.port)/")! }

    static let kimi = LocalServerSpec(
        label: "com.kimi.server",
        port: 58627,
        titleKey: "Kimi Code",
        startKey: "Start Kimi Code server",
        stopKey: "Stop Kimi Code server and free its memory",
        openKey: "Open Kimi web UI",
        startingKey: "Kimi Code is starting…",
        stoppingKey: "Kimi Code is stopping…",
        failedKey: "Kimi Code failed",
        probePath: "api/v1/meta",
        probeStyle: .jsonAPI,
        tokenLinkLogPath: nil
    )

    static let deepseek = LocalServerSpec(
        label: "com.deepseek.server",
        port: 58628,
        titleKey: "DeepSeek Harness",
        startKey: "Start DeepSeek server",
        stopKey: "Stop DeepSeek server and free its memory",
        openKey: "Open DeepSeek web UI",
        startingKey: "DeepSeek is starting…",
        stoppingKey: "DeepSeek is stopping…",
        failedKey: "DeepSeek failed",
        probePath: "",
        probeStyle: .anyResponse,
        tokenLinkLogPath: "Library/Logs/deepseek-server.log"
    )
}

internal final class LocalServer {
    internal enum Status: Equatable {
        /// No LaunchAgent on this machine — the control hides itself.
        case unavailable
        case stopped
        case starting
        case running
        case stopping
        case failed(String)

        var busy: Bool { self == .starting || self == .stopping }
    }

    internal let spec: LocalServerSpec
    internal private(set) var status: Status = .stopped
    internal var onChange: ((Status) -> Void)?

    /// A start the user asked for ends by opening the web UI — a switch that
    /// only makes a process exist is not something the panel's user can act on.
    private var openWhenReady = false

    private let plist: URL
    private let domain = "gui/\(getuid())"
    private let session: URLSession
    private let queue: DispatchQueue

    internal init(spec: LocalServerSpec) {
        self.spec = spec
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.plist = home.appendingPathComponent("Library/LaunchAgents/\(spec.label).plist")
        self.queue = DispatchQueue(label: "eu.exelban.Stats.server.\(spec.label)", qos: .userInitiated)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    internal var installed: Bool {
        FileManager.default.fileExists(atPath: self.plist.path)
    }

    // MARK: - state

    private func publish(_ new: Status) {
        DispatchQueue.main.async {
            guard self.status != new else { return }
            self.status = new
            self.onChange?(new)
        }
    }

    /// Re-sync with the outside world — called when the panel opens, and after
    /// a failed transition. A state the user did not set from here (a manual
    /// launchctl in a terminal) would otherwise be shown stale.
    internal func refresh() {
        guard self.installed else { return self.publish(.unavailable) }
        guard !self.status.busy else { return }
        self.probe { running in self.publish(running ? .running : .stopped) }
    }

    // MARK: - toggle

    internal func toggle() {
        switch self.status {
        case .running:
            self.stop()
        case .stopped:
            self.start()
        case .failed:
            // the failure left the real state unknown — look, then act opposite
            self.probe { running in running ? self.stop() : self.start() }
        case .starting, .stopping, .unavailable:
            break
        }
    }

    internal func start() {
        guard self.installed, !self.status.busy else { return }
        self.openWhenReady = true
        self.publish(.starting)
        self.queue.async {
            _ = self.launchctl(["enable", "\(self.domain)/\(self.spec.label)"])
            let (code, output) = self.launchctl(["bootstrap", self.domain, self.plist.path])
            // a bootstrap failure is not fatal on its own: the job may simply
            // have been loaded already, in which case the port probe succeeds
            self.settle(expectRunning: true, failure: output.isEmpty ? "launchctl bootstrap: exit \(code)" : output)
        }
    }

    internal func stop() {
        guard self.installed, !self.status.busy else { return }
        self.openWhenReady = false
        self.publish(.stopping)
        self.queue.async {
            // `disable` must come with the unload: RunAtLoad would otherwise
            // resurrect the server at the next login, which is not what "off"
            // means to someone who just switched it off.
            _ = self.launchctl(["disable", "\(self.domain)/\(self.spec.label)"])
            let (code, output) = self.launchctl(["bootout", "\(self.domain)/\(self.spec.label)"])
            self.settle(expectRunning: false, failure: output.isEmpty ? "launchctl bootout: exit \(code)" : output)
        }
    }

    internal func openWebUI() {
        NSWorkspace.shared.open(self.webURLLink())
    }

    /// The URL worth opening: the newest token-carrying link from the launch
    /// log when the server rotates tokens (the token survives in the browser
    /// only as long as its query URL is used), the plain root otherwise.
    private func webURLLink() -> URL {
        guard let logPath = self.spec.tokenLinkLogPath else { return self.spec.baseURL }
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let text = try? String(contentsOf: home.appendingPathComponent(logPath), encoding: .utf8) else {
            return self.spec.baseURL
        }
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("token="), let start = line.range(of: "http://") else { continue }
            let raw = line[start.lowerBound...].trimmingCharacters(in: .whitespaces)
            if let url = URL(string: raw) { return url }
        }
        return self.spec.baseURL
    }

    // MARK: - probing

    /// The listening port is the source of truth: `launchctl print` reports a
    /// job as running a moment before the server actually accepts connections,
    /// and says nothing about a worker that failed to bind.
    private func probe(_ done: @escaping (Bool) -> Void) {
        let url: URL = self.spec.probeStyle == .jsonAPI
            ? self.spec.baseURL.appendingPathComponent(self.spec.probePath)
            : self.spec.baseURL
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        self.session.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            let running: Bool
            switch self.spec.probeStyle {
            case .jsonAPI:
                running = http?.statusCode == 200 && data != nil
            case .anyResponse:
                // a token fence answers 401 to an unauthenticated GET / —
                // any answered status still proves the port serves
                running = http != nil
            }
            DispatchQueue.main.async { done(running) }
        }.resume()
    }

    /// Poll the port until it matches the intended state, then publish it.
    private func settle(expectRunning: Bool, failure: String, attempt: Int = 0) {
        self.probe { running in
            if running == expectRunning {
                let open = expectRunning && self.openWhenReady
                self.openWhenReady = false
                self.publish(expectRunning ? .running : .stopped)
                if open {
                    self.openWebUI()
                }
                return
            }
            guard attempt < 66 else { // ≈20 s, enough for either server's cold start
                self.openWhenReady = false
                self.publish(.failed(failure))
                return
            }
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                self.settle(expectRunning: expectRunning, failure: failure, attempt: attempt + 1)
            }
        }
    }

    // MARK: - launchctl

    private func launchctl(_ arguments: [String]) -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (task.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

internal final class LocalServerControl: NSStackView {
    private let spec: LocalServerSpec
    private let server: LocalServer
    private let title = NSButton()
    private let power = NSButton()
    private let open = NSButton()
    private let spinner = NSProgressIndicator()

    internal init(spec: LocalServerSpec) {
        self.spec = spec
        self.server = LocalServer(spec: spec)
        super.init(frame: .zero)

        self.orientation = .horizontal
        self.alignment = .centerY
        self.spacing = 5

        self.title.title = localizedString(spec.titleKey)
        self.title.isBordered = false
        self.title.focusRingType = .none
        self.title.font = Design.labelFont
        self.title.contentTintColor = Design.secondaryTextColor
        self.title.target = self
        self.title.action = #selector(self.toggle)
        self.title.setContentHuggingPriority(.required, for: .horizontal)

        self.power.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        self.power.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        self.power.isBordered = false
        self.power.focusRingType = .none
        self.power.target = self
        self.power.action = #selector(self.toggle)

        self.open.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
        self.open.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        self.open.isBordered = false
        self.open.focusRingType = .none
        self.open.contentTintColor = Design.mutedTextColor
        self.open.toolTip = localizedString(spec.openKey)
        self.open.setAccessibilityLabel(localizedString(spec.openKey))
        self.open.target = self
        self.open.action = #selector(self.openWeb)

        self.spinner.style = .spinning
        self.spinner.controlSize = .small
        self.spinner.isDisplayedWhenStopped = false

        // the spinner takes the power button's slot while a transition runs, so
        // both are pinned to the same width and the row never shifts
        for icon in [self.power, self.spinner] {
            icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        }
        self.spinner.heightAnchor.constraint(equalToConstant: 22).isActive = true
        self.open.widthAnchor.constraint(equalToConstant: 20).isActive = true

        for view in [self.title, self.power, self.spinner, self.open] as [NSView] {
            self.addArrangedSubview(view)
        }

        self.server.onChange = { [weak self] _ in self?.render() }
        self.render()
        self.server.refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    internal func refresh() {
        self.server.refresh()
    }

    @objc private func toggle() {
        self.server.toggle()
    }

    @objc private func openWeb() {
        self.server.openWebUI()
    }

    private func render() {
        let status = self.server.status
        self.isHidden = status == .unavailable

        self.power.isHidden = status.busy
        self.open.isHidden = status != .running
        if status.busy {
            self.spinner.startAnimation(nil)
        } else {
            self.spinner.stopAnimation(nil)
        }

        switch status {
        case .running:
            self.power.contentTintColor = Design.good
        case .stopped:
            self.power.contentTintColor = Design.mutedTextColor
        case .failed:
            self.power.contentTintColor = Design.critical
        default:
            self.power.contentTintColor = Design.accent
        }

        let tip: String
        switch status {
        case .unavailable:
            return
        case .stopped:
            tip = localizedString(self.spec.startKey)
        case .starting:
            tip = localizedString(self.spec.startingKey)
        case .running:
            tip = localizedString(self.spec.stopKey)
        case .stopping:
            tip = localizedString(self.spec.stoppingKey)
        case .failed(let detail):
            tip = "\(localizedString(self.spec.failedKey)): \(detail)"
        }
        self.title.toolTip = tip
        self.power.toolTip = tip
        // the symbol's own name ("power") is not a useful spoken label
        self.power.setAccessibilityLabel(tip)
    }
}
