import AppKit
import SwiftUI

@MainActor
final class TumoflipStudioAppDelegate: NSObject, NSApplicationDelegate {
    private weak var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.stop()
    }

    func configure(state: AppState) {
        self.state = state
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
                .task {
                    appDelegate.configure(state: state)
                    state.start()
                }
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

        MenuBarExtra {
            StudioMenuBarView(state: state)
                .task {
                    appDelegate.configure(state: state)
                    state.start()
                }
        } label: {
            StudioMenuBarLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}
