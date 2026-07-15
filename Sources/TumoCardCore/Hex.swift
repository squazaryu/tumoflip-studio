import Foundation

public extension Data {
    init?(hex: String) {
        let compact = hex.filter { !$0.isWhitespace && $0 != ":" }
        guard compact.count.isMultiple(of: 2) else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    var hex: String {
        map { String(format: "%02X", $0) }.joined()
    }

    var spacedHex: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
