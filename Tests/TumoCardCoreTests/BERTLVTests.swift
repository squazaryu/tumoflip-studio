import Foundation
import XCTest
@testable import TumoCardCore

final class BERTLVTests: XCTestCase {
    func testParsesNestedPaymentDirectory() throws {
        let data = Data(hex: "61154F07A0000000041010500A4D617374657263617264")!
        let nodes = try BERTLVParser.parse(data)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(
            nodes[0].descendants(withTag: 0x4F).first?.value,
            Data(hex: "A0000000041010")!
        )

        let response = try APDUResponse(raw: data + Data([0x90, 0x00]))
        let applications = CardApplicationParser.applications(from: response)
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(applications[0].name, "Mastercard")
        XCTAssertEqual(applications[0].aid, "A0000000041010")
    }

    func testRejectsOutOfBoundsValueLength() {
        XCTAssertThrowsError(try BERTLVParser.parse(Data(hex: "5A08DEADBEEF")!)) { error in
            XCTAssertEqual(error as? BERTLVError, .valueOutOfBounds)
        }
    }
}
