import Foundation

struct ActivityLogEntry: Identifiable, Equatable {
    enum Level: String {
        case info
        case warning
        case error
    }

    let id = UUID()
    let date: Date
    let level: Level
    let source: String
    let message: String
}

@MainActor
final class ActivityLogStore: ObservableObject {
    @Published private(set) var entries: [ActivityLogEntry] = []

    private let maximumEntries = 500

    func append(_ message: String, source: String, level: ActivityLogEntry.Level = .info) {
        entries.append(ActivityLogEntry(date: Date(), level: level, source: source, message: message))
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}
