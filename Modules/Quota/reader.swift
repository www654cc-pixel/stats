//
//  reader.swift
//  Quota
//
//  Quota reader: fetches Kimi For Coding plan quota and Codex (ChatGPT)
//  subscription quota. Request shapes mirror CC Switch (farion1231/cc-switch)
//  but the parsing matches the ACTUAL API responses on this machine
//  (verified 2026-07-21):
//    Kimi  : GET https://api.kimi.com/coding/v1/usages
//            -> usage.{limit,used,remaining,resetTime}  (套餐/周额度)
//            -> limits[0].{window.duration/minutes, detail.{limit,remaining,resetTime}} (5h 窗口)
//    Codex : GET https://chatgpt.com/backend-api/wham/usage
//            -> rate_limit.primary_window / secondary_window
//

import Cocoa
import Kit

// MARK: - Data model (must be Codable for the generic Reader<T>)

public struct CodexWindow: Codable {
    var name: String
    var durationSeconds: Int64? // API window identity; optional keeps older snapshots decodable
    var utilization: Double      // 0-100 (consumed %)
    var resetsAt: String?        // human readable reset time for the standalone Quota popup
    var resetAt: Date?           // original deadline retained for the dashboard's live countdown
}

public struct CodexQuota: Codable {
    var windows: [CodexWindow] = []
    var accountId: String?
    var error: String?

    var fiveHourWindow: CodexWindow? {
        self.windows.first { $0.durationSeconds == 18_000 }
    }

    var weeklyWindow: CodexWindow? {
        self.windows.first { $0.durationSeconds == 604_800 }
    }
}

public struct KimiQuota: Codable {
    // 5 小时窗口 (limits[0], window.duration == 300 分钟)
    var fiveHourLimit: Double?
    var fiveHourRemaining: Double?
    var fiveHourReset: String?
    var fiveHourResetAt: Date?
    // 周/套餐额度 (usage)
    var weeklyLimit: Double?
    var weeklyUsed: Double?
    var weeklyRemaining: Double?
    var weeklyReset: String?
    var weeklyResetAt: Date?
    var planTier: String?
    var accountStatus: String?

    var fiveHourRemainingPct: Double? {
        guard let l = fiveHourLimit, l > 0, let r = fiveHourRemaining else { return nil }
        return max(0, min(100, r / l * 100))
    }
    var weeklyRemainingPct: Double? {
        guard let l = weeklyLimit, l > 0, let r = weeklyRemaining else { return nil }
        return max(0, min(100, r / l * 100))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Claude (Anthropic) — FEATURE CURRENTLY CANCELLED / NOT DISPLAYED.
//
// The only authoritative source is Anthropic's official endpoint
//   GET https://api.anthropic.com/api/oauth/usage
// (the exact endpoint Claude Code's built-in /usage command queries). The
// percentages are computed SERVER-SIDE by Anthropic — NOT estimated locally.
//
// It requires the subscription OAuth token (sk-ant-oat01-…) that Claude Code
// writes to ~/.claude/.credentials.json or the macOS Keychain when you log in
// with a claude.ai plan ON THIS MACHINE. On this build host that token is
// absent (only the oauthAccount metadata/email exists), so the call can never
// succeed → the row was removed from the UI to avoid a permanently dead entry.
//
// TO RE-ENABLE: install Claude Code, run `claude` and `/login` with the
// claude.ai subscription on this Mac (writes the token locally), then:
//   1. add `var claude: ClaudeQuota?` back to QuotaData
//   2. re-add the fetchClaude() DispatchGroup call in read()
//   3. re-add the Claude row in portal.swift / popup.swift / main.swift
// fetchClaude() / readClaudeToken() below are correct and ready to use.
// ─────────────────────────────────────────────────────────────────────────────
public struct ClaudeQuota: Codable {
    var fiveHourUtil: Double?   // consumed % in the rolling 5h window (0-100)
    var fiveHourReset: String?
    var weeklyUtil: Double?     // consumed % in the rolling 7d window
    var weeklyReset: String?
    var subscriptionType: String?
    var error: String?
}

public struct QuotaData: Codable {
    var kimi: KimiQuota?
    var codex: CodexQuota?
    var updatedAt: Date?        // last read ATTEMPT
    var kimiUpdatedAt: Date?    // last time `kimi` actually came from the API
    var codexUpdatedAt: Date?   // last time `codex.windows` actually came from the API
    var kimiError: String?
    var error: String?
}

// MARK: - Reader

public class QuotaReader: Reader<QuotaData> {
    // Must match ModuleType.quota stringValue ("Quota") so it lines up with
    // the keys written by Settings (e.g. "Quota_kimiApiKey").
    private let title = "Quota"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// Guards against overlapping reads: the repeating timer and an on-demand
    /// refresh (panel opened) can otherwise fire two rounds of requests at once.
    private let flightQueue = DispatchQueue(label: "eu.exelban.quotaInFlight")
    private var _inFlight: Bool = false

    /// Access token obtained by refreshing during this app session. Codex CLI owns
    /// ~/.codex/auth.json, so we never write back — we just reuse it in memory.
    private var _cachedCodexAccess: String?
    private var cachedCodexAccess: String? {
        get { self.flightQueue.sync { self._cachedCodexAccess } }
        set { self.flightQueue.sync { self._cachedCodexAccess = newValue } }
    }

    public override func setup() {
        // Keep the reader's fallback aligned with the value shown in Settings.
        // Reader defaults to one second, which would otherwise poll both remote
        // quota APIs continuously until the user explicitly chose an interval.
        // The overview panel refreshes on open, so background polling only needs
        // to keep the (optional) menu bar text widget from going stale.
        self.defaultInterval = 1800
    }

    /// "刷新间隔 = 关闭": the overview panel's open-triggered fetch is the only
    /// trigger, so nothing polls in the background.
    private var backgroundPollingDisabled: Bool {
        Store.shared.int(key: "\(self.title)_updateInterval", defaultValue: 1800) == 0
    }

    public override func start() {
        guard self.backgroundPollingDisabled else {
            super.start()
            return
        }
        // Still read once at launch: the menu bar text widget and the restored
        // snapshot would otherwise stay empty until the panel is first opened.
        DispatchQueue.global(qos: .background).async { [weak self] in self?.read() }
    }

    public override func read() {
        let start: Bool = self.flightQueue.sync {
            if self._inFlight { return false }
            self._inFlight = true
            return true
        }
        guard start else {
            debug("Quota read already in flight, skipping", log: self.log)
            return
        }

        let group = DispatchGroup()
        var kimi: KimiQuota?
        var kimiErr: String?
        var codex: CodexQuota?

        group.enter()
        self.fetchKimi { q, err in
            kimi = q
            kimiErr = err
            group.leave()
        }

        group.enter()
        self.fetchCodex { c in
            codex = c
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.flightQueue.sync { self._inFlight = false }

            let previous = self.value
            var data = QuotaData()
            data.updatedAt = Date()

            // Kimi: a failed poll must not erase a good reading. Keep the last
            // one and record the error, so the UI can dim it instead of showing
            // "—" for up to a full poll interval after one network hiccup.
            if let kimi {
                data.kimi = kimi
                data.kimiUpdatedAt = data.updatedAt
                data.kimiError = nil
            } else if kimiErr != nil, let old = previous?.kimi {
                data.kimi = old
                data.kimiUpdatedAt = previous?.kimiUpdatedAt
                data.kimiError = kimiErr
            } else {
                // never configured, or no previous value to fall back to
                data.kimiError = kimiErr
            }

            // Codex: same rule, keyed on whether this round produced any window.
            if let codex, !codex.windows.isEmpty {
                data.codex = codex
                data.codexUpdatedAt = data.updatedAt
            } else if let old = previous?.codex, !old.windows.isEmpty {
                var merged = old
                merged.error = codex?.error
                data.codex = merged
                data.codexUpdatedAt = previous?.codexUpdatedAt
            } else {
                data.codex = codex
            }

            if data.kimi == nil, data.codex?.windows.isEmpty ?? true {
                data.error = kimiErr ?? data.codex?.error
            }
            self.callback(data)

            // Reader's own DB write is throttled to interval*10 (5h at a 30-minute
            // interval), which would leave a cold launch showing "—". Persist every
            // successful round so a restart starts from the last known numbers.
            if kimi != nil || !(codex?.windows.isEmpty ?? true) {
                self.save(data)
            }
        }
    }

    // MARK: Kimi For Coding

    private func fetchKimi(completion: @escaping (KimiQuota?, String?) -> Void) {
        let apiKey = Store.shared.string(key: "\(self.title)_kimiApiKey", defaultValue: "")
        guard !apiKey.isEmpty else {
            completion(nil, nil) // not configured -> skip silently
            return
        }

        guard let url = URL(string: "https://api.kimi.com/coding/v1/usages") else {
            completion(nil, "Invalid Kimi endpoint")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        self.session.dataTask(with: req) { data, resp, err in
            if let err {
                completion(nil, "Kimi 网络错误: \(err.localizedDescription)")
                return
            }
            guard let data, let http = resp as? HTTPURLResponse else {
                completion(nil, "Kimi 无响应")
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                completion(nil, "Kimi API Key 无效 (HTTP \(http.statusCode))")
                return
            }
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, "Kimi 响应解析失败")
                return
            }

            var q = KimiQuota()

            // 周/套餐额度
            if let usage = dict["usage"] as? [String: Any] {
                q.weeklyLimit = Self.toDouble(usage["limit"])
                q.weeklyUsed = Self.toDouble(usage["used"])
                // Kimi omits "remaining" entirely once the quota is exhausted
                // (verified 2026-07-30: {limit:"100", used:"100"} with no
                // remaining), so derive it rather than rendering "—" for 0%.
                q.weeklyRemaining = Self.remaining(usage)
                q.weeklyResetAt = QuotaCountdownFormatter.date(fromISO8601: usage["resetTime"] as? String)
                q.weeklyReset = q.weeklyResetAt.map(Self.shortDate) ?? (usage["resetTime"] as? String)
            }

            // 5 小时窗口 (limits[] 中 window.duration==300 分钟 == 18000s)
            if let limits = dict["limits"] as? [[String: Any]] {
                for l in limits {
                    guard let w = l["window"] as? [String: Any] else { continue }
                    let dur = w["duration"] as? Int ?? 0
                    let tu = w["timeUnit"] as? String
                    let secs = (tu == "TIME_UNIT_MINUTE") ? dur * 60 : dur
                    let detail = l["detail"] as? [String: Any]
                    let lim = Self.toDouble(detail?["limit"])
                    let rem = detail.flatMap { Self.remaining($0) }
                    let resetAt = QuotaCountdownFormatter.date(fromISO8601: detail?["resetTime"] as? String)
                    let reset = resetAt.map(Self.shortDate) ?? (detail?["resetTime"] as? String)
                    if secs == 18000 {
                        q.fiveHourLimit = lim
                        q.fiveHourRemaining = rem
                        q.fiveHourReset = reset
                        q.fiveHourResetAt = resetAt
                    } else if secs >= 604800 {
                        q.weeklyLimit = lim
                        q.weeklyRemaining = rem
                        q.weeklyReset = reset
                        q.weeklyResetAt = resetAt
                    }
                }
            }

            if let user = dict["user"] as? [String: Any],
               let membership = user["membership"] as? [String: Any],
               let level = membership["level"] as? String {
                q.planTier = level
            }
            q.accountStatus = dict["subType"] as? String

            completion(q, nil)
        }.resume()
    }

    // MARK: Codex (ChatGPT) quota

    private func fetchCodex(completion: @escaping (CodexQuota) -> Void) {
        var result = CodexQuota()
        let enableCodex = Store.shared.bool(key: "\(self.title)_enableCodex", defaultValue: true)
        guard enableCodex else {
            completion(result)
            return
        }

        guard let token = self.readCodexToken() else {
            result.error = "未找到 Codex 凭据 (~/.codex/auth.json)"
            completion(result)
            return
        }
        result.accountId = token.account

        // Prefer a token we refreshed earlier in this app session: the refreshed
        // access token is never written back to ~/.codex/auth.json, so without
        // this cache every single poll would pay for a refresh round-trip.
        let access = self.cachedCodexAccess ?? token.access

        self.performCodexRequest(access: access, account: token.account) { [weak self] http, data, err in
            guard let self else { completion(result); return }

            // Refresh once on 401, then retry.
            if let http, (http.statusCode == 401 || http.statusCode == 403) {
                self.refreshCodexToken { newAccess in
                    guard let newAccess else {
                        result.error = "Codex token 已过期，请重新登录 Codex"
                        completion(result)
                        return
                    }
                    self.cachedCodexAccess = newAccess
                    self.performCodexRequest(access: newAccess, account: token.account) { http2, data2, err2 in
                        self.parseCodex(data: data2, http: http2, error: err2, into: &result)
                        completion(result)
                    }
                }
                return
            }

            self.parseCodex(data: data, http: http, error: err, into: &result)
            completion(result)
        }
    }

    private func performCodexRequest(access: String, account: String,
                                     completion: @escaping (HTTPURLResponse?, Data?, Error?) -> Void) {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            completion(nil, nil, nil); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !account.isEmpty {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        self.session.dataTask(with: req) { data, resp, err in
            completion(resp as? HTTPURLResponse, data, err)
        }.resume()
    }

    private func parseCodex(data: Data?, http: HTTPURLResponse?, error: Error?, into result: inout CodexQuota) {
        // Distinguish "the network never answered" from "the answer surprised us":
        // both used to be reported as 解析失败 (HTTP -1), which hid every outage.
        if let error {
            result.error = "Codex 网络错误: \(error.localizedDescription)"
            return
        }
        guard let http else {
            result.error = "Codex 无响应"
            return
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            result.error = "Codex token 已过期，请重新登录 Codex"
            return
        }
        guard http.statusCode == 200 else {
            result.error = "Codex HTTP \(http.statusCode)"
            return
        }
        guard let data,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = dict["rate_limit"] as? [String: Any] else {
            result.error = "Codex 响应解析失败（无 rate_limit 字段）"
            return
        }

        // Windows are matched by duration downstream, so an unparseable window is
        // silently dropped. Be permissive about the numeric encoding, and report
        // which window keys were present but unusable — otherwise a server-side
        // schema change is indistinguishable from OpenAI retiring a window.
        func parseWindow(_ w: [String: Any]?) -> CodexWindow? {
            guard let w, let used = Self.toDouble(w["used_percent"]) else { return nil }
            let secs = Self.toInt64(w["limit_window_seconds"]) ?? 0
            let resetAt = Self.toInt64(w["reset_at"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return CodexWindow(
                name: Self.windowName(secs),
                durationSeconds: secs,
                utilization: used,
                resetsAt: resetAt.map(Self.shortDate),
                resetAt: resetAt
            )
        }

        var skipped: [String] = []
        for key in ["primary_window", "secondary_window"] {
            let raw = rl[key] as? [String: Any]
            if let w = parseWindow(raw) {
                result.windows.append(w)
            } else if raw != nil {
                skipped.append(key)
            }
        }
        if result.windows.isEmpty {
            result.error = skipped.isEmpty
                ? "Codex 未返回任何额度窗口"
                : "Codex 窗口无法解析: \(skipped.joined(separator: ", "))"
        } else if !skipped.isEmpty {
            debug("Codex windows present but unparseable: \(skipped.joined(separator: ", "))", log: self.log)
        }
    }

    // MARK: Codex token helpers

    private func readCodexToken() -> (access: String, account: String)? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = dict["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            return nil
        }
        let account = tokens["account_id"] as? String ?? ""
        return (access, account)
    }

    private func refreshCodexToken(completion: @escaping (String?) -> Void) {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = dict["tokens"] as? [String: Any],
              let refresh = tokens["refresh_token"] as? String else {
            completion(nil); return
        }

        guard let tokenURL = URL(string: "https://auth.openai.com/oauth/token") else {
            completion(nil); return
        }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(refresh)",
            "client_id=app_EMoamEEZ73f0CkXaXp7hrann",
            "redirect_uri=https://auth.openai.com/deviceauth/callback"
        ].joined(separator: "&")
        req.httpBody = body.data(using: .utf8)

        self.session.dataTask(with: req) { data, _, _ in
            guard let data,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = dict["access_token"] as? String else {
                completion(nil); return
            }
            completion(access)
        }.resume()
    }

    // MARK: Claude — official Anthropic usage endpoint

    /// Queries Anthropic's official usage endpoint (the same one Claude Code's
    /// built-in /usage command uses). Returns server-computed utilization
    /// percentages for the rolling 5h and 7d windows. No local estimation.
    private func fetchClaude(completion: @escaping (ClaudeQuota) -> Void) {
        var result = ClaudeQuota()

        guard let token = self.readClaudeToken() else {
            result.error = "未找到 Claude 订阅凭据（请在本机用订阅登录 Claude Code）"
            completion(result)
            return
        }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            result.error = "Invalid Claude usage endpoint"
            completion(result)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        self.session.dataTask(with: req) { data, resp, err in
            if let err {
                result.error = "Claude 网络错误: \(err.localizedDescription)"
                completion(result); return
            }
            guard let data, let http = resp as? HTTPURLResponse else {
                result.error = "Claude 无响应"; completion(result); return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                result.error = "Claude 凭据无效/已过期，请重新登录 Claude Code"
                completion(result); return
            }
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result.error = "Claude 响应解析失败"; completion(result); return
            }

            func window(_ key: String) -> (Double?, String?) {
                guard let w = dict[key] as? [String: Any] else { return (nil, nil) }
                let u = w["utilization"] as? Double
                let r = Self.isoToReadable(w["resets_at"] as? String)
                return (u, r)
            }

            let (fh, fhr) = window("five_hour")
            let (sd, sdr) = window("seven_day")
            result.fiveHourUtil = fh
            result.fiveHourReset = fhr
            result.weeklyUtil = sd
            result.weeklyReset = sdr
            if let eu = dict["extra_usage"] as? [String: Any],
               let t = eu["subscriptionType"] as? String {
                result.subscriptionType = t
            }
            completion(result)
        }.resume()
    }

    /// Reads the Claude subscription OAuth token. Claude Code stores it either
    /// in ~/.claude/.credentials.json or in the macOS Keychain under the
    /// service name "Claude Code-credentials". Returns the Bearer access token,
    /// or nil if Claude Code was never logged in with a subscription here.
    private func readClaudeToken() -> String? {
        // 1) ~/.claude/.credentials.json
        let credPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: credPath)),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = dict["claudeAiOauth"] as? [String: Any],
           let at = oauth["accessToken"] as? String, !at.isEmpty {
            return at
        }
        // 2) macOS Keychain
        if let out = self.runSecurity(args: ["find-generic-password",
                                             "-s", "Claude Code-credentials", "-w"]),
           let data = out.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = dict["claudeAiOauth"] as? [String: Any],
           let at = oauth["accessToken"] as? String, !at.isEmpty {
            return at
        }
        return nil
    }

    private func runSecurity(args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: formatting helpers

    private static func toDouble(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let s = v as? String, let d = Double(s) { return d }
        return nil
    }

    /// Kimi's `remaining` disappears from the payload when it hits zero, so fall
    /// back to limit - used. Returns nil only when neither form is available.
    private static func remaining(_ node: [String: Any]) -> Double? {
        if let r = Self.toDouble(node["remaining"]) { return r }
        guard let limit = Self.toDouble(node["limit"]),
              let used = Self.toDouble(node["used"]) else { return nil }
        return max(0, limit - used)
    }

    private static func toInt64(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { return n.int64Value }
        if let i = v as? Int64 { return i }
        if let s = v as? String, let i = Int64(s) { return i }
        return nil
    }

    private static func windowName(_ secs: Int64) -> String {
        switch secs {
        case 18000: return "5 小时"
        case 604800: return "7 天"
        case 2_592_000: return "30 天"
        default:
            let hours = secs / 3600
            return hours >= 24 ? "\(hours / 24) 天" : "\(hours) 小时"
        }
    }

    private static func shortDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }

    private static func isoToReadable(_ iso: String?) -> String? {
        guard let iso else { return nil }
        return QuotaCountdownFormatter.date(fromISO8601: iso).map(Self.shortDate) ?? iso
    }
}
