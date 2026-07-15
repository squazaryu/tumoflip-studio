import SwiftUI

struct StudioRootView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 190, idealWidth: 215, maxWidth: 240)

            detail
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .foregroundStyle(.tint)
                Text("Tumoflip Studio")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            List(WorkspaceSection.allCases, selection: $state.selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selection ?? .overview {
        case .overview:
            StudioOverviewView(
                transport: state.transport,
                aiRadar: state.aiRadar,
                card: state.card,
                open: { state.selection = $0 }
            )
        case .aiRadar:
            AIRadarView(store: state.aiRadar)
        case .cards:
            TumoCardFeatureView(store: state.card)
        case .network:
            NetworkLabView()
                .environmentObject(state.network)
                .environmentObject(state.crack)
        case .developer:
            DeveloperView(store: state.developer)
        case .logs:
            LogsView(store: state.log)
        }
    }
}
