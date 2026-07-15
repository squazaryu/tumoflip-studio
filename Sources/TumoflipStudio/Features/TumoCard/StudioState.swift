import Foundation

enum StudioConnectionState: Equatable {
    case disconnected
    case readerReady
    case scanning
    case cardReady
    case unsupported(String)
    case failed(String)

    var title: String {
        switch self {
        case .disconnected: "Bridge disconnected"
        case .readerReady: "Waiting for card"
        case .scanning: "Reading public metadata"
        case .cardReady: "Card ready"
        case .unsupported: "Unsupported card"
        case .failed: "Connection error"
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected: "cable.connector.slash"
        case .readerReady: "sensor.tag.radiowaves.forward"
        case .scanning: "wave.3.right"
        case .cardReady: "checkmark.circle.fill"
        case .unsupported: "questionmark.diamond"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var detail: String? {
        switch self {
        case let .unsupported(message), let .failed(message): message
        default: nil
        }
    }

}

enum StudioSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case applications = "Applications"
    case metadata = "Metadata"
    case timeline = "APDU Timeline"
    case history = "History"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.and.text.magnifyingglass"
        case .applications: "square.stack.3d.up"
        case .metadata: "list.bullet.indent"
        case .timeline: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "Reader and public card metadata"
        case .applications: "Discoverable ISO 7816 applications"
        case .metadata: "Decoded fields without cardholder payloads"
        case .timeline: "Read-only command headers, status and timing"
        case .history: "Redacted sessions stored locally"
        }
    }
}
