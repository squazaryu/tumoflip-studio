import SwiftUI

struct AIRadarView: View {
    @ObservedObject var store: AIRadarStore

    var body: some View {
        VStack(spacing: 0) {
            StudioPageHeader(
                title: "AI & Relay",
                subtitle: store.collectionStatus,
                systemImage: "antenna.radiowaves.left.and.right"
            ) {
                Button("Refresh", systemImage: "arrow.clockwise", action: store.collectNow)
                Menu {
                    Button("Reload Relay", systemImage: "arrow.triangle.2.circlepath", action: store.reloadRelayMappings)
                    Button("Copy Endpoint URL", systemImage: "doc.on.doc", action: store.copyEndpoint)
                    Divider()
                    Button("Restart HTTP Service", systemImage: "network", action: store.restartHTTPService)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: StudioLayout.sectionSpacing) {
                StudioPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        StudioSectionHeader(title: "Services", systemImage: "network")
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                            GridRow {
                                Label("AI endpoint", systemImage: "network")
                                Text(store.endpointURL).textSelection(.enabled)
                                statusPill(store.isListening ? "Listening" : "Stopped", active: store.isListening)
                            }
                            GridRow {
                                Label("BLE App Bridge", systemImage: "antenna.radiowaves.left.and.right")
                                Text(store.bridgeStatus)
                                statusPill(store.bridgeStatus.hasSuffix("ready") ? "Ready" : "Waiting", active: store.bridgeStatus.hasSuffix("ready"))
                            }
                            GridRow {
                                Label("Relay allowlist", systemImage: "list.bullet.rectangle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(store.relayStatus)
                                    Text(store.relayConfigPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Text(store.relayLastAction)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            GridRow {
                                Label("Collection", systemImage: "clock.arrow.circlepath")
                                Picker("Interval", selection: $store.interval) {
                                    Text("1 min").tag(60.0)
                                    Text("2 min").tag(120.0)
                                    Text("5 min").tag(300.0)
                                    Text("10 min").tag(600.0)
                                }
                                .labelsHidden()
                                .frame(width: 120)
                                Text(store.lastUpdated?.formatted(date: .omitted, time: .standard) ?? "Never")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let error = store.serviceError {
                    StudioPanel {
                        HStack {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Retry", systemImage: "arrow.clockwise", action: store.restartHTTPService)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    StudioSectionHeader(title: "Provider Snapshot", systemImage: "doc.text.magnifyingglass")
                    StudioConsole(
                        text: store.snapshot,
                        placeholder: "No provider snapshot available.",
                        minHeight: 260
                    )
                }
            }
            .padding(StudioLayout.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func statusPill(_ title: String, active: Bool) -> some View {
        StudioStatusLabel(
            title: title,
            systemImage: active ? "checkmark.circle.fill" : "clock",
            color: active ? .green : .secondary
        )
    }
}
