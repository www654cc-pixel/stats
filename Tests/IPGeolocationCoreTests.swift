import Foundation

@main
struct IPGeolocationCoreTests {
    static func main() {
        expect(IPGeolocationCore.classify("192.168.1.10") == .privateAddress, "private IPv4")
        expect(IPGeolocationCore.classify("127.0.0.1") == .loopback, "loopback IPv4")
        expect(IPGeolocationCore.classify("169.254.10.20") == .linkLocal, "link-local IPv4")
        expect(IPGeolocationCore.classify("10.0.0.1") == .privateAddress, "RFC1918 IPv4")
        expect(IPGeolocationCore.classify("8.8.8.8") == .publicAddress, "public IPv4")
        expect(IPGeolocationCore.classify("::1") == .loopback, "loopback IPv6")
        expect(IPGeolocationCore.classify("fe80::1") == .linkLocal, "link-local IPv6")
        expect(IPGeolocationCore.classify("fd00::1") == .privateAddress, "unique-local IPv6")
        expect(IPGeolocationCore.classify("2001:4860:4860::8888") == .publicAddress, "public IPv6")
        expect(IPGeolocationCore.classify("::ffff:8.8.8.8") == .publicAddress, "mapped public IPv4")
        expect(IPGeolocationCore.classify("::ffff:192.168.1.10") == .privateAddress, "mapped private IPv4")
        expect(IPGeolocationCore.classify("not-an-ip") == .invalid, "invalid address")

        testIPWhoResponseParsing()
        testLocationSummaryIsCompactAndDeduplicated()
        testChineseLocationNormalization()
        testUnknownLocationDoesNotInventText()
        testUnsuccessfulIPWhoResponseIsIgnored()
        print("IP_GEOLOCATION_CORE_TESTS_OK")
    }

    static func testIPWhoResponseParsing() {
        let json = """
        {"success":true,"country":"China","country_code":"CN","region":"Chongqing","city":"Chongqing","postal":"400000"}
        """
        let location = IPGeolocationCore.decode(Data(json.utf8))
        expect(location?.countryCode == "CN", "country code parsed")
        expect(location?.region == "Chongqing", "region parsed")
        expect(location?.city == "Chongqing", "city parsed")
    }

    static func testLocationSummaryIsCompactAndDeduplicated() {
        let location = Network_IPLocation(country: "United States", countryCode: "US", region: "California", city: "Mountain View", district: nil)
        expectEqual(IPGeolocationCore.summary(location), "美国 · California · Mountain View", "compact location summary")
    }

    static func testChineseLocationNormalization() {
        let location = Network_IPLocation(country: "China", countryCode: "CN", region: "Chongqing", city: "Chongqing", district: "Jiangbei")
        expectEqual(IPGeolocationCore.summary(location), "中国 · 重庆市 · 江北区", "Chinese location summary")
    }

    static func testUnknownLocationDoesNotInventText() {
        let location = Network_IPLocation(country: nil, countryCode: nil, region: nil, city: nil, district: nil)
        expect(IPGeolocationCore.summary(location) == nil, "unknown location must remain unknown")
    }

    static func testUnsuccessfulIPWhoResponseIsIgnored() {
        let location = IPGeolocationCore.decode(Data("{\"success\":false,\"country\":\"China\"}".utf8))
        expect(location == nil, "unsuccessful response must be ignored")
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
        guard actual == expected else { fatalError("\(name): expected \(expected), got \(actual)") }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
