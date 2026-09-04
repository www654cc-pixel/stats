//
//  ProxyRemoteTrafficCore.swift
//  Stats
//
//  Pure parsing and period-selection logic for the remote vnStat collector.
//  Kept independent of AppKit and SSH so it can be regression-tested directly.
//

import Foundation

internal struct ProxyTrafficPollGate {
    private var inFlight = false

    internal mutating func begin() -> Bool {
        guard !self.inFlight else { return false }
        self.inFlight = true
        return true
    }

    internal mutating func finish() {
        self.inFlight = false
    }
}

internal enum ProxyTrafficRate {
    internal static func perSecond(delta: Int64, elapsed: TimeInterval) -> Int64 {
        let seconds = max(elapsed, 1)
        return Int64(Double(max(delta, 0)) / seconds)
    }
}

internal enum ProxyRemoteTrafficDataState: Equatable {
    case loading
    case live
    case stale
}

internal struct ProxyRemoteTrafficSnapshot: Equatable {
    internal let monthRx: Int64
    internal let monthTx: Int64
    internal let dayRx: Int64
    internal let dayTx: Int64
    internal let totalsState: ProxyRemoteTrafficDataState
}

internal struct ProxyRemoteTrafficTotals: Equatable {
    internal let monthRx: Int64
    internal let monthTx: Int64
    internal let dayRx: Int64
    internal let dayTx: Int64

    internal var monthTotal: Int64 { self.monthRx + self.monthTx }
    internal var dayTotal: Int64 { self.dayRx + self.dayTx }
}

internal enum ProxyRemoteTrafficParser {
    /// Parses vnStat's human-readable bitrate output. vnStat 2.x emits both
    /// `rx 123 kbit/s` and older/alternate `rx: 123 kbit/s` forms.
    internal static func parseBitrate(_ text: String, prefix: String) -> Double {
        let expected = prefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .lowercased()

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let parts = rawLine
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3 else { continue }
            let actual = parts[0]
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .lowercased()
            guard actual == expected, let value = Double(parts[1]) else { continue }

            switch parts[2].lowercased() {
            case "bit/s": return value / 1_000
            case "kbit/s": return value
            case "mbit/s": return value * 1_000
            case "gbit/s": return value * 1_000_000
            case "tbit/s": return value * 1_000_000_000
            case "b/s": return value * 8 / 1_000
            case "kb/s": return value * 8
            case "mb/s": return value * 8_000
            case "gb/s": return value * 8_000_000
            default: continue
            }
        }
        return 0
    }

    /// Reads the newest recorded month and day entries. `traffic.total` is
    /// deliberately ignored because it is the interface's all-time counter.
    internal static func parseTotals(monthJSON: String, dayJSON: String) -> ProxyRemoteTrafficTotals? {
        guard let month = latestPeriod(json: monthJSON, key: "month"),
              let day = latestPeriod(json: dayJSON, key: "day") else {
            return nil
        }
        return ProxyRemoteTrafficTotals(
            monthRx: month.rx,
            monthTx: month.tx,
            dayRx: day.rx,
            dayTx: day.tx
        )
    }

    private static func latestPeriod(json: String, key: String) -> (rx: Int64, tx: Int64)? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let interfaces = root["interfaces"] as? [[String: Any]],
              let traffic = interfaces.first?["traffic"] as? [String: Any],
              let entries = traffic[key] as? [[String: Any]],
              let entry = entries.max(by: { periodSortValue($0) < periodSortValue($1) }),
              let rx = integer(entry["rx"]),
              let tx = integer(entry["tx"]) else {
            return nil
        }
        return (rx, tx)
    }

    private static func periodSortValue(_ entry: [String: Any]) -> Int64 {
        if let timestamp = integer(entry["timestamp"]) { return timestamp }
        guard let date = entry["date"] as? [String: Any],
              let year = integer(date["year"]),
              let month = integer(date["month"]) else { return 0 }
        let day = integer(date["day"]) ?? 0
        return year * 10_000_000 + month * 100 + day
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return nil
    }
}
