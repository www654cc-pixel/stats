//
//  ProxyRemoteTraffic.swift
//  Stats
//
//  Queries the hk VPS vnstat daemon via SSH to report the server's global
//  network traffic (all services, not just proxy). This is the ground-truth
//  number for a VPS with a bandwidth cap — local mihomo counters only see
//  one client and reset on process restart.
//

import Foundation
import Kit

internal class ProxyRemoteTraffic {

    static let shared = ProxyRemoteTraffic()

    // MARK: - config

    private let sshAlias = "hkvps"
    private let iface = "ens17"

    // MARK: - published state (thread-safe via queue)

    private let queue = DispatchQueue(label: "eu.exelban.Stats.ProxyRemoteTraffic")
    private let stateLock = NSLock()
    private var activeProcess: Process?
    private var lifecycleGeneration: UInt64 = 0

    private var monthRx: Int64 = 0
    private var monthTx: Int64 = 0
    private var dayRx: Int64 = 0
    private var dayTx: Int64 = 0
    private var totalsState: ProxyRemoteTrafficDataState = .loading

    // MARK: - timers

    private var started = false
    private var fetchingTotals = false

    // MARK: - public API

    /// Returns the latest cached values without performing network work.
    internal func snapshot() -> ProxyRemoteTrafficSnapshot {
        self.withState {
            ProxyRemoteTrafficSnapshot(
                monthRx: self.monthRx,
                monthTx: self.monthTx,
                dayRx: self.dayRx,
                dayTx: self.dayTx,
                totalsState: self.totalsState
            )
        }
    }

    private func withState<T>(_ body: () -> T) -> T {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return body()
    }

    internal func totals() -> (monthRx: Int64, monthTx: Int64, dayRx: Int64, dayTx: Int64) {
        let value = self.snapshot()
        return (value.monthRx, value.monthTx, value.dayRx, value.dayTx)
    }

    /// Fetches once per panel appearance. Idempotent and main-thread-owned.
    internal func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        let generation: UInt64? = self.withState {
            guard !self.started else { return nil }
            self.started = true
            self.lifecycleGeneration &+= 1
            self.totalsState = .loading
            return self.lifecycleGeneration
        }
        guard let generation else { return }

        // Fetch once per panel appearance. The popup owns this lifecycle, so
        // there is no background SSH timer while the dashboard is closed.
        self.queue.async { [weak self] in self?.fetchTotals(generation: generation) }
    }

    /// Stops future polling and cancels an SSH command already in flight.
    internal func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        let shouldCancel = self.withState { () -> Bool in
            guard self.started else { return false }
            self.started = false
            self.lifecycleGeneration &+= 1
            return true
        }
        guard shouldCancel else { return }
        self.cancelActiveProcess()
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        self.withState { self.started && self.lifecycleGeneration == generation }
    }

    private func cancelActiveProcess() {
        let process: Process? = self.withState { self.activeProcess }
        if let process, process.isRunning {
            process.terminate()
        }
    }

    // MARK: - SSH helpers

    /// Runs a command on the remote VPS via SSH and returns stdout. Blocking,
    /// but always called on the private utility queue, never the main thread.
    private func ssh(_ remoteCmd: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-o", "ConnectTimeout=8",
                          "-o", "BatchMode=yes",
                          "-o", "StrictHostKeyChecking=yes",
                          self.sshAlias, remoteCmd]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in finished.signal() }
        self.withState { self.activeProcess = proc }
        defer {
            self.withState {
                if self.activeProcess === proc { self.activeProcess = nil }
            }
        }
        do {
            try proc.run()
        } catch {
            return nil
        }
        if finished.wait(timeout: .now() + 12) == .timedOut {
            proc.terminate()
            _ = finished.wait(timeout: .now() + 2)
            return nil
        }

        guard proc.terminationStatus == 0 else { return nil }
        let data = try? pipe.fileHandleForReading.readToEnd()
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }


    // MARK: - fetchTotals

    /// Fetches month and day JSON in one SSH round-trip. Period values are
    /// selected from vnStat's dated arrays; `traffic.total` is all-time and
    /// must never be used for month/day display.
    private func fetchTotals(generation: UInt64) {
        guard self.isCurrent(generation) else { return }
        guard !self.fetchingTotals else { return }
        self.fetchingTotals = true
        defer { self.fetchingTotals = false }

        let sentinel = "---VSTAT-SPLIT---"
        guard let output = self.ssh("vnstat -i \(self.iface) --json m && echo '\(sentinel)' && vnstat -i \(self.iface) --json d") else {
            self.withState {
                guard self.started && self.lifecycleGeneration == generation else { return }
                self.totalsState = .stale
            }
            return
        }

        guard self.isCurrent(generation) else { return }
        let parts = output.components(separatedBy: sentinel)
        guard parts.count >= 2,
              let totals = ProxyRemoteTrafficParser.parseTotals(
                monthJSON: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                dayJSON: parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
              ) else {
            self.withState {
                guard self.started && self.lifecycleGeneration == generation else { return }
                self.totalsState = .stale
            }
            return
        }

        self.withState {
            guard self.started && self.lifecycleGeneration == generation else { return }
            self.monthRx = totals.monthRx
            self.monthTx = totals.monthTx
            self.dayRx = totals.dayRx
            self.dayTx = totals.dayTx
            self.totalsState = .live
        }
    }
}
