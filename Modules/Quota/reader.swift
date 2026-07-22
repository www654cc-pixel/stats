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
    var utilization: Double      // 0-100 (consumed %)
    var resetsAt: String?        // human readable reset time
}

public struct CodexQuota: Codable {
    var windows: [CodexWindow] = []
    var accountId: String?
    var error: String?
}

public struct KimiQuota: Codable {
    // 5 小时窗口 (limits[0], window.duration == 300 分钟)
    var fiveHourLimit: Double?
    var fiveHourRemaining: Double?
    var fiveHourReset: String?
    // 周/套餐额度 (usage)
    var weeklyLimit: Double?
    var weeklyUsed: Double?
    var weeklyRemaining: Double?
    var weeklyReset: String?
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
    var updatedAt: Date?
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

    public override func read() {
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
            var data = QuotaData()
            data.kimi = kimi
            data.codex = codex
            data.updatedAt = Date()
            if kimiErr != nil, codex == nil {
                data.error = kimiErr
            }
            self.callback(data)
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
                q.weeklyRemaining = Self.toDouble(usage["remaining"])
                q.weeklyReset = Self.isoToReadable(usage["resetTime"] as? String)
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
                    let rem = Self.toDouble(detail?["remaining"])
                    let reset = Self.isoToReadable(detail?["resetTime"] as? String)
                    if secs == 18000 {
                        q.fiveHourLimit = lim
                        q.fiveHourRemaining = rem
                        q.fiveHourReset = reset
                    } else if secs >= 604800 {
                        q.weeklyLimit = lim
                        q.weeklyRemaining = rem
                        q.weeklyReset = reset
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

        self.performCodexRequest(access: token.access, account: token.account) { [weak self] http, data in
            guard let self else { completion(result); return }

            // Refresh once on 401, then retry.
            if let http, (http.statusCode == 401 || http.statusCode == 403) {
                self.refreshCodexToken { newAccess in
                    guard let newAccess else {
                        result.error = "Codex token 已过期，请重新登录 Codex"
                        completion(result)
                        return
                    }
                    self.performCodexRequest(access: newAccess, account: token.account) { http2, data2 in
                        self.parseCodex(data: data2, http: http2, into: &result)
                        completion(result)
                    }
                }
                return
            }

            self.parseCodex(data: data, http: http, into: &result)
            completion(result)
        }
    }

    private func performCodexRequest(access: String, account: String,
                                     completion: @escaping (HTTPURLResponse?, Data?) -> Void) {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            completion(nil, nil); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !account.isEmpty {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        self.session.dataTask(with: req) { data, resp, _ in
            completion(resp as? HTTPURLResponse, data)
        }.resume()
    }

    private func parseCodex(data: Data?, http: HTTPURLResponse?, into result: inout CodexQuota) {
        guard let data, let http = http, http.statusCode == 200,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = dict["rate_limit"] as? [String: Any] else {
            if let http, (http.statusCode == 401 || http.statusCode == 403) {
                result.error = "Codex token 已过期，请重新登录 Codex"
            } else {
                result.error = "Codex 响应解析失败 (HTTP \(http?.statusCode ?? -1))"
            }
            return
        }

        func parseWindow(_ w: [String: Any]?) -> CodexWindow? {
            guard let w, let used = w["used_percent"] as? Double else { return nil }
            let secs = w["limit_window_seconds"] as? Int64 ?? 0
            var resets: String?
            if let ts = w["reset_at"] as? Int64 {
                resets = Self.shortDate(TimeInterval(ts))
            }
            return CodexWindow(name: Self.windowName(secs), utilization: used, resetsAt: resets)
        }

        if let pw = parseWindow(rl["primary_window"] as? [String: Any]) { result.windows.append(pw) }
        if let sw = parseWindow(rl["secondary_window"] as? [String: Any]) { result.windows.append(sw) }
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
        if let d = v as? Double { return d }
        if let s = v as? String, let d = Double(s) { return d }
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

    private static func shortDate(_ ts: TimeInterval) -> String {
        let d = Date(timeIntervalSince1970: ts)
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: d)
    }

    private static func isoToReadable(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "MM-dd HH:mm"
        out.timeZone = .current
        return out.string(from: d)
    }
}
