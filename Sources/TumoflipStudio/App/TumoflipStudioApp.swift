import AppKit
import SwiftUI

final class TumoflipStudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct TumoflipStudioApp: App {
    @NSApplicationDelegateAdaptor(TumoflipStudioAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Tumoflip Studio", id: "main") {
            StudioRootView(state: state)
                .frame(minWidth: 1040, minHeight: 680)
                .task { state.start() }
        }
        .defaultSize(width: 1280, height: 780)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Workspace") {
                ForEach(WorkspaceSection.allCases) { section in
                    Button(section.title) { state.selection = section }
                }
            }
        }

        MenuBarExtra("Tumoflip Studio", systemImage: "externaldrive.connected.to.line.below") {
            StudioMenuBarView(state: state)
        }
    }
}
