import Foundation

@main
struct ProxyTrafficParserTests {
    static func main() {
        testBitrateAcceptsRealVnstatOutput()
        testBitrateAcceptsColonOutput()
        testBitrateSupportsAllCommonUnits()
        testPeriodTotalsUseLatestMonthAndDayEntries()
        testPeriodTotalsRejectMissingPeriod()
        testPollGatePreventsOutOfOrderOverlap()
        testRateUsesActualElapsedTime()
        testVPSAggregateTotals()
        print("PROXY_TRAFFIC_PARSER_TESTS_OK")
    }

    static func testBitrateAcceptsRealVnstatOutput() {
        let output = """
        Sampling ens17 (2 seconds average)...414 packets sampled in 2 seconds
        Traffic average for ens17

         rx 703.80 kbit/s 109 packets/s
         tx 719.96 kbit/s 98 packets/s
        """
        expectEqual(ProxyRemoteTrafficParser.parseBitrate(output, prefix: "rx:"), 703.80, "real vnstat rx")
        expectEqual(ProxyRemoteTrafficParser.parseBitrate(output, prefix: "tx:"), 719.96, "real vnstat tx")
    }

    static func testBitrateAcceptsColonOutput() {
        let output = "rx: 1.25 Mbit/s\ntx: 2.5 Gbit/s"
        expectEqual(ProxyRemoteTrafficParser.parseBitrate(output, prefix: "rx:"), 1250, "colon rx")
        expectEqual(ProxyRemoteTrafficParser.parseBitrate(output, prefix: "tx:"), 2_500_000, "colon tx")
    }

    static func testBitrateSupportsAllCommonUnits() {
        let output = "rx 800 bit/s\ntx 2.5 MB/s"
        expectEqual(ProxyRemoteTrafficParser.parseBitrate(output, prefix: "rx:"), 0.8, "bit/s")
        expectEqual(ProxyRemoteTrafficParser.parseBitrate(output, prefix: "tx:"), 20_000, "MB/s")
    }

    static func testPeriodTotalsUseLatestMonthAndDayEntries() {
        let month = """
        {"interfaces":[{"traffic":{"total":{"rx":9999,"tx":9999},"month":[
          {"date":{"year":2026,"month":7},"timestamp":100,"rx":100,"tx":200},
          {"date":{"year":2026,"month":8},"timestamp":200,"rx":1234,"tx":2345}
        ]}}]}
        """
        let day = """
        {"interfaces":[{"traffic":{"total":{"rx":9999,"tx":9999},"day":[
          {"date":{"year":2026,"month":8,"day":1},"timestamp":100,"rx":10,"tx":20},
          {"date":{"year":2026,"month":8,"day":2},"timestamp":200,"rx":321,"tx":654}
        ]}}]}
        """
        let totals = ProxyRemoteTrafficParser.parseTotals(monthJSON: month, dayJSON: day)
        expectEqual(totals, ProxyRemoteTrafficTotals(monthRx: 1234, monthTx: 2345, dayRx: 321, dayTx: 654), "period totals")
    }

    static func testPeriodTotalsRejectMissingPeriod() {
        let json = "{\"interfaces\":[{\"traffic\":{\"total\":{\"rx\":999,\"tx\":999},\"month\":[]}}]}"
        let totals = ProxyRemoteTrafficParser.parseTotals(monthJSON: json, dayJSON: json)
        expect(totals == nil, "missing period must not become zero or all-time")
    }

    static func testPollGatePreventsOutOfOrderOverlap() {
        var gate = ProxyTrafficPollGate()
        expect(gate.begin(), "first poll should begin")
        expect(!gate.begin(), "second poll must be rejected while first is in flight")
        gate.finish()
        expect(gate.begin(), "poll should begin again after completion")
    }

    static func testRateUsesActualElapsedTime() {
        expectEqual(ProxyTrafficRate.perSecond(delta: 1_000, elapsed: 4), 250, "rate elapsed time")
        expectEqual(ProxyTrafficRate.perSecond(delta: 1_000, elapsed: 0), 1_000, "rate zero elapsed guard")
    }

    static func testVPSAggregateTotals() {
        let totals = ProxyRemoteTrafficTotals(monthRx: 300, monthTx: 700, dayRx: 30, dayTx: 70)
        expectEqual(totals.monthTotal, 1_000, "monthly VPS total")
        expectEqual(totals.dayTotal, 100, "daily VPS total")
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
        guard actual == expected else {
            fatalError("\(name): expected \(expected), got \(actual)")
        }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
