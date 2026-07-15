import Foundation

enum TransportKind: String, CaseIterable, Identifiable {
    case bluetooth
    case localHTTP
    case pcsc
    case serial
    case flipperUSB

    var id: Self { self }

    var title: String {
        switch self {
        case .bluetooth: "Bluetooth"
        case .localHTTP: "Local HTTP"
        case .pcsc: "USB CCID"
        case .serial: "USB Serial"
        case .flipperUSB: "Flipper USB"
        }
    }

    var isWiredExclusive: Bool {
        switch self {
        case .pcsc, .serial, .flipperUSB: true
        case .bluetooth, .localHTTP: false
        }
    }
}

struct TransportLease: Identifiable, Equatable {
    var id: TransportKind { kind }
    let kind: TransportKind
    let owner: String
    let acquiredAt: Date
}

@MainActor
final class TransportCoordinator: ObservableObject {
    @Published private(set) var leases: [TransportKind: TransportLease] = [:]
    @Published private(set) var serialDevices: [String] = []
    @Published private(set) var lastConflict: String?

    private let log: ActivityLogStore

    init(log: ActivityLogStore) {
        self.log = log
        refreshDevices()
    }

    @discardableResult
    func acquire(_ kind: TransportKind, owner: String) -> Bool {
        if let current = leases[kind] {
            if current.owner == owner { return true }
            return reject(kind, owner: owner, conflict: current)
        }

        if kind.isWiredExclusive,
           let conflict = leases.values.first(where: { $0.kind.isWiredExclusive && $0.owner != owner }) {
            return reject(kind, owner: owner, conflict: conflict)
        }

        leases[kind] = TransportLease(kind: kind, owner: owner, acquiredAt: Date())
        lastConflict = nil
        log.append("Acquired \(kind.title)", source: owner)
        return true
    }

    func release(_ kind: TransportKind, owner: String) {
        guard leases[kind]?.owner == owner else { return }
        leases[kind] = nil
        log.append("Released \(kind.title)", source: owner)
    }

    func releaseAll(owner: String) {
        for kind in leases.values.filter({ $0.owner == owner }).map(\.kind) {
            release(kind, owner: owner)
        }
    }

    func refreshDevices() {
        let dev = URL(fileURLWithPath: "/dev", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(
            at: dev,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        serialDevices = names
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("cu.usb") || $0.hasPrefix("cu.wch") || $0.hasPrefix("cu.SLAB") }
            .sorted()
            .map { "/dev/\($0)" }
    }

    private func reject(_ kind: TransportKind, owner: String, conflict: TransportLease) -> Bool {
        let message = "\(kind.title) is unavailable while \(conflict.owner) owns \(conflict.kind.title)."
        lastConflict = message
        log.append(message, source: owner, level: .warning)
        return false
    }
}
