import Foundation
import XCTest
@testable import TumoCardCore

final class ReportTests: XCTestCase {
    func testReportOmitsRawPayloadsAndCardholderData() throws {
        let command = try APDUCommand.select(
            aid: Data(hex: "A0000000041010")!,
            name: "Select Mastercard"
        )
        let response = try APDUResponse(raw: Data(hex: "5A0812345678901234569000")!)
        let snapshot = CardSnapshot(
            readerName: "Generic USB Smart Card Reader",
            protocolName: "T=1",
            atr: "3B00",
            uid: "04AABBCCDDEE",
            applications: []
        )
        let report = TumoCardReport(
            card: snapshot,
            events: [
                APDUEvent(
                    command: command,
                    response: response,
                    transportError: nil,
                    durationMilliseconds: 12
                )
            ]
        )
        let json = String(decoding: try report.jsonData(), as: UTF8.self)
        XCTAssertFalse(json.contains("1234567890123456"))
        XCTAssertFalse(json.contains("5A081234567890123456"))
        XCTAssertFalse(json.contains("04AABBCCDDEE"))
        XCTAssertTrue(json.contains("uidFingerprint"))
        XCTAssertTrue(json.contains("responseDigest"))
        XCTAssertTrue(json.contains("9000"))
    }
}
