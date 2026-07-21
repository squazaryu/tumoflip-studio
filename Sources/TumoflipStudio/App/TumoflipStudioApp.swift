import AppKit
import SwiftUI

@MainActor
final class TumoflipStudioAppDelegate: NSObject, NSApplicationDelegate {
    private weak var state: AppState?
    private var fullTerminationRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard fullTerminationRequested else {
            sender.windows
                .filter { $0.isVisible && $0.canBecomeMain }
                .forEach { $0.performClose(nil) }
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        state?.stop()
    }

    func configure(state: AppState) {
        self.state = state
    }

    func requestFullTermination() {
        fullTerminationRequested = true
        NSApp.terminate(nil)
    }

    @objc private func workspaceWillPowerOff(_ notification: Notification) {
        fullTerminationRequested = true
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
            StudioMenuBarView(state: state) {
                appDelegate.requestFullTermination()
            }
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
