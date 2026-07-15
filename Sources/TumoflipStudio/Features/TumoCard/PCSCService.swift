import CPCSCBridge
import Foundation
import TumoCardCore

struct PCSCCardConnection: Sendable {
    let readerName: String
    let protocolName: String
    let atr: Data
}

enum PCSCServiceError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case noReader
    case noCard
    case cardRemoved
    case communication(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .communication(message): message
        case .noReader: "NFC CCID Bridge is not connected"
        case .noCard: "No ISO 14443-4 card is present"
        case .cardRemoved: "The card was removed"
        }
    }
}

private final class PCSCSessionHandle: @unchecked Sendable {
    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    deinit {
        tc_pcsc_session_destroy(rawValue)
    }
}

actor PCSCService {
    private var sessionHandle: PCSCSessionHandle?
    private var connectedReader: String?

    func listReaders() throws -> [String] {
        let session = try ensureSession()
        var buffer = [CChar](repeating: 0, count: 4096)
        var length = UInt32(buffer.count)
        let code = tc_pcsc_list_readers(session, &buffer, &length)
        if tc_pcsc_is_no_reader(code) { throw PCSCServiceError.noReader }
        try check(code)

        var readers: [String] = []
        var start = 0
        let usableLength = min(Int(length), buffer.count)
        while start < usableLength, buffer[start] != 0 {
            let end = buffer[start...].firstIndex(of: 0) ?? usableLength
            let bytes = buffer[start..<end].map { UInt8(bitPattern: $0) }
            if let reader = String(bytes: bytes, encoding: .utf8), !reader.isEmpty {
                readers.append(reader)
            }
            start = end + 1
        }
        return readers
    }

    func refreshConnection(reader: String) throws -> PCSCCardConnection {
        let session = try ensureSession()
        var info = TCPCSCConnectionInfo()
        let code: Int32
        if connectedReader == reader {
            code = tc_pcsc_status(session, &info)
        } else {
            tc_pcsc_disconnect(session)
            connectedReader = nil
            code = reader.withCString { tc_pcsc_connect(session, $0, &info) }
            if tc_pcsc_is_success(code) { connectedReader = reader }
        }

        if tc_pcsc_is_no_card(code) {
            tc_pcsc_disconnect(session)
            connectedReader = nil
            throw PCSCServiceError.noCard
        }
        if tc_pcsc_is_card_removed(code) {
            tc_pcsc_disconnect(session)
            connectedReader = nil
            throw PCSCServiceError.cardRemoved
        }
        try check(code)
        return connection(from: info, reader: reader)
    }

    func transmit(_ command: APDUCommand) throws -> APDUResponse {
        guard let session = sessionHandle?.rawValue, connectedReader != nil else {
            throw PCSCServiceError.noCard
        }
        var response = [UInt8](repeating: 0, count: 4096)
        var responseLength = UInt32(response.count)
        let commandBytes = [UInt8](command.bytes)
        let code = commandBytes.withUnsafeBufferPointer { commandBuffer in
            response.withUnsafeMutableBufferPointer { responseBuffer in
                tc_pcsc_transmit(
                    session,
                    commandBuffer.baseAddress,
                    UInt32(commandBuffer.count),
                    responseBuffer.baseAddress,
                    &responseLength
                )
            }
        }
        if tc_pcsc_is_card_removed(code) {
            tc_pcsc_disconnect(session)
            connectedReader = nil
            throw PCSCServiceError.cardRemoved
        }
        try check(code)
        return try APDUResponse(raw: Data(response.prefix(Int(responseLength))))
    }

    func disconnect() {
        guard let session = sessionHandle?.rawValue else { return }
        tc_pcsc_disconnect(session)
        connectedReader = nil
    }

    private func ensureSession() throws -> OpaquePointer {
        if let sessionHandle { return sessionHandle.rawValue }
        var code: Int32 = 0
        guard let created = tc_pcsc_session_create(&code) else {
            throw PCSCServiceError.unavailable(errorDescription(for: code))
        }
        sessionHandle = PCSCSessionHandle(rawValue: created)
        return created
    }

    private func connection(
        from info: TCPCSCConnectionInfo,
        reader: String
    ) -> PCSCCardConnection {
        var mutableInfo = info
        let atr = withUnsafeBytes(of: &mutableInfo.atr) { bytes in
            Data(bytes.prefix(min(Int(info.atr_length), bytes.count)))
        }
        let protocolName: String
        switch info.active_protocol {
        case 1: protocolName = "T=0"
        case 2: protocolName = "T=1"
        default: protocolName = "Unknown"
        }
        return PCSCCardConnection(readerName: reader, protocolName: protocolName, atr: atr)
    }

    private func check(_ code: Int32) throws {
        guard tc_pcsc_is_success(code) else {
            throw PCSCServiceError.communication(errorDescription(for: code))
        }
    }

    private func errorDescription(for code: Int32) -> String {
        String(cString: tc_pcsc_error_description(code))
    }
}
