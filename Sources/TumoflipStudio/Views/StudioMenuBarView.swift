import AppKit
import SwiftUI

struct StudioMenuBarView: View {
    @ObservedObject var state: AppState
    let quitCompletely: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label("Tumoflip Studio", systemImage: "waveform.path.ecg")
        Text("Background services are active")
        Text(state.aiRadar.collectionStatus)
        Text(state.aiRadar.bridgeStatus)
        Text(state.aiRadar.relayLastAction)
        Divider()
        Button("Open Tumoflip Studio") {
            openMainWindow()
        }
        .keyboardShortcut("o")
        Button("Refresh AI Radar", action: state.aiRadar.collectNow)
        Divider()
        Button("Quit Completely", action: quitCompletely)
        .keyboardShortcut("q")
    }

    private func openMainWindow() {
        if let window = NSApp.windows.first(where: { $0.title == "Tumoflip Studio" && $0.canBecomeMain }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct StudioMenuBarLabel: View {
    var body: some View {
        Image(systemName: "waveform.path.ecg")
    }
}
