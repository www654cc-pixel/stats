//
//  ProxyTrafficLedger.swift
//  Stats
//
//  Always-on per-server traffic accounting for the mihomo proxy. Polls the
// external-controller /connections endpoint every 5 s (independent of panel
//  visibility), attributes each connection's cumulative byte counters to its
//  exit node (top-level chains[0]) mapped to its VPS (server host from the
//  mihomo config), and accumulates the deltas into per-day buckets persisted
//  to Application Support/proxy-traffic.json. Nodes that share a server
//  (e.g. HK-Trojan + HK-Hysteria2 on the same VPS) are booked under one key.
//
//  Accuracy notes:
//  - new connections are booked with their full counters (they are cumulative
//    since connection start), so at most the last <=2 s of a closing
//    connection is lost;
//  - connection snapshots are persisted too, so a Stats restart does not
//    double-count connections that outlive it (ids are mihomo UUIDs and are
//    stable while mihomo keeps running).
//

import Cocoa
import Kit

internal final class ProxyTrafficLedger {
    internal static let shared = ProxyTrafficLedger()

    // MARK: - persisted model

    private struct NodeBytes: Codable {
        var up: Int64 = 0
        var down: Int64 = 0
    }

    private struct ConnState: Codable {
        var node: String
        var up: Int64
        var down: Int64
        var seen: TimeInterval // unix timestamp
    }

    private struct DiskStore: Codable {
        var version: Int = 1
        var days: [String: [String: NodeBytes]] = [:] // "yyyy-MM-dd" -> node -> bytes
        var connections: [String: ConnState] = [:]    // mihomo connection id -> last booked counters
        // A node may move between VPS hosts. Keep every host it has used so
        // historical buckets remain visible after a config change.
        var nodeServerHistory: [String: [String]] = [:]

        private enum CodingKeys: String, CodingKey {
            case version, days, connections, nodeServerHistory
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            self.days = try c.decodeIfPresent([String: [String: NodeBytes]].self, forKey: .days) ?? [:]
            self.connections = try c.decodeIfPresent([String: ConnState].self, forKey: .connections) ?? [:]
            self.nodeServerHistory = try c.decodeIfPresent([String: [String]].self, forKey: .nodeServerHistory) ?? [:]
        }
    }

    // MARK: - state

    private let queue = DispatchQueue(label: "eu.exelban.Stats.proxy-traffic-ledger")
    private var store = DiskStore()
    private var dirty = false
    private var lastSaveAt: Date = .distantPast
    private let saveInterval: TimeInterval = 30
    private let dayRetention: TimeInterval = 62 * 24 * 3600
    private let connRetention: TimeInterval = 6 * 3600

    private var timer: Timer?
    // Five seconds keeps the persistent accounting window bounded while
    // avoiding an unconditional 43k requests/day for a menu-bar utility.
    private let pollInterval: TimeInterval = 5
    private var started = false
    // /connections can take longer than the 5 s timer interval. Only one
    // request may be in flight; otherwise late responses are interpreted as
    // counter resets and can be double-booked.
    private var pollGate = ProxyTrafficPollGate()

    // node name -> VPS server host, parsed from the mihomo config so traffic
    // from different protocols on the same VPS is booked under one key
    private var serverMap: [String: String] = [:]
    private var configMtime: Date?
    private var configPath: String {
        // ~/Documents is TCC-protected for this ad-hoc-signed app; the mihomo
        // run wrapper snapshots the config it launches with to ~/.config/mihomo
        // (live-config.yaml), which always matches the running core.
        let custom = Store.shared.string(key: "CombinedProxy_mihomoConfig", defaultValue: "")
        if !custom.isEmpty {
            return (custom as NSString).expandingTildeInPath
        }
        return NSHomeDirectory() + "/.config/mihomo/live-config.yaml"
    }

    // last computed per-interval speed (bytes per second), for the UI
    private(set) var speedUp: Int64 = 0
    private(set) var speedDown: Int64 = 0
    private var lastTotals: (up: Int64, down: Int64, at: TimeInterval)?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private var base: String {
        "http://" + Store.shared.string(key: "CombinedProxy_controller", defaultValue: "127.0.0.1:9090")
    }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("Stats/proxy-traffic.json")
    }

    /// v1 wrote the ledger to the Application Support root; move it into the
    /// Stats/ subdirectory once.
    private func migrateLegacyFile() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = dir.appendingPathComponent("proxy-traffic.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: self.fileURL.path) else { return }
        try? fm.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: legacy, to: self.fileURL)
    }

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var todayKey: String { self.dayFormatter.string(from: Date()) }
    private var monthPrefix: String { String(self.todayKey.prefix(7)) }

    private init() {
        self.migrateLegacyFile()
        self.load()
        // server map first, then the legacy key migration that depends on it
        self.queue.async {
            guard self.loadServerMapLocked(at: self.configPath) else { return }
            self.migrateToServerKeysLocked()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.sync { self?.saveLocked() }
        }
    }

    // MARK: - lifecycle

    /// Idempotent: starts the always-on poll timer. Called from ProxyPortal
    /// init/start; safe to call multiple times.
    internal func start() {
        DispatchQueue.main.async { [weak self] in
            guard let ledger = self, !ledger.started else { return }
            ledger.started = true
            ledger.poll()
            ledger.timer = Timer.scheduledTimer(withTimeInterval: ledger.pollInterval, repeats: true) { [weak ledger] _ in
                ledger?.poll()
            }
        }
    }

    // MARK: - public read API (main-thread safe)

    /// Current node's VPS usage: (monthUp, monthDown, todayUp, todayDown).
    /// The node is resolved to its server host first, so protocols sharing a
    /// VPS report the same merged totals.
    internal func usage(node: String) -> (Int64, Int64, Int64, Int64) {
        self.queue.sync {
            var keys = Set([self.serverMap[node] ?? node, node])
            keys.formUnion(self.store.nodeServerHistory[node] ?? [])
            var mUp: Int64 = 0, mDown: Int64 = 0, tUp: Int64 = 0, tDown: Int64 = 0
            let prefix = self.monthPrefix
            for (day, nodes) in self.store.days where day.hasPrefix(prefix) {
                for key in keys {
                    guard let b = nodes[key] else { continue }
                    mUp += b.up
                    mDown += b.down
                    if day == self.todayKey {
                        tUp += b.up
                        tDown += b.down
                    }
                }
            }
            return (mUp, mDown, tUp, tDown)
        }
    }

    internal func currentSpeed() -> (up: Int64, down: Int64) {
        self.queue.sync { (self.speedUp, self.speedDown) }
    }

    // MARK: - polling

    private func poll() {
        guard self.pollGate.begin() else { return }
        self.refreshServerMapIfNeeded()
        guard let url = URL(string: self.base + "/connections") else {
            self.pollGate.finish()
            return
        }
        self.session.dataTask(with: url) { [weak self] data, response, err in
            guard let self = self else { return }
            guard err == nil, let data = data,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.markPollFailure()
                return
            }
            guard let connections = json["connections"] as? [[String: Any]],
                  let totalUp = (json["uploadTotal"] as? NSNumber)?.int64Value,
                  let totalDown = (json["downloadTotal"] as? NSNumber)?.int64Value else {
                self.markPollFailure()
                return
            }
            self.queue.async {
                self.book(connections, totalUp: totalUp, totalDown: totalDown)
                DispatchQueue.main.async { self.pollGate.finish() }
            }
        }.resume()
    }


    private func markPollFailure() {
        self.queue.async {
            // controller unreachable or malformed: drop stale speed and the
            // totals baseline so recovery cannot create a bogus rate spike.
            self.speedUp = 0
            self.speedDown = 0
            self.lastTotals = nil
            DispatchQueue.main.async { self.pollGate.finish() }
        }
    }

    /// Books the per-connection deltas into today's bucket and derives the
    /// per-interval speed from the global totals. Runs on `queue`.
    private func book(_ connections: [[String: Any]], totalUp: Int64, totalDown: Int64) {
        let now = Date()
        let day = self.todayKey
        var dayNodes = self.store.days[day] ?? [:]
        var changed = false

        for conn in connections {
            guard let id = conn["id"] as? String else { continue }
            let up = (conn["upload"] as? NSNumber)?.int64Value ?? 0
            let down = (conn["download"] as? NSNumber)?.int64Value ?? 0
            let chains = conn["chains"] as? [String] ?? []
            let rawNode = chains.first ?? "DIRECT"
            // merge protocols that live on the same VPS under one key
            let node = self.serverMap[rawNode] ?? rawNode

            var deltaUp = up
            var deltaDown = down
            if let prev = self.store.connections[id] {
                // counters are per-connection cumulative; on wraparound (should
                // not happen) fall back to booking the full current value
                deltaUp = up >= prev.up ? up - prev.up : up
                deltaDown = down >= prev.down ? down - prev.down : down
            }
            self.store.connections[id] = ConnState(node: node, up: up, down: down, seen: now.timeIntervalSince1970)

            guard deltaUp > 0 || deltaDown > 0 else { continue }
            var b = dayNodes[node] ?? NodeBytes()
            b.up += deltaUp
            b.down += deltaDown
            dayNodes[node] = b
            changed = true
        }

        if changed {
            self.store.days[day] = dayNodes
            self.dirty = true
        }

        // speed from the global cumulative totals (stable across connection
        // churn, unlike the per-connection counters). Use the actual elapsed
        // response interval because SSH/API latency can exceed 2 seconds.
        if let prev = self.lastTotals {
            let elapsed = now.timeIntervalSince1970 - prev.at
            self.speedUp = ProxyTrafficRate.perSecond(delta: totalUp - prev.up, elapsed: elapsed)
            self.speedDown = ProxyTrafficRate.perSecond(delta: totalDown - prev.down, elapsed: elapsed)
        }
        self.lastTotals = (up: totalUp, down: totalDown, at: now.timeIntervalSince1970)

        self.prune(now: now)
        if self.dirty, now.timeIntervalSince(self.lastSaveAt) >= self.saveInterval {
            self.saveLocked()
        }
    }

    /// Drops day buckets older than the retention window and connection
    /// snapshots not seen for 6 h (mihomo restarts mint new ids).
    private func prune(now: Date) {
        let cutoffDay = self.dayFormatter.string(from: now.addingTimeInterval(-self.dayRetention))
        let oldDays = self.store.days.keys.filter { $0 < cutoffDay }
        oldDays.forEach { self.store.days.removeValue(forKey: $0) }

        let cutoffConn = now.timeIntervalSince1970 - self.connRetention
        let stale = self.store.connections.filter { $0.value.seen < cutoffConn }.map { $0.key }
        stale.forEach { self.store.connections.removeValue(forKey: $0) }

        if !oldDays.isEmpty || !stale.isEmpty { self.dirty = true }
    }

    // MARK: - server map (node name -> VPS host)

    /// Re-parses the mihomo config when its mtime changed (checked every
    /// poll; stat is cheap). The map is rebuilt atomically on `queue`.
    private func refreshServerMapIfNeeded() {
        let path = self.configPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return }
        guard self.configMtime != mtime else { return }
        self.queue.async {
            // Do not mark a timestamp as consumed before parsing succeeds;
            // transient TCC/file-write errors must be retried on the next poll.
            guard self.configMtime != mtime,
                  self.loadServerMapLocked(at: path) else { return }
            self.configMtime = mtime
        }
    }

    /// Minimal scanner for the top-level `proxies:` list: pairs each
    /// `- name: X` with the next `server: Y`. Not a YAML parser — only
    /// handles the block style mihomo configs use. Runs on `queue`.
    @discardableResult
    private func loadServerMapLocked(at path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        var map: [String: String] = [:]
        var inProxies = false
        var currentName: String?
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            // top-level key switch: column-0 keys end the proxies section.
            // NOTE: YAML list items may sit at column 0 too (`proxies:` then
            // `- name: ...` unindented) — a leading dash never ends a section.
            if indent == 0 && !trimmed.hasPrefix("-") {
                inProxies = trimmed.hasPrefix("proxies:")
                currentName = nil
                continue
            }
            guard inProxies else { continue }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                currentName = nil
                let rest = String(trimmed.dropFirst(trimmed == "-" ? 1 : 2))
                    .trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("name:") {
                    currentName = Self.unquote(String(rest.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                }
                continue
            }
            if trimmed.hasPrefix("name:"), currentName == nil {
                currentName = Self.unquote(String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.hasPrefix("server:"), let name = currentName, !name.isEmpty {
                let host = Self.unquote(String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces))
                if !host.isEmpty { map[name] = host }
            }
        }
        guard !map.isEmpty else { return false }
        self.serverMap = map
        var historyChanged = false
        for (node, host) in map {
            var hosts = self.store.nodeServerHistory[node] ?? []
            if !hosts.contains(host) {
                hosts.append(host)
                historyChanged = true
            }
            self.store.nodeServerHistory[node] = hosts
        }
        if historyChanged { self.dirty = true }
        return true
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { return String(s.dropFirst().dropLast()) }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") { return String(s.dropFirst().dropLast()) }
        return s
    }

    /// Legacy versions booked per node name; v3 books per server host (v2
    /// shipped with a config path the app could not read, so its merge ran
    /// with an empty map — re-run it). Merges existing day buckets through the server map
    /// once (unmapped keys, e.g. DIRECT or removed nodes, are kept as-is).
    /// Runs on `queue`.
    private func migrateToServerKeysLocked() {
        guard self.store.version < 3 else { return }
        var newDays: [String: [String: NodeBytes]] = [:]
        for (day, nodes) in self.store.days {
            var merged: [String: NodeBytes] = [:]
            for (node, b) in nodes {
                let key = self.serverMap[node] ?? node
                var m = merged[key] ?? NodeBytes()
                m.up += b.up
                m.down += b.down
                merged[key] = m
            }
            newDays[day] = merged
        }
        self.store.days = newDays
        self.store.version = 3
        self.dirty = true
        self.saveLocked()
    }

    // MARK: - persistence (queue-confined)

    private func load() {
        self.queue.sync {
            guard let data = try? Data(contentsOf: self.fileURL),
                  let decoded = try? JSONDecoder().decode(DiskStore.self, from: data) else { return }
            self.store = decoded
        }
    }

    /// Must be called on `queue`. Atomic write via temporary file + replace.
    private func saveLocked() {
        guard let data = try? JSONEncoder().encode(self.store) else { return }
        let url = self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            self.dirty = false
            self.lastSaveAt = Date()
        } catch {
            NSLog("ProxyTrafficLedger: save failed: \(error.localizedDescription)")
        }
    }
}
