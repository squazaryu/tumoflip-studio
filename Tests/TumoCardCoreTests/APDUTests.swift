import Foundation
import XCTest
@testable import TumoCardCore

final class APDUTests: XCTestCase {
    func testReadOnlyPolicyAllowsSelectAndReadCommands() throws {
        _ = try APDUCommand(name: "Select", bytes: Data(hex: "00A4040007D276000085010100")!)
        _ = try APDUCommand(name: "Read", bytes: Data(hex: "00B0000010")!)
        _ = try APDUCommand.getUID()
    }

    func testReadOnlyPolicyRejectsStateChangingCommands() {
        XCTAssertThrowsError(
            try APDUCommand(name: "Update", bytes: Data(hex: "00D6000001FF")!)
        ) { error in
            XCTAssertEqual(error as? APDUValidationError, .stateChangingInstruction(0xD6))
        }
        XCTAssertThrowsError(
            try APDUCommand(name: "Generate AC", bytes: Data(hex: "80AE800000")!)
        ) { error in
            XCTAssertEqual(error as? APDUValidationError, .stateChangingInstruction(0xAE))
        }
    }

    func testResponseSeparatesPayloadAndStatusWord() throws {
        let response = try APDUResponse(raw: Data(hex: "6F038401019000")!)
        XCTAssertEqual(response.payload, Data(hex: "6F03840101")!)
        XCTAssertEqual(response.statusWord, 0x9000)
        XCTAssertTrue(response.succeeded)
    }
}
