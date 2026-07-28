//
//  Kit.swift
//  Tests
//
//  Created by Serhiy Mytrovtsiy on 04/07/2026.
//  Using Swift 6.0.
//  Running on macOS 26.5.
//
//  Copyright © 2026 Serhiy Mytrovtsiy. All rights reserved.
//

import XCTest
import Kit
import Quota

class KitTests: XCTestCase {
    func testIsNewestVersion_release() throws {
        XCTAssertFalse(isNewestVersion(currentVersion: "v2.11.0", latestVersion: "v2.11.0"))
        XCTAssertTrue(isNewestVersion(currentVersion: "v2.11.0", latestVersion: "v2.11.1"))
        XCTAssertFalse(isNewestVersion(currentVersion: "v2.11.1", latestVersion: "v2.11.0"))
        XCTAssertTrue(isNewestVersion(currentVersion: "v2.11.0", latestVersion: "v2.12.0"))
        XCTAssertFalse(isNewestVersion(currentVersion: "v2.12.0", latestVersion: "v2.11.5"))
        XCTAssertTrue(isNewestVersion(currentVersion: "v2.11.0", latestVersion: "v3.0.0"))
        XCTAssertFalse(isNewestVersion(currentVersion: "v3.0.0", latestVersion: "v2.99.99"))
    }
    
    func testIsNewestVersion_beta() throws {
        XCTAssertFalse(isNewestVersion(currentVersion: "v2.11.0-beta1", latestVersion: "v2.11.0-beta1"))
        XCTAssertFalse(isNewestVersion(currentVersion: "v2.11.0-beta2", latestVersion: "v2.11.0-beta1"))
        XCTAssertTrue(isNewestVersion(currentVersion: "v2.11.0-beta1", latestVersion: "v2.11.0-beta2"))
        XCTAssertTrue(isNewestVersion(currentVersion: "v2.11.0-beta1", latestVersion: "v2.11.0"))
        XCTAssertFalse(isNewestVersion(currentVersion: "v2.11.0-beta1", latestVersion: "v2.10.9"))
        XCTAssertFalse(isNewestVersion(currentVersion: "v2.11.0", latestVersion: "v2.11.1-beta1"))
        XCTAssertTrue(isNewestVersion(currentVersion: "v2.11.0-beta1", latestVersion: "v2.11.1-beta1"))
    }
    
    func testIsNewestVersion_malformed() throws {
        XCTAssertFalse(isNewestVersion(currentVersion: "v3", latestVersion: "v3.0.0"))
        XCTAssertTrue(isNewestVersion(currentVersion: "v3", latestVersion: "v3.0.1"))
        XCTAssertFalse(isNewestVersion(currentVersion: "v3.0", latestVersion: "v3.0.0"))
        XCTAssertFalse(isNewestVersion(currentVersion: "", latestVersion: ""))
    }
    
    func testUnitsGetReadableSpeed_byte() throws {
        XCTAssertEqual(Units(bytes: 0).getReadableSpeed(base: .byte), "0 KB/s")
        XCTAssertEqual(Units(bytes: 999).getReadableSpeed(base: .byte), "0 KB/s")
        XCTAssertEqual(Units(bytes: 1_000).getReadableSpeed(base: .byte), "1 KB/s")
        XCTAssertEqual(Units(bytes: 500_000).getReadableSpeed(base: .byte), "500 KB/s")
        XCTAssertEqual(Units(bytes: 2_500_000).getReadableSpeed(base: .byte), "2.5 MB/s")
        XCTAssertEqual(Units(bytes: 150_000_000).getReadableSpeed(base: .byte), "150 MB/s")
        XCTAssertEqual(Units(bytes: 2_000_000_000).getReadableSpeed(base: .byte), "2.0 GB/s")
        XCTAssertEqual(Units(bytes: 2_000_000_000_000).getReadableSpeed(base: .byte), "2.0 TB/s")
        XCTAssertEqual(Units(bytes: -5).getReadableSpeed(base: .byte), "0 KB/s")
    }
    
    func testUnitsGetReadableSpeed_bit() throws {
        XCTAssertEqual(Units(bytes: 100).getReadableSpeed(base: .bit), "0 Kb/s")
        XCTAssertEqual(Units(bytes: 50_000).getReadableSpeed(base: .bit), "400 Kb/s")
        XCTAssertEqual(Units(bytes: 500_000).getReadableSpeed(base: .bit), "4.0 Mb/s")
        XCTAssertEqual(Units(bytes: 200_000_000).getReadableSpeed(base: .bit), "1.6 Gb/s")
        XCTAssertEqual(Units(bytes: 200_000_000_000).getReadableSpeed(base: .bit), "1.6 Tb/s")
    }
    
    func testUnitsGetReadableSpeed_fixedUnit() throws {
        XCTAssertEqual(Units(bytes: 500_000).getReadableSpeed(base: .byte, unit: "KB"), "500 KB/s")
        XCTAssertEqual(Units(bytes: 500_000).getReadableSpeed(base: .byte, unit: "MB"), "0.5 MB/s")
        XCTAssertEqual(Units(bytes: 500_000).getReadableSpeed(base: .bit, unit: "MB"), "4 Mb/s")
    }

    func testQuotaCountdownText() throws {
        let now = Date(timeIntervalSince1970: 1_720_000_000)

        XCTAssertEqual(QuotaCountdownFormatter.text(until: now.addingTimeInterval(4 * 60 + 59), now: now), "4分")
        XCTAssertEqual(QuotaCountdownFormatter.text(until: now.addingTimeInterval(59), now: now), "不足1分")
        XCTAssertEqual(QuotaCountdownFormatter.text(until: now.addingTimeInterval(2 * 3600), now: now), "2时")
        XCTAssertEqual(QuotaCountdownFormatter.text(until: now.addingTimeInterval(2 * 3600 + 3 * 60), now: now), "2时 3分")
        XCTAssertEqual(QuotaCountdownFormatter.text(until: now.addingTimeInterval(3 * 86_400), now: now), "3天")
        XCTAssertEqual(QuotaCountdownFormatter.text(until: now.addingTimeInterval(3 * 86_400 + 3600), now: now), "3天 1时")
        XCTAssertEqual(QuotaCountdownFormatter.text(until: now, now: now), "即将重置")
        XCTAssertNil(QuotaCountdownFormatter.text(until: nil, now: now))
    }

    func testQuotaCountdownParsesISO8601ResetTime() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = Calendar(identifier: .gregorian)

        let wholeSecond = try XCTUnwrap(QuotaCountdownFormatter.date(fromISO8601: "2026-07-27T16:30:00Z"))
        let wholeSecondParts = calendar.dateComponents(in: timeZone, from: wholeSecond)
        XCTAssertEqual(wholeSecondParts.year, 2026)
        XCTAssertEqual(wholeSecondParts.month, 7)
        XCTAssertEqual(wholeSecondParts.day, 27)
        XCTAssertEqual(wholeSecondParts.hour, 16)
        XCTAssertEqual(wholeSecondParts.minute, 30)

        XCTAssertNotNil(QuotaCountdownFormatter.date(fromISO8601: "2026-07-27T16:30:00.125Z"))
        XCTAssertNil(QuotaCountdownFormatter.date(fromISO8601: "not-a-date"))
    }

    func testQuotaSnapshotsDecodeWithoutCountdownDeadlines() throws {
        let decoder = JSONDecoder()
        XCTAssertNoThrow(try decoder.decode(KimiQuota.self, from: Data("{}".utf8)))
        XCTAssertNoThrow(try decoder.decode(
            CodexWindow.self,
            from: Data("{\"name\":\"weekly\",\"utilization\":50}".utf8)
        ))
    }
}
