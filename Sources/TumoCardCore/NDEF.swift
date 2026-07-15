import Foundation

public struct NDEFType4CapabilityContainer: Equatable, Sendable {
    public let mappingVersion: UInt8
    public let maximumReadLength: UInt16
    public let maximumCommandLength: UInt16
    public let ndefFileID: UInt16
    public let maximumNDEFSize: UInt16
    public let readAccess: UInt8
    public let writeAccess: UInt8

    public static func parse(_ data: Data) throws -> NDEFType4CapabilityContainer {
        guard data.count >= 15 else { throw NDEFError.truncatedCapabilityContainer }
        let bytes = [UInt8](data)
        let declaredLength = Int(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        guard declaredLength >= 15, data.count >= min(declaredLength, 15) else {
            throw NDEFError.truncatedCapabilityContainer
        }
        guard bytes[7] == 0x04, bytes[8] == 0x06 else {
            throw NDEFError.missingNDEFFileControl
        }
        return NDEFType4CapabilityContainer(
            mappingVersion: bytes[2],
            maximumReadLength: UInt16(bytes[3]) << 8 | UInt16(bytes[4]),
            maximumCommandLength: UInt16(bytes[5]) << 8 | UInt16(bytes[6]),
            ndefFileID: UInt16(bytes[9]) << 8 | UInt16(bytes[10]),
            maximumNDEFSize: UInt16(bytes[11]) << 8 | UInt16(bytes[12]),
            readAccess: bytes[13],
            writeAccess: bytes[14]
        )
    }
}

public struct NDEFRecordSummary: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let type: String
    public let payloadLength: Int
    public let language: String?
    public let uriScheme: String?

    public init(
        id: UUID = UUID(),
        type: String,
        payloadLength: Int,
        language: String?,
        uriScheme: String?
    ) {
        self.id = id
        self.type = type
        self.payloadLength = payloadLength
        self.language = language
        self.uriScheme = uriScheme
    }

    public var metadata: [PublicMetadataItem] {
        var result = [
            PublicMetadataItem(category: "NDEF", label: "Record type", value: type),
            PublicMetadataItem(
                category: "NDEF",
                label: "Payload size",
                value: "\(payloadLength) bytes"
            ),
        ]
        if let language {
            result.append(PublicMetadataItem(category: "NDEF", label: "Language", value: language))
        }
        if let uriScheme {
            result.append(PublicMetadataItem(category: "NDEF", label: "URI scheme", value: uriScheme))
        }
        return result
    }
}

public enum NDEFError: Error, Equatable {
    case truncatedCapabilityContainer
    case missingNDEFFileControl
    case messageTooLarge
    case truncatedRecord
    case chunkedRecordUnsupported
    case invalidMessageBoundary
}

public enum NDEFMessageParser {
    private static let maximumMessageSize = 65_535
    private static let maximumRecordCount = 64

    public static func summaries(from data: Data) throws -> [NDEFRecordSummary] {
        guard data.count <= maximumMessageSize else { throw NDEFError.messageTooLarge }
        var index = data.startIndex
        var records: [NDEFRecordSummary] = []
        var sawMessageBegin = false
        var sawMessageEnd = false

        while index < data.endIndex {
            guard records.count < maximumRecordCount else { throw NDEFError.messageTooLarge }
            let header = try readByte(data, index: &index)
            let messageBegin = header & 0x80 != 0
            let messageEnd = header & 0x40 != 0
            let chunked = header & 0x20 != 0
            let shortRecord = header & 0x10 != 0
            let hasID = header & 0x08 != 0
            let tnf = header & 0x07

            if chunked { throw NDEFError.chunkedRecordUnsupported }
            if records.isEmpty && !messageBegin { throw NDEFError.invalidMessageBoundary }
            if !records.isEmpty && messageBegin { throw NDEFError.invalidMessageBoundary }
            sawMessageBegin = sawMessageBegin || messageBegin

            let typeLength = Int(try readByte(data, index: &index))
            let payloadLength: Int
            if shortRecord {
                payloadLength = Int(try readByte(data, index: &index))
            } else {
                payloadLength = Int(try readUInt32(data, index: &index))
            }
            let idLength = hasID ? Int(try readByte(data, index: &index)) : 0
            guard payloadLength <= maximumMessageSize else { throw NDEFError.messageTooLarge }

            let type = try readData(data, index: &index, count: typeLength)
            _ = try readData(data, index: &index, count: idLength)
            let payload = try readData(data, index: &index, count: payloadLength)
            records.append(summary(tnf: tnf, type: type, payload: payload))

            if messageEnd {
                sawMessageEnd = true
                guard index == data.endIndex else { throw NDEFError.invalidMessageBoundary }
            }
        }

        guard sawMessageBegin, sawMessageEnd else { throw NDEFError.invalidMessageBoundary }
        return records
    }

    private static func summary(tnf: UInt8, type: Data, payload: Data) -> NDEFRecordSummary {
        let typeString = String(data: type, encoding: .utf8) ?? type.hex
        var displayType = "TNF \(tnf): \(typeString)"
        var language: String?
        var uriScheme: String?

        if tnf == 0x01, typeString == "T", let status = payload.first {
            displayType = "Text"
            let languageLength = Int(status & 0x3F)
            if payload.count >= 1 + languageLength {
                language = String(
                    data: payload.dropFirst().prefix(languageLength),
                    encoding: .ascii
                )
            }
        } else if tnf == 0x01, typeString == "U", let prefix = payload.first {
            displayType = "URI"
            uriScheme = uriPrefix(prefix)
        } else if tnf == 0x02 {
            displayType = "MIME: \(typeString)"
        } else if tnf == 0x04 {
            displayType = "External: \(typeString)"
        }

        return NDEFRecordSummary(
            type: displayType,
            payloadLength: payload.count,
            language: language,
            uriScheme: uriScheme
        )
    }

    private static func uriPrefix(_ code: UInt8) -> String? {
        let prefixes = [
            "", "http://www.", "https://www.", "http://", "https://", "tel:", "mailto:",
            "ftp://anonymous:anonymous@", "ftp://ftp.", "ftps://", "sftp://", "smb://",
            "nfs://", "ftp://", "dav://", "news:", "telnet://", "imap:", "rtsp://",
            "urn:", "pop:", "sip:", "sips:", "tftp:", "btspp://", "btl2cap://",
            "btgoep://", "tcpobex://", "irdaobex://", "file://", "urn:epc:id:",
            "urn:epc:tag:", "urn:epc:pat:", "urn:epc:raw:", "urn:epc:", "urn:nfc:",
        ]
        guard Int(code) < prefixes.count else { return "unknown" }
        return prefixes[Int(code)].isEmpty ? "none" : prefixes[Int(code)]
    }

    private static func readByte(_ data: Data, index: inout Data.Index) throws -> UInt8 {
        guard index < data.endIndex else { throw NDEFError.truncatedRecord }
        defer { index = data.index(after: index) }
        return data[index]
    }

    private static func readUInt32(_ data: Data, index: inout Data.Index) throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 { value = (value << 8) | UInt32(try readByte(data, index: &index)) }
        return value
    }

    private static func readData(
        _ data: Data,
        index: inout Data.Index,
        count: Int
    ) throws -> Data {
        guard count >= 0, data.distance(from: index, to: data.endIndex) >= count else {
            throw NDEFError.truncatedRecord
        }
        let end = data.index(index, offsetBy: count)
        defer { index = end }
        return Data(data[index..<end])
    }
}
