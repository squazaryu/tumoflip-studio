import AppKit
import SwiftUI

struct StudioMenuBarView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.aiRadar.collectionStatus)
        Text(state.aiRadar.bridgeStatus)
        Text(state.aiRadar.relayLastAction)
        Divider()
        Button("Open Tumoflip Studio") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh AI Radar", action: state.aiRadar.collectNow)
        Divider()
        Button("Quit") {
            state.stop()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
