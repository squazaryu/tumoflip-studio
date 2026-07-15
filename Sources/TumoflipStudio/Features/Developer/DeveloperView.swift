import AppKit
import SwiftUI

struct DeveloperView: View {
    @ObservedObject var store: DeveloperStore

    var body: some View {
        VStack(spacing: 0) {
            StudioPageHeader(
                title: "FAP Developer",
                subtitle: store.status,
                systemImage: "hammer"
            ) {
                if store.isRunning { ProgressView().controlSize(.small) }
                Button("Clear", systemImage: "trash", action: store.clearOutput)
                    .disabled(store.isRunning || store.output.isEmpty)
            }

            Divider()

            VStack(alignment: .leading, spacing: StudioLayout.sectionSpacing) {
                StudioPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        StudioSectionHeader(title: "Build Configuration", systemImage: "slider.horizontal.3")
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                Text("Firmware")
                                TextField("Firmware checkout", text: $store.firmwarePath)
                                Button { chooseDirectory(for: $store.firmwarePath) } label: {
                                    Image(systemName: "folder")
                                }
                                .help("Choose firmware checkout")
                            }
                            GridRow {
                                Text("FAP source")
                                TextField("Directory containing application.fam", text: $store.appSourcePath)
                                Button { chooseDirectory(for: $store.appSourcePath) } label: {
                                    Image(systemName: "folder")
                                }
                                .help("Choose FAP source")
                            }
                            GridRow {
                                Text("USB port")
                                TextField("auto", text: $store.usbPort)
                                Color.clear.frame(width: 28, height: 1)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }

                HStack(spacing: 10) {
                    Button("Inspect SDK", systemImage: "doc.text.magnifyingglass", action: store.inspectFirmware)
                    Button("USB Info", systemImage: "cable.connector", action: store.readDeviceInfo)
                    Button("Build Report", systemImage: "checkmark.seal") {
                        store.buildReport(includeDevice: true)
                    }
                    Spacer()
                    Button("Build & Run", systemImage: "play.fill", action: store.buildAndRun)
                        .buttonStyle(.borderedProminent)
                }
                .disabled(store.isRunning)

                VStack(alignment: .leading, spacing: 8) {
                    StudioSectionHeader(title: "Build Output", systemImage: "terminal")
                    StudioConsole(
                        text: store.output,
                        placeholder: "Build output will appear here.",
                        minHeight: 260
                    )
                }
            }
            .padding(StudioLayout.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func chooseDirectory(for binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }
}
