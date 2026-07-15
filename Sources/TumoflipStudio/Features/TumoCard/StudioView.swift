import SwiftUI
import TumoCardCore

struct StudioView: View {
    @ObservedObject var store: StudioStore

    private var selectedSection: StudioSection {
        store.selectedSection ?? .overview
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioPageHeader(
                title: "TumoCard",
                subtitle: selectedSection.subtitle,
                systemImage: "creditcard"
            ) {
                Button("Refresh", systemImage: "arrow.clockwise", action: store.refresh)

                Menu {
                    Button("JSON Report", systemImage: "curlybraces", action: store.exportJSON)
                    Button("Text Report", systemImage: "doc.plaintext", action: store.exportText)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(store.snapshot == nil)
            }

            Divider()

            HStack {
                Picker("Section", selection: Binding(
                    get: { selectedSection },
                    set: { store.selectedSection = $0 }
                )) {
                    ForEach(StudioSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 680)
                Spacer()
            }
            .padding(.horizontal, StudioLayout.pagePadding)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            Group {
                switch selectedSection {
                case .overview:
                    OverviewView(store: store)
                case .applications:
                    ApplicationsView(store: store)
                case .metadata:
                    MetadataView(store: store)
                case .timeline:
                    TimelineView(store: store)
                case .history:
                    HistoryView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            BridgeStatusFooter(store: store)
        }
    }
}

private struct MetadataView: View {
    @ObservedObject var store: StudioStore

    var body: some View {
        Group {
            if let metadata = store.snapshot?.metadata, !metadata.isEmpty {
                Table(metadata) {
                    TableColumn("Category", value: \.category)
                        .width(min: 80, ideal: 100, max: 130)
                    TableColumn("Field", value: \.label)
                    TableColumn("Value", value: \.value)
                }
            } else {
                ContentUnavailableView(
                    "No public metadata",
                    systemImage: "list.bullet.indent",
                    description: Text("No supported decoder produced metadata for this card.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryView: View {
    @ObservedObject var store: StudioStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Completed read-only sessions are stored automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive, action: store.deleteSelectedHistory) {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(store.selectedHistoryID == nil)
            }
            .padding(.horizontal, StudioLayout.pagePadding)
            .padding(.vertical, 10)

            Divider()

            if let error = store.historyError {
                ContentUnavailableView(
                    "History unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.history.isEmpty {
                ContentUnavailableView(
                    "No saved sessions",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Completed read-only sessions are stored here automatically.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(store.history, selection: $store.selectedHistoryID) {
                    TableColumn("Date") { report in
                        Text(report.generatedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    TableColumn("Protocol") { report in
                        Text(report.card.protocolName)
                    }
                    TableColumn("UID fingerprint") { report in
                        Text(report.card.uidFingerprint ?? "Unavailable")
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Applications") { report in
                        Text(String(report.card.applications.count))
                    }
                }
            }
        }
    }
}

private struct BridgeStatusFooter: View {
    @ObservedObject var store: StudioStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: store.connectionState.systemImage)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.connectionState.title)
                    .font(.callout.weight(.medium))
                if let reader = store.readerName {
                    Text(reader)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, StudioLayout.pagePadding)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var statusColor: Color {
        switch store.connectionState {
        case .cardReady: .green
        case .scanning: .orange
        case .failed: .red
        default: .secondary
        }
    }
}

private struct OverviewView: View {
    @ObservedObject var store: StudioStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioLayout.sectionSpacing) {
                if let detail = store.connectionState.detail {
                    Label(detail, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                if let card = store.snapshot {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 14) {
                        SummaryRow(label: "Reader", value: card.readerName)
                        SummaryRow(label: "Protocol", value: card.protocolName)
                        SummaryRow(label: "ATR", value: card.atr)
                        SummaryRow(label: "UID", value: card.uid ?? "Unavailable")
                        SummaryRow(label: "Applications", value: String(card.applications.count))
                        SummaryRow(
                            label: "Scanned",
                            value: card.scannedAt.formatted(date: .abbreviated, time: .standard)
                        )
                    }
                    .textSelection(.enabled)

                    Divider()

                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(.orange)
                        Text("Read-only session. APDU payloads are excluded from exported reports.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView(
                        store.connectionState.title,
                        systemImage: store.connectionState.systemImage,
                        description: Text(emptyStateDescription)
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(StudioLayout.pagePadding)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private var emptyStateDescription: String {
        switch store.connectionState {
        case .disconnected: "NFC CCID Bridge is not available over USB."
        case .readerReady: "The bridge is ready for an ISO 14443-4 card."
        case .scanning: "The card is being queried with read-only APDUs."
        case let .unsupported(message), let .failed(message): message
        case .cardReady: "Card metadata is available."
        }
    }
}

private struct ApplicationsView: View {
    @ObservedObject var store: StudioStore

    var body: some View {
        Group {
            if let applications = store.snapshot?.applications, !applications.isEmpty {
                Table(applications) {
                    TableColumn("Name", value: \.name)
                    TableColumn("AID", value: \.aid)
                    TableColumn("Source", value: \.source)
                }
            } else {
                ContentUnavailableView(
                    "No applications discovered",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("The card did not expose a supported public application directory.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TimelineView: View {
    @ObservedObject var store: StudioStore

    var body: some View {
        Group {
            if store.timeline.isEmpty {
                ContentUnavailableView(
                    "No APDU events",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Events appear after a supported card is detected.")
                )
            } else {
                Table(store.timeline) {
                    TableColumn("Command") { event in
                        Text(event.command.name)
                    }
                    TableColumn("Header") { event in
                        Text(
                            String(
                                format: "%02X %02X %02X %02X",
                                event.command.cla,
                                event.command.instruction,
                                event.command.p1,
                                event.command.p2
                            )
                        )
                        .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Status") { event in
                        if let response = event.response {
                            Text(String(format: "%04X", response.statusWord))
                                .foregroundStyle(response.succeeded ? .green : .secondary)
                        } else {
                            Text("Transport")
                                .foregroundStyle(.red)
                        }
                    }
                    TableColumn("Time") { event in
                        Text("\(event.durationMilliseconds) ms")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(.body, design: label == "ATR" || label == "UID" ? .monospaced : .default))
        }
    }
}
