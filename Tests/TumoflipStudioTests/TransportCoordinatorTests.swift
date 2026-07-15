import XCTest
@testable import TumoflipStudio

@MainActor
final class TransportCoordinatorTests: XCTestCase {
    func testWiredTransportsAreExclusiveAcrossOwners() {
        let log = ActivityLogStore()
        let coordinator = TransportCoordinator(log: log)

        XCTAssertTrue(coordinator.acquire(.pcsc, owner: "TumoCard"))
        XCTAssertFalse(coordinator.acquire(.serial, owner: "Network Lab"))
        XCTAssertEqual(coordinator.leases[.pcsc]?.owner, "TumoCard")
        XCTAssertNotNil(coordinator.lastConflict)
    }

    func testOwnerCanReacquireAndReleaseTransport() {
        let log = ActivityLogStore()
        let coordinator = TransportCoordinator(log: log)

        XCTAssertTrue(coordinator.acquire(.serial, owner: "Network Lab"))
        XCTAssertTrue(coordinator.acquire(.serial, owner: "Network Lab"))
        coordinator.release(.serial, owner: "Network Lab")

        XCTAssertNil(coordinator.leases[.serial])
    }

    func testBackgroundTransportsDoNotBlockWiredTransport() {
        let log = ActivityLogStore()
        let coordinator = TransportCoordinator(log: log)

        XCTAssertTrue(coordinator.acquire(.bluetooth, owner: "AI Relay"))
        XCTAssertTrue(coordinator.acquire(.localHTTP, owner: "AI Relay"))
        XCTAssertTrue(coordinator.acquire(.flipperUSB, owner: "FAP Builder"))
    }

    func testAppBridgeFrameRoundTrip() throws {
        let payload = Data("payload".utf8)
        let encoded = try XCTUnwrap(AppBridgeFrame.encode(appId: "relay", command: "ping", payload: payload))
        let decoded = try XCTUnwrap(AppBridgeFrame.decode(encoded))

        XCTAssertEqual(decoded.appId, "relay")
        XCTAssertEqual(decoded.command, "ping")
        XCTAssertEqual(decoded.payload, payload)
    }
}
