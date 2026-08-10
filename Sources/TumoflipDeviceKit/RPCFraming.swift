import Foundation

public enum RPCFramingError: Error, LocalizedError, Equatable {
    case malformedLength
    case frameTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .malformedLength:
            "Malformed protobuf frame length."
        case .frameTooLarge(let size):
            "Protobuf frame is too large (\(size) bytes)."
        }
    }
}

public struct DelimitedProtobufDecoder: Sendable {
    private var buffer = Data()
    private let maximumFrameSize: Int

    public init(maximumFrameSize: Int = 1_048_576) {
        self.maximumFrameSize = maximumFrameSize
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while !buffer.isEmpty {
            guard let (length, prefixLength) = Self.readVarint(buffer) else {
                if buffer.prefix(10).count == 10,
                   buffer.prefix(10).allSatisfy({ $0 & 0x80 != 0 }) {
                    throw RPCFramingError.malformedLength
                }
                break
            }

            guard length <= UInt64(maximumFrameSize) else {
                throw RPCFramingError.frameTooLarge(Int(clamping: length))
            }
            let total = prefixLength + Int(length)
            guard buffer.count >= total else { break }

            frames.append(buffer.subdata(in: prefixLength..<total))
            buffer.removeSubrange(0..<total)
        }

        return frames
    }

    public static func encode(_ payload: Data) -> Data {
        var result = encodeVarint(UInt64(payload.count))
        result.append(payload)
        return result
    }

    public static func encodeVarint(_ value: UInt64) -> Data {
        var remaining = value
        var result = Data()
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            result.append(byte)
        } while remaining != 0
        return result
    }

    public static func readVarint(_ data: Data) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0

        for (index, byte) in data.prefix(10).enumerated() {
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return (value, index + 1)
            }
            shift += 7
        }
        return nil
    }
}
