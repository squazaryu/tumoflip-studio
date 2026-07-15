import SwiftUI

struct LogsView: View {
    @ObservedObject var store: ActivityLogStore

    var body: some View {
        VStack(spacing: 0) {
            StudioPageHeader(
                title: "Activity",
                subtitle: store.entries.isEmpty ? "No recorded events" : "\(store.entries.count) recorded events",
                systemImage: "text.alignleft"
            ) {
                Button("Clear", systemImage: "trash", action: store.clear)
                    .disabled(store.entries.isEmpty)
            }

            Divider()

            if store.entries.isEmpty {
                ContentUnavailableView("No Activity", systemImage: "text.alignleft")
            } else {
                Table(store.entries) {
                    TableColumn("Time") { entry in
                        Text(entry.date.formatted(date: .omitted, time: .standard))
                            .monospacedDigit()
                    }
                    .width(90)
                    TableColumn("Source", value: \.source)
                        .width(min: 110, ideal: 150)
                    TableColumn("Level") { entry in
                        Text(entry.level.rawValue.capitalized)
                            .foregroundStyle(color(for: entry.level))
                    }
                    .width(80)
                    TableColumn("Message", value: \.message)
                }
            }
        }
    }

    private func color(for level: ActivityLogEntry.Level) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
