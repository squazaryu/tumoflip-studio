import Foundation
import XCTest
@testable import TumoCardCore

final class DecoderTests: XCTestCase {
    func testEMVDecoderReturnsOnlyPublicFCIFields() throws {
        let application = CardApplication(
            aid: "A0000000041010",
            name: "Mastercard",
            source: "PPSE"
        )
        let response = try APDUResponse(
            raw: Data(hex: "6F1C8407A0000000041010A511500A4D6173746572636172645F2D02656E9000")!
        )
        let metadata = EMVFCIDecoder().decode(application: application, response: response)
        XCTAssertTrue(metadata.contains { $0.label == "Label" && $0.value == "Mastercard" })
        XCTAssertTrue(metadata.contains { $0.label == "Languages" && $0.value == "en" })
        XCTAssertFalse(metadata.contains { $0.label.localizedCaseInsensitiveContains("PAN") })
    }

    func testParsesType4CapabilityContainer() throws {
        let cc = try NDEFType4CapabilityContainer.parse(
            Data(hex: "000F20003B00340406E10400FF00FF")!
        )
        XCTAssertEqual(cc.ndefFileID, 0xE104)
        XCTAssertEqual(cc.maximumNDEFSize, 255)
        XCTAssertEqual(cc.readAccess, 0)
    }

    func testNDEFSummaryDoesNotExposeURIContent() throws {
        let message = Data(hex: "D1010C55046578616D706C652E636F6D")!
        let records = try NDEFMessageParser.summaries(from: message)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].type, "URI")
        XCTAssertEqual(records[0].uriScheme, "https://")
        XCTAssertFalse(records[0].metadata.contains { $0.value.contains("example.com") })
    }
}
