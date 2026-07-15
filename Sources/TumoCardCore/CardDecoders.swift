import Foundation

public protocol CardMetadataDecoder: Sendable {
    var identifier: String { get }
    func supports(application: CardApplication) -> Bool
    func decode(application: CardApplication, response: APDUResponse) -> [PublicMetadataItem]
}

public struct EMVFCIDecoder: CardMetadataDecoder {
    public let identifier = "emv-fci"

    public init() {}

    public func supports(application: CardApplication) -> Bool {
        let aid = application.aid
        return aid.hasPrefix("A000000003") || aid.hasPrefix("A000000004") ||
            aid.hasPrefix("A000000025") || aid.hasPrefix("A000000065") ||
            aid.hasPrefix("A000000333") || aid.hasPrefix("A000000324")
    }

    public func decode(
        application: CardApplication,
        response: APDUResponse
    ) -> [PublicMetadataItem] {
        guard response.succeeded, let nodes = try? BERTLVParser.parse(response.payload) else {
            return []
        }

        var items = [
            PublicMetadataItem(category: "EMV", label: "Application", value: application.name),
            PublicMetadataItem(category: "EMV", label: "AID", value: application.aid),
        ]
        appendASCII(tag: 0x50, label: "Label", nodes: nodes, items: &items)
        appendASCII(tag: 0x9F12, label: "Preferred name", nodes: nodes, items: &items)
        appendASCII(tag: 0x5F2D, label: "Languages", nodes: nodes, items: &items)

        if let priority = firstValue(tag: 0x87, nodes: nodes)?.first {
            items.append(
                PublicMetadataItem(
                    category: "EMV",
                    label: "Directory priority",
                    value: String(priority & 0x0F)
                )
            )
        }
        return deduplicated(items)
    }

    private func appendASCII(
        tag: UInt32,
        label: String,
        nodes: [BERTLV],
        items: inout [PublicMetadataItem]
    ) {
        guard let data = firstValue(tag: tag, nodes: nodes),
              let value = String(data: data, encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return
        }
        items.append(PublicMetadataItem(category: "EMV", label: label, value: value))
    }

    private func firstValue(tag: UInt32, nodes: [BERTLV]) -> Data? {
        for node in nodes {
            if let match = node.descendants(withTag: tag).first { return match.value }
        }
        return nil
    }
}

public struct CardDecoderRegistry: Sendable {
    private let decoders: [any CardMetadataDecoder]

    public init(decoders: [any CardMetadataDecoder] = [EMVFCIDecoder()]) {
        self.decoders = decoders
    }

    public func decode(
        application: CardApplication,
        response: APDUResponse
    ) -> [PublicMetadataItem] {
        deduplicated(
            decoders
                .filter { $0.supports(application: application) }
                .flatMap { $0.decode(application: application, response: response) }
        )
    }
}

private func deduplicated(_ items: [PublicMetadataItem]) -> [PublicMetadataItem] {
    var seen = Set<String>()
    return items.filter { seen.insert($0.id).inserted }
}
