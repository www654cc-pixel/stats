//
//  ProxyTrafficLedger.swift
//  Stats
//
//  Always-on per-node traffic accounting for the mihomo proxy. Polls the
//  external-controller /connections endpoint every 2 s (independent of panel
//  visibility), attributes each connection's cumulative byte counters to its
//  exit node (top-level chains[0]) and accumulates the deltas into per-day
//  buckets persisted to Application Support/proxy-traffic.json.
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
    private let pollInterval: TimeInterval = 2
    private var started = false

    // last computed per-interval speed (bytes per second), for the UI
    private(set) var speedUp: Int64 = 0
    private(set) var speedDown: Int64 = 0
    private var lastTotals: (up: Int64, down: Int64)?

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
        DispatchQueue.main.async {
            guard !self.started else { return }
            self.started = true
            self.poll()
            self.timer = Timer.scheduledTimer(withTimeInterval: self.pollInterval, repeats: true) { [weak self] _ in
                self?.poll()
            }
        }
    }

    // MARK: - public read API (main-thread safe)

    /// Current node's usage: (monthUp, monthDown, todayUp, todayDown).
    internal func usage(node: String) -> (Int64, Int64, Int64, Int64) {
        self.queue.sync {
            var mUp: Int64 = 0, mDown: Int64 = 0, tUp: Int64 = 0, tDown: Int64 = 0
            let prefix = self.monthPrefix
            for (day, nodes) in self.store.days where day.hasPrefix(prefix) {
                guard let b = nodes[node] else { continue }
                mUp += b.up
                mDown += b.down
                if day == self.todayKey {
                    tUp = b.up
                    tDown = b.down
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
        guard let url = URL(string: self.base + "/connections") else { return }
        self.session.dataTask(with: url) { [weak self] data, _, err in
            guard let self = self else { return }
            guard err == nil, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // controller unreachable: drop stale speed and the totals
                // baseline so a mihomo restart (counter reset) can't produce
                // a bogus reading on recovery
                self.queue.async {
                    self.speedUp = 0
                    self.speedDown = 0
                    self.lastTotals = nil
                }
                return
            }
            let connections = json["connections"] as? [[String: Any]] ?? []
            let totalUp = (json["uploadTotal"] as? NSNumber)?.int64Value ?? 0
            let totalDown = (json["downloadTotal"] as? NSNumber)?.int64Value ?? 0
            self.queue.async { self.book(connections, totalUp: totalUp, totalDown: totalDown) }
        }.resume()
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
            let node = chains.first ?? "DIRECT"

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
        // churn, unlike the per-connection counters)
        if let prev = self.lastTotals {
            self.speedUp = max(totalUp - prev.up, 0) / Int64(self.pollInterval)
            self.speedDown = max(totalDown - prev.down, 0) / Int64(self.pollInterval)
        }
        self.lastTotals = (up: totalUp, down: totalDown)

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
