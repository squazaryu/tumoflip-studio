import SwiftUI

struct StudioOverviewView: View {
    @ObservedObject var transport: TransportCoordinator
    @ObservedObject var aiRadar: AIRadarStore
    @ObservedObject var card: StudioStore
    let open: (WorkspaceSection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            StudioPageHeader(
                title: "Overview",
                subtitle: "Flipper, Module One and desktop services",
                systemImage: "rectangle.grid.2x2"
            ) {
                Button("Refresh Devices", systemImage: "arrow.clockwise", action: transport.refreshDevices)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: StudioLayout.sectionSpacing) {
                    StudioPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            StudioSectionHeader(title: "Connections", systemImage: "cable.connector")

                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                                GridRow {
                                    Label("Flipper USB", systemImage: "cable.connector")
                                    Text(transport.serialDevices.first(where: { $0.contains("usbmodemflip") }) ?? "Not detected")
                                        .textSelection(.enabled)
                                    connectionStatus(transport.serialDevices.contains(where: { $0.contains("usbmodemflip") }))
                                }
                                GridRow {
                                    Label("AI endpoint", systemImage: "network")
                                    Text(aiRadar.endpointURL).textSelection(.enabled)
                                    connectionStatus(aiRadar.isListening)
                                }
                                GridRow {
                                    Label("BLE App Bridge", systemImage: "antenna.radiowaves.left.and.right")
                                    Text(aiRadar.bridgeStatus)
                                    connectionStatus(aiRadar.bridgeStatus.hasSuffix("ready"))
                                }
                            }
                        }
                    }

                    StudioPanel(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            StudioSectionHeader(title: "Workspaces", systemImage: "square.grid.2x2")
                                .padding(14)
                            Divider()
                            workspaceRow(
                                title: "AI & Relay",
                                detail: aiRadar.collectionStatus,
                                icon: "antenna.radiowaves.left.and.right",
                                section: .aiRadar
                            )
                            Divider()
                            workspaceRow(
                                title: "TumoCard",
                                detail: card.connectionState.displayText,
                                icon: "creditcard",
                                section: .cards
                            )
                            Divider()
                            workspaceRow(
                                title: "Network Lab",
                                detail: "Module One capture and network inspection",
                                icon: "wifi.router",
                                section: .network
                            )
                            Divider()
                            workspaceRow(
                                title: "FAP Developer",
                                detail: "FAP validation, build and USB launch",
                                icon: "hammer",
                                section: .developer
                            )
                        }
                    }

                    if let conflict = transport.lastConflict {
                        Label(conflict, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .padding(StudioLayout.pagePadding)
                .frame(maxWidth: 920, alignment: .leading)
            }
        }
    }

    private func connectionStatus(_ connected: Bool) -> some View {
        StudioStatusLabel(
            title: connected ? "Available" : "Waiting",
            systemImage: connected ? "checkmark.circle.fill" : "clock",
            color: connected ? .green : .secondary
        )
    }

    private func workspaceRow(
        title: String,
        detail: String,
        icon: String,
        section: WorkspaceSection
    ) -> some View {
        Button { open(section) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 22)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }
}

private extension StudioConnectionState {
    var displayText: String {
        switch self {
        case .disconnected: "CCID bridge disconnected"
        case .readerReady: "CCID bridge ready"
        case .scanning: "Reading card"
        case .cardReady: "Card ready"
        case .unsupported(let message): message
        case .failed(let message): message
        }
    }
}
