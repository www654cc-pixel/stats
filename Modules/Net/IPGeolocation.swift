import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum Network_IPAddressKind: Equatable {
    case publicAddress
    case privateAddress
    case loopback
    case linkLocal
    case invalid
}

public struct Network_IPLocation: Codable, Equatable {
    public var country: String?
    public var countryCode: String?
    public var region: String?
    public var city: String?
    public var district: String?

    public init(country: String? = nil, countryCode: String? = nil, region: String? = nil, city: String? = nil, district: String? = nil) {
        self.country = country
        self.countryCode = countryCode
        self.region = region
        self.city = city
        self.district = district
    }
}

public enum Network_IPLocationState: String, Codable {
    case idle
    case loading
    case available
    case unavailable
}

public enum IPGeolocationCore {
    private struct IPWhoResponse: Decodable {
        let success: Bool?
        let country: String?
        let countryCode: String?
        let region: String?
        let city: String?
        let district: String?

        enum CodingKeys: String, CodingKey {
            case success
            case country
            case countryCode = "country_code"
            case region
            case city
            case district
        }
    }

    public static func classify(_ address: String) -> Network_IPAddressKind {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .invalid }

        if value.contains(":") {
            guard let bytes = parseIPv6(value) else { return .invalid }
            return classifyIPv6(bytes)
        }
        if value.contains(".") {
            guard let bytes = parseIPv4(value) else { return .invalid }
            return classifyIPv4(bytes)
        }
        return .invalid
    }

    public static func decode(_ data: Data) -> Network_IPLocation? {
        guard let response = try? JSONDecoder().decode(IPWhoResponse.self, from: data), response.success == true else {
            return nil
        }
        let location = Network_IPLocation(
            country: response.country,
            countryCode: response.countryCode?.uppercased(),
            region: response.region,
            city: response.city,
            district: response.district
        )
        return summary(location) == nil ? nil : location
    }

    public static func summary(_ location: Network_IPLocation) -> String? {
        let values = [
            localizedCountry(location.country, code: location.countryCode),
            normalizedChinaName(location.region, kind: .region, code: location.countryCode),
            normalizedChinaName(location.city, kind: .city, code: location.countryCode),
            normalizedChinaName(location.district, kind: .district, code: location.countryCode)
        ].compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var unique: [String] = []
        for value in values where !unique.contains(value) {
            unique.append(value)
        }
        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }

    private static func parseIPv4(_ address: String) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 4)
        let result = address.withCString { pointer in
            bytes.withUnsafeMutableBufferPointer { buffer in
                inet_pton(AF_INET, pointer, buffer.baseAddress)
            }
        }
        return result == 1 ? bytes : nil
    }

    private static func parseIPv6(_ address: String) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let result = address.withCString { pointer in
            bytes.withUnsafeMutableBufferPointer { buffer in
                inet_pton(AF_INET6, pointer, buffer.baseAddress)
            }
        }
        return result == 1 ? bytes : nil
    }

    private static func classifyIPv4(_ bytes: [UInt8]) -> Network_IPAddressKind {
        let first = bytes[0]
        let second = bytes[1]
        if first == 127 { return .loopback }
        if first == 169 && second == 254 { return .linkLocal }
        if first == 10 || (first == 172 && (16...31).contains(second)) || (first == 192 && second == 168) {
            return .privateAddress
        }
        if first == 0 || first >= 224 || (first == 100 && (64...127).contains(second)) {
            return .privateAddress
        }
        return .publicAddress
    }

    private static func classifyIPv6(_ bytes: [UInt8]) -> Network_IPAddressKind {
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return .loopback }
        if bytes.allSatisfy({ $0 == 0 }) { return .privateAddress }
        if bytes[0] == 0xff { return .privateAddress }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return .linkLocal }
        if (bytes[0] & 0xfe) == 0xfc { return .privateAddress }
        if bytes.starts(with: [0x20, 0x01, 0x0d, 0xb8]) { return .privateAddress }

        // IPv4-mapped IPv6 addresses inherit the IPv4 classification.
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return classifyIPv4(Array(bytes[12..<16]))
        }
        return .publicAddress
    }

    private static func localizedCountry(_ value: String?, code: String?) -> String? {
        let names: [String: String] = [
            "CN": "中国", "HK": "中国香港", "MO": "中国澳门", "TW": "中国台湾",
            "US": "美国", "JP": "日本", "KR": "韩国", "SG": "新加坡", "GB": "英国",
            "DE": "德国", "FR": "法国", "CA": "加拿大", "AU": "澳大利亚", "RU": "俄罗斯"
        ]
        if let code, let name = names[code.uppercased()] { return name }
        return value
    }

    private enum ChinaNameKind { case region, city, district }

    private static func normalizedChinaName(_ value: String?, kind: ChinaNameKind, code: String?) -> String? {
        guard let value else { return nil }
        guard code?.uppercased() == "CN", !containsCJK(value) else { return value }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " Province", with: "")
            .replacingOccurrences(of: " Municipality", with: "")
            .lowercased()
        let names: [String: String] = [
            "chongqing": "重庆市", "beijing": "北京市", "shanghai": "上海市", "tianjin": "天津市",
            "guangdong": "广东省", "sichuan": "四川省", "zhejiang": "浙江省", "jiangsu": "江苏省",
            "hubei": "湖北省", "hunan": "湖南省", "fujian": "福建省", "shandong": "山东省",
            "henan": "河南省", "hebei": "河北省", "anhui": "安徽省", "jiangxi": "江西省",
            "shaanxi": "陕西省", "yunnan": "云南省", "guangxi": "广西", "liaoning": "辽宁省",
            "jilin": "吉林省", "heilongjiang": "黑龙江省", "hainan": "海南省", "gansu": "甘肃省",
            "qinghai": "青海省", "xinjiang": "新疆", "tibet": "西藏", "inner mongolia": "内蒙古",
            "ningxia": "宁夏", "hong kong": "中国香港", "macau": "中国澳门", "taiwan": "中国台湾",
            "jiangbei": "江北区"
        ]
        if let localized = names[key] {
            if kind == .city && localized.hasSuffix("省") { return localized.replacingOccurrences(of: "省", with: "市") }
            return localized
        }
        return value
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}

internal final class IPGeolocationReader {
    typealias Completion = (Result<Network_IPLocation?, Error>) -> Void

    private struct CacheEntry {
        let location: Network_IPLocation?
        let expiresAt: Date
    }

    private let session: URLSession
    private let stateQueue = DispatchQueue(label: "eu.exelban.NetworkIPGeolocation")
    private var cache: [String: CacheEntry] = [:]
    private var tasks: [String: URLSessionDataTask] = [:]
    private var completions: [String: [Completion]] = [:]
    private let cacheTTL: TimeInterval = 7 * 24 * 60 * 60
    private let maxCacheEntries = 64

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        self.cancelAll()
        self.session.invalidateAndCancel()
    }

    func lookup(_ ip: String, completion: @escaping Completion) {
        guard IPGeolocationCore.classify(ip) == .publicAddress else {
            completion(.success(nil))
            return
        }

        self.stateQueue.async { [weak self] in
            guard let self else { return }
            if let cached = self.cache[ip], cached.expiresAt > Date() {
                completion(.success(cached.location))
                return
            }
            self.cache.removeValue(forKey: ip)
            self.completions[ip, default: []].append(completion)
            guard self.tasks[ip] == nil else { return }

            guard let url = URL(string: "https://ipwho.is/\(ip)") else {
                self.finish(ip: ip, result: .failure(URLError(.badURL)))
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 5
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let task = self.session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                if let error {
                    self.finish(ip: ip, result: .failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    self.finish(ip: ip, result: .failure(URLError(.badServerResponse)))
                    return
                }
                guard let data else {
                    self.finish(ip: ip, result: .failure(URLError(.zeroByteResource)))
                    return
                }
                guard let location = IPGeolocationCore.decode(data) else {
                    self.finish(ip: ip, result: .success(nil))
                    return
                }
                self.finish(ip: ip, result: .success(location))
            }
            self.tasks[ip] = task
            task.resume()
        }
    }

    func cancelAll() {
        self.stateQueue.sync {
            self.tasks.values.forEach { $0.cancel() }
            self.tasks.removeAll()
            self.completions.removeAll()
        }
    }

    private func finish(ip: String, result: Result<Network_IPLocation?, Error>) {
        self.stateQueue.async {
            self.tasks.removeValue(forKey: ip)
            if case let .success(location) = result {
                // Cache an explicit "no location" response as well. This keeps
                // an IP with missing/unknown metadata from being queried on
                // every refresh while still retrying transport/HTTP failures.
                self.cache[ip] = CacheEntry(location: location, expiresAt: Date().addingTimeInterval(self.cacheTTL))
                if self.cache.count > self.maxCacheEntries {
                    let oldest = self.cache.min { $0.value.expiresAt < $1.value.expiresAt }?.key
                    if let oldest { self.cache.removeValue(forKey: oldest) }
                }
            }
            let callbacks = self.completions.removeValue(forKey: ip) ?? []
            callbacks.forEach { $0(result) }
        }
    }
}
