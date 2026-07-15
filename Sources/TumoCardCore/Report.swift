import CryptoKit
import Foundation

public struct RedactedAPDURecord: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let name: String
    public let header: String
    public let commandLength: Int
    public let responseLength: Int?
    public let statusWord: String?
    public let durationMilliseconds: Int
    public let transportError: String?
    public let responseDigest: String?
}

public struct RedactedCardSummary: Codable, Hashable, Sendable {
    public let readerName: String
    public let protocolName: String
    public let atr: String
    public let uidFingerprint: String?
    public let applications: [CardApplication]
    public let metadata: [PublicMetadataItem]
    public let scannedAt: Date

    init(card: CardSnapshot) {
        readerName = card.readerName
        protocolName = card.protocolName
        atr = card.atr
        uidFingerprint = card.uid
            .flatMap(Data.init(hex:))
            .map { "sha256:" + Data(SHA256.hash(data: $0)).prefix(8).hex }
        applications = card.applications
        metadata = card.metadata
        scannedAt = card.scannedAt
    }
}

public struct TumoCardReport: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let formatVersion: Int
    public let generatedAt: Date
    public let card: RedactedCardSummary
    public let timeline: [RedactedAPDURecord]
    public let notice: String

    public init(
        id: UUID = UUID(),
        card: CardSnapshot,
        events: [APDUEvent],
        generatedAt: Date = Date()
    ) {
        self.id = id
        formatVersion = 1
        self.generatedAt = generatedAt
        self.card = RedactedCardSummary(card: card)
        timeline = events.map { event in
            RedactedAPDURecord(
                timestamp: event.timestamp,
                name: event.command.name,
                header: String(
                    format: "%02X %02X %02X %02X",
                    event.command.cla,
                    event.command.instruction,
                    event.command.p1,
                    event.command.p2
                ),
                commandLength: event.command.bytes.count,
                responseLength: event.response.map { $0.payload.count + 2 },
                statusWord: event.response.map { String(format: "%04X", $0.statusWord) },
                durationMilliseconds: event.durationMilliseconds,
                transportError: event.transportError,
                responseDigest: event.response.map { response in
                    Data(SHA256.hash(data: response.payload)).prefix(8).hex
                }
            )
        }
        notice = "APDU payloads and cardholder data are omitted by default."
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    public func text() -> String {
        var lines = [
            "TumoCard Studio report",
            "Generated: \(generatedAt.ISO8601Format())",
            "Reader: \(card.readerName)",
            "Protocol: \(card.protocolName)",
            "ATR: \(card.atr)",
            "UID: \(card.uidFingerprint ?? "Unavailable")",
            "Applications: \(card.applications.count)",
            "",
            "APDU timeline",
        ]
        for event in timeline {
            let status = event.statusWord ?? "TRANSPORT"
            lines.append(
                "\(event.timestamp.ISO8601Format())  \(event.name)  SW=\(status)  \(event.durationMilliseconds)ms"
            )
        }
        lines.append("")
        lines.append(notice)
        return lines.joined(separator: "\n")
    }
}
