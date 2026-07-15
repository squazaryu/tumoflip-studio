import Foundation

public struct BERTLV: Hashable, Sendable {
    public let tag: UInt32
    public let value: Data
    public let children: [BERTLV]

    public init(tag: UInt32, value: Data, children: [BERTLV]) {
        self.tag = tag
        self.value = value
        self.children = children
    }

    public func descendants(withTag requestedTag: UInt32) -> [BERTLV] {
        var matches = tag == requestedTag ? [self] : []
        for child in children {
            matches.append(contentsOf: child.descendants(withTag: requestedTag))
        }
        return matches
    }
}

public enum BERTLVError: Error, Equatable {
    case truncatedTag
    case truncatedLength
    case unsupportedLength
    case valueOutOfBounds
    case nestingTooDeep
}

public enum BERTLVParser {
    public static func parse(_ data: Data) throws -> [BERTLV] {
        try parse(data, depth: 0)
    }

    private static func parse(_ data: Data, depth: Int) throws -> [BERTLV] {
        guard depth <= 8 else { throw BERTLVError.nestingTooDeep }
        var index = data.startIndex
        var result: [BERTLV] = []

        while index < data.endIndex {
            let firstTagByte = data[index]
            index = data.index(after: index)
            var tag = UInt32(firstTagByte)

            if firstTagByte & 0x1F == 0x1F {
                var tagBytes = 1
                while true {
                    guard index < data.endIndex else { throw BERTLVError.truncatedTag }
                    let byte = data[index]
                    index = data.index(after: index)
                    tag = (tag << 8) | UInt32(byte)
                    tagBytes += 1
                    guard tagBytes <= 4 else { throw BERTLVError.truncatedTag }
                    if byte & 0x80 == 0 { break }
                }
            }

            guard index < data.endIndex else { throw BERTLVError.truncatedLength }
            let firstLength = data[index]
            index = data.index(after: index)
            let length: Int
            if firstLength & 0x80 == 0 {
                length = Int(firstLength)
            } else {
                let byteCount = Int(firstLength & 0x7F)
                guard byteCount > 0, byteCount <= 3 else { throw BERTLVError.unsupportedLength }
                guard data.distance(from: index, to: data.endIndex) >= byteCount else {
                    throw BERTLVError.truncatedLength
                }
                var accumulated = 0
                for _ in 0..<byteCount {
                    accumulated = (accumulated << 8) | Int(data[index])
                    index = data.index(after: index)
                }
                length = accumulated
            }

            guard length <= 65_535,
                  data.distance(from: index, to: data.endIndex) >= length else {
                throw BERTLVError.valueOutOfBounds
            }
            let end = data.index(index, offsetBy: length)
            let value = Data(data[index..<end])
            index = end

            let isConstructed = firstTagByte & 0x20 != 0
            let children = isConstructed ? (try parse(value, depth: depth + 1)) : []
            result.append(BERTLV(tag: tag, value: value, children: children))
        }
        return result
    }
}
