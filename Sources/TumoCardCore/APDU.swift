import Foundation

public enum APDUValidationError: Error, Equatable, LocalizedError {
    case tooShort
    case tooLong
    case malformedLength
    case stateChangingInstruction(UInt8)

    public var errorDescription: String? {
        switch self {
        case .tooShort:
            "APDU must contain at least CLA, INS, P1 and P2"
        case .tooLong:
            "APDU exceeds the product safety limit"
        case .malformedLength:
            "APDU length fields are inconsistent"
        case let .stateChangingInstruction(instruction):
            String(format: "Instruction %02X is not allowed in read-only mode", instruction)
        }
    }
}

public struct APDUCommand: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let bytes: Data

    public init(id: UUID = UUID(), name: String, bytes: Data) throws {
        try Self.validateReadOnly(bytes)
        self.id = id
        self.name = name
        self.bytes = bytes
    }

    public var cla: UInt8 { bytes[bytes.startIndex] }
    public var instruction: UInt8 { bytes[bytes.startIndex + 1] }
    public var p1: UInt8 { bytes[bytes.startIndex + 2] }
    public var p2: UInt8 { bytes[bytes.startIndex + 3] }

    public static func select(aid: Data, name: String) throws -> APDUCommand {
        guard !aid.isEmpty, aid.count <= 255 else { throw APDUValidationError.malformedLength }
        var bytes = Data([0x00, 0xA4, 0x04, 0x00, UInt8(aid.count)])
        bytes.append(aid)
        bytes.append(0x00)
        return try APDUCommand(name: name, bytes: bytes)
    }

    public static func getUID() throws -> APDUCommand {
        try APDUCommand(name: "Get UID", bytes: Data([0xFF, 0xCA, 0x00, 0x00, 0x00]))
    }

    public static func selectFile(id: UInt16, name: String) throws -> APDUCommand {
        try APDUCommand(
            name: name,
            bytes: Data([
                0x00,
                0xA4,
                0x00,
                0x0C,
                0x02,
                UInt8(id >> 8),
                UInt8(id & 0xFF),
            ])
        )
    }

    public static func readBinary(offset: UInt16, length: UInt8, name: String) throws
        -> APDUCommand {
        guard offset <= 0x7FFF else { throw APDUValidationError.malformedLength }
        return try APDUCommand(
            name: name,
            bytes: Data([
                0x00,
                0xB0,
                UInt8(offset >> 8),
                UInt8(offset & 0xFF),
                length,
            ])
        )
    }

    public static func validateReadOnly(_ bytes: Data) throws {
        guard bytes.count >= 4 else { throw APDUValidationError.tooShort }
        guard bytes.count <= 261 else { throw APDUValidationError.tooLong }

        let instruction = bytes[bytes.startIndex + 1]
        let allowed: Set<UInt8> = [0xA4, 0xB0, 0xB1, 0xC0, 0xCA, 0xCB]
        guard allowed.contains(instruction) else {
            throw APDUValidationError.stateChangingInstruction(instruction)
        }

        if bytes.count <= 5 { return }
        let lc = Int(bytes[bytes.startIndex + 4])
        guard lc > 0, bytes.count == 5 + lc || bytes.count == 6 + lc else {
            throw APDUValidationError.malformedLength
        }
    }
}

public struct APDUResponse: Codable, Hashable, Sendable {
    public let payload: Data
    public let statusWord: UInt16

    public init(raw: Data) throws {
        guard raw.count >= 2 else { throw APDUResponseError.missingStatusWord }
        payload = raw.dropLast(2)
        statusWord = UInt16(raw[raw.index(raw.endIndex, offsetBy: -2)]) << 8 |
            UInt16(raw[raw.index(before: raw.endIndex)])
    }

    public var succeeded: Bool { statusWord == 0x9000 }

    public var statusDescription: String {
        switch statusWord {
        case 0x9000: "Success"
        case 0x6283: "Selected file is invalidated"
        case 0x6300: "Authentication or verification failed"
        case 0x6700: "Wrong APDU length"
        case 0x6982: "Security status not satisfied"
        case 0x6985: "Conditions of use not satisfied"
        case 0x6A81: "Function not supported"
        case 0x6A82: "Application or file not found"
        case 0x6A86: "Incorrect parameters"
        case 0x6D00: "Instruction not supported"
        case 0x6E00: "Class not supported"
        default: String(format: "Card status %04X", statusWord)
        }
    }
}

public enum APDUResponseError: Error, Equatable {
    case missingStatusWord
}

public struct APDUEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let command: APDUCommand
    public let response: APDUResponse?
    public let transportError: String?
    public let durationMilliseconds: Int

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        command: APDUCommand,
        response: APDUResponse?,
        transportError: String?,
        durationMilliseconds: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.command = command
        self.response = response
        self.transportError = transportError
        self.durationMilliseconds = durationMilliseconds
    }
}
