import Foundation

public struct CardApplication: Identifiable, Codable, Hashable, Sendable {
    public var id: String { aid }
    public let aid: String
    public let name: String
    public let source: String

    public init(aid: String, name: String, source: String) {
        self.aid = aid
        self.name = name
        self.source = source
    }
}

public struct CardSnapshot: Codable, Hashable, Sendable {
    public let readerName: String
    public let protocolName: String
    public let atr: String
    public let uid: String?
    public let applications: [CardApplication]
    public let metadata: [PublicMetadataItem]
    public let scannedAt: Date

    public init(
        readerName: String,
        protocolName: String,
        atr: String,
        uid: String?,
        applications: [CardApplication],
        metadata: [PublicMetadataItem] = [],
        scannedAt: Date = Date()
    ) {
        self.readerName = readerName
        self.protocolName = protocolName
        self.atr = atr
        self.uid = uid
        self.applications = applications
        self.metadata = metadata
        self.scannedAt = scannedAt
    }
}

public struct PublicMetadataItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(category)|\(label)|\(value)" }
    public let category: String
    public let label: String
    public let value: String

    public init(category: String, label: String, value: String) {
        self.category = category
        self.label = label
        self.value = value
    }
}

public enum KnownCardApplication {
    public static let ppseName = "2PAY.SYS.DDF01"
    public static let ppseAID = Data(ppseName.utf8)
    public static let ndefAID = Data(hex: "D2760000850101")!
    public static let pivAID = Data(hex: "A000000308000010000100")!

    public static func name(for aid: Data) -> String {
        switch aid.hex {
        case ndefAID.hex: "NFC Forum Type 4 / NDEF"
        case pivAID.hex: "PIV"
        default: paymentNetworkName(for: aid) ?? "ISO 7816 application"
        }
    }

    private static func paymentNetworkName(for aid: Data) -> String? {
        let value = aid.hex
        if value.hasPrefix("A000000003") { return "Visa" }
        if value.hasPrefix("A000000004") { return "Mastercard" }
        if value.hasPrefix("A000000025") { return "American Express" }
        if value.hasPrefix("A000000065") { return "JCB" }
        if value.hasPrefix("A000000333") { return "UnionPay" }
        if value.hasPrefix("A000000324") { return "Discover" }
        return nil
    }
}

public enum CardApplicationParser {
    public static func applications(from response: APDUResponse) -> [CardApplication] {
        guard response.succeeded, let nodes = try? BERTLVParser.parse(response.payload) else {
            return []
        }

        var results: [CardApplication] = []
        collectApplications(in: nodes, into: &results)
        var seen = Set<String>()
        return results.filter { seen.insert($0.aid).inserted }
    }

    private static func collectApplications(
        in nodes: [BERTLV],
        into results: inout [CardApplication]
    ) {
        for node in nodes {
            if node.tag == 0x61 {
                let aid = node.descendants(withTag: 0x4F).first?.value
                let labelData = node.descendants(withTag: 0x50).first?.value
                if let aid, !aid.isEmpty {
                    let label = labelData
                        .flatMap { String(data: $0, encoding: .ascii) }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    results.append(
                        CardApplication(
                            aid: aid.hex,
                            name: label.flatMap { $0.isEmpty ? nil : $0 }
                                ?? KnownCardApplication.name(for: aid),
                            source: "PPSE"
                        )
                    )
                }
            }
            collectApplications(in: node.children, into: &results)
        }
    }
}
