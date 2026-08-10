import Foundation
import XCTest
@testable import TumoflipDeviceKit

final class DeviceKitTests: XCTestCase {
    func testDelimitedDecoderHandlesFragmentedAndAdjacentFrames() throws {
        let first = Data([0x01, 0x02, 0x03])
        let second = Data(repeating: 0xaa, count: 300)
        let encoded = DelimitedProtobufDecoder.encode(first)
            + DelimitedProtobufDecoder.encode(second)

        var decoder = DelimitedProtobufDecoder()
        XCTAssertEqual(try decoder.append(encoded.prefix(2)), [])
        let frames = try decoder.append(encoded.dropFirst(2))
        XCTAssertEqual(frames, [first, second])
    }

    func testDelimitedDecoderRejectsOversizedFrameBeforeBufferingPayload() throws {
        var decoder = DelimitedProtobufDecoder(maximumFrameSize: 16)
        XCTAssertThrowsError(try decoder.append(DelimitedProtobufDecoder.encodeVarint(17))) {
            XCTAssertEqual($0 as? RPCFramingError, .frameTooLarge(17))
        }
    }

    func testUSBDiscoveryOnlyReturnsFlipperCalloutPorts() {
        let devices = USBDeviceDiscovery.flipperDevices(in: [
            "/dev/cu.Bluetooth-Incoming-Port",
            "/dev/cu.usbserial-0001",
            "/dev/tty.usbmodemflip_ABC",
            "/dev/cu.usbmodemflip_DEF",
            "/dev/cu.usbmodem1234",
        ])

        XCTAssertEqual(devices.map(\.path), ["/dev/cu.usbmodemflip_DEF"])
    }

    func testFlipperPathsNormalizeAndRejectTraversal() throws {
        XCTAssertEqual(try FlipperPath.normalize("//ext//apps/"), "/ext/apps")
        XCTAssertEqual(try FlipperPath.join(directory: "/ext/apps", name: "Tools"), "/ext/apps/Tools")
        XCTAssertEqual(try FlipperPath.parent(of: "/ext/apps/Tools"), "/ext/apps")
        XCTAssertThrowsError(try FlipperPath.normalize("/ext/../int"))
        XCTAssertThrowsError(try FlipperPath.join(directory: "/ext", name: "../int"))
    }

    func testFileSortingKeepsDirectoriesFirstAndUsesNaturalOrder() {
        let entries = [
            FlipperFileEntry(name: "file10", path: "/ext/file10", isDirectory: false, size: 10),
            FlipperFileEntry(name: "Folder", path: "/ext/Folder", isDirectory: true, size: 0),
            FlipperFileEntry(name: "file2", path: "/ext/file2", isDirectory: false, size: 2),
        ]

        XCTAssertEqual(FlipperDeviceService.sorted(entries).map(\.name), ["Folder", "file2", "file10"])
    }

    func testRPCSessionCollectsStreamingResponsesByCommandID() async throws {
        let transport = MockTransport()
        let session = FlipperRPCSession(transport: transport)
        try await session.start()

        let command = Task {
            try await session.command(timeout: 2) { main in
                main.content = .systemDeviceInfoRequest(PBSystem_DeviceInfoRequest())
            }
        }

        let request = try await transport.waitForRequest()
        var first = PB_Main()
        first.commandID = request.commandID
        first.hasNext_p = true
        var firstProperty = PBSystem_DeviceInfoResponse()
        firstProperty.key = "firmware_version"
        firstProperty.value = "t-dev-004-014"
        first.content = .systemDeviceInfoResponse(firstProperty)

        var second = PB_Main()
        second.commandID = request.commandID
        var secondProperty = PBSystem_DeviceInfoResponse()
        secondProperty.key = "firmware_commit"
        secondProperty.value = "12345678"
        second.content = .systemDeviceInfoResponse(secondProperty)

        try transport.deliver(first)
        try transport.deliver(second)

        let responses = try await command.value
        XCTAssertEqual(responses.count, 2)
        await session.stop()
    }
}

private final class MockTransport: FlipperTransport, @unchecked Sendable {
    let incomingBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var sent: [Data] = []

    init() {
        let stream = AsyncStream<Data>.makeStream()
        incomingBytes = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws {}

    func disconnect() async {
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        lock.lock()
        sent.append(data)
        lock.unlock()
    }

    func waitForRequest() async throws -> PB_Main {
        for _ in 0..<200 {
            let data = firstSentFrame()
            if let data {
                var decoder = DelimitedProtobufDecoder()
                guard let payload = try decoder.append(data).first else {
                    throw FlipperRPCError.invalidResponse
                }
                return try PB_Main(serializedBytes: payload)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw FlipperRPCError.timedOut
    }

    func deliver(_ message: PB_Main) throws {
        continuation.yield(DelimitedProtobufDecoder.encode(try message.serializedData()))
    }

    private func firstSentFrame() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return sent.first
    }
}
