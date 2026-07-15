import SwiftUI

struct TumoCardFeatureView: View {
    @ObservedObject var store: StudioStore

    var body: some View {
        StudioView(store: store)
            .onAppear { store.startMonitoring() }
            .onDisappear { store.stopMonitoring() }
    }
}
