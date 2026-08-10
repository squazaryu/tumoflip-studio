import SwiftUI
import TumoflipDeviceKit

struct DeviceManagerView: View {
    @ObservedObject var store: DeviceManagerStore

    var body: some View {
        VStack(spacing: 0) {
            StudioPageHeader(
                title: "Device Manager",
                subtitle: "Your Flipper, files and applications",
                systemImage: "externaldrive.connected.to.line.below"
            ) {
                headerActions
            }

            Divider()

            if store.connectionState.isConnected {
                connectedContent
            } else {
                disconnectedContent
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button("Refresh", systemImage: "arrow.clockwise") {
                store.refreshDevices()
            }
            .disabled(store.connectionState == .connecting)

            if store.connectionState.isConnected {
                Button("Disconnect", systemImage: "cable.connector.slash") {
                    store.disconnect()
                }
            } else {
                Button("Connect", systemImage: "cable.connector") {
                    store.connect()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.selectedDevice == nil || store.connectionState == .connecting)
            }
        }
    }

    private var disconnectedContent: some View {
        VStack(spacing: 20) {
            ContentUnavailableView {
                Label("Connect your Flipper", systemImage: "externaldrive.badge.plus")
            } description: {
                Text("Device Manager uses a read-only USB session in this phase. It will not change files or firmware.")
            }

            StudioPanel {
                VStack(alignment: .leading, spacing: 12) {
                    StudioSectionHeader(title: "USB device", systemImage: "cable.connector")

                    Picker("Device", selection: $store.selectedDeviceID) {
                        Text("No device selected").tag(FlipperUSBDevice.ID?.none)
                        ForEach(store.devices) { device in
                            Text(device.displayName).tag(Optional(device.id))
                        }
                    }
                    .frame(maxWidth: 520)

                    HStack(spacing: 8) {
                        if store.connectionState == .connecting {
                            ProgressView().controlSize(.small)
                        }
                        Text(store.message)
                            .font(.callout)
                            .foregroundStyle(messageColor)
                    }
                }
            }
            .frame(maxWidth: 620)
        }
        .padding(StudioLayout.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectedContent: some View {
        VStack(spacing: 0) {
            deviceSummary
            Divider()

            NavigationSplitView {
                volumeSidebar
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
            } detail: {
                fileBrowser
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var deviceSummary: some View {
        HStack(spacing: 18) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(store.snapshot?.hardware ?? "Flipper Zero")
                    .font(.headline)
                Text(store.snapshot?.firmware.nonEmpty ?? "Firmware information unavailable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            summaryValue("API", store.snapshot?.apiVersion ?? "—")
            summaryValue("Commit", store.snapshot?.commit.map { String($0.prefix(8)) } ?? "—")
            summaryValue("Battery", store.snapshot?.batteryLevel.map { "\($0)%" } ?? "—")
        }
        .padding(.horizontal, StudioLayout.pagePadding)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var volumeSidebar: some View {
        List(selection: Binding(
            get: { store.currentPath.hasPrefix("/int") ? "/int" : "/ext" },
            set: { if let path = $0 { store.openRoot(path) } }
        )) {
            Section("Device") {
                volumeRow(path: "/ext", title: "SD Card", icon: "sdcard")
                volumeRow(path: "/int", title: "Internal", icon: "memorychip")
            }

            Section("Coming next") {
                Label("Applications", systemImage: "square.grid.3x3")
                    .foregroundStyle(.secondary)
                Label("Marketplace", systemImage: "bag")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    private var fileBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Up", systemImage: "arrow.up") { store.goUp() }
                    .labelStyle(.iconOnly)
                    .disabled(store.currentPath == "/ext" || store.currentPath == "/int")
                Text(store.currentPath)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer()
                if store.isLoadingDirectory {
                    ProgressView().controlSize(.small)
                }
                Button("Reload", systemImage: "arrow.clockwise") { store.reloadDirectory() }
                    .labelStyle(.iconOnly)
                    .disabled(store.isLoadingDirectory)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if store.entries.isEmpty, !store.isLoadingDirectory {
                ContentUnavailableView(
                    "Empty folder",
                    systemImage: "folder",
                    description: Text(store.message)
                )
            } else {
                List(selection: $store.selectedEntryID) {
                    ForEach(store.entries) { entry in
                        fileRow(entry)
                            .tag(entry.id)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            selectionBar
        }
    }

    private func volumeRow(path: String, title: String, icon: String) -> some View {
        let volume = store.volumes.first { $0.path == path }
        return VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
            if let volume {
                Text(Self.storageText(volume))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(path)
    }

    private func fileRow(_ entry: FlipperFileEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(entry.name)
                .lineLimit(1)
            Spacer()
            if !entry.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if entry.isDirectory {
                Button("Open", systemImage: "chevron.right") {
                    store.open(entry)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.open(entry) }
    }

    private var selectionBar: some View {
        HStack {
            if let entry = store.selectedEntry {
                Label(entry.isDirectory ? "Folder" : "File", systemImage: entry.isDirectory ? "folder" : "doc")
                Text(entry.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(store.message)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Read only")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func summaryValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).textSelection(.enabled)
        }
        .frame(minWidth: 74, alignment: .leading)
    }

    private var messageColor: Color {
        if case .failed = store.connectionState { return .red }
        return .secondary
    }

    private static func storageText(_ volume: FlipperStorageVolume) -> String {
        let used = volume.totalSpace > volume.freeSpace ? volume.totalSpace - volume.freeSpace : 0
        let usedText = ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .file)
        let totalText = ByteCountFormatter.string(fromByteCount: Int64(volume.totalSpace), countStyle: .file)
        return "\(usedText) of \(totalText)"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
