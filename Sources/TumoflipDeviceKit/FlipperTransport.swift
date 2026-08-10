import Foundation

public protocol FlipperTransport: AnyObject, Sendable {
    var incomingBytes: AsyncStream<Data> { get }

    func connect() async throws
    func disconnect() async
    func send(_ data: Data) async throws
}

public enum FlipperTransportError: Error, LocalizedError, Equatable {
    case invalidDevicePath
    case cannotOpen(String, String)
    case cannotConfigure(String)
    case disconnected
    case shortWrite

    public var errorDescription: String? {
        switch self {
        case .invalidDevicePath:
            "The selected USB device path is invalid."
        case .cannotOpen(let path, let reason):
            "Cannot open \(path): \(reason)"
        case .cannotConfigure(let step):
            "Cannot configure the Flipper USB port (\(step))."
        case .disconnected:
            "Flipper disconnected."
        case .shortWrite:
            "The USB transfer stopped before all bytes were written."
        }
    }
}
