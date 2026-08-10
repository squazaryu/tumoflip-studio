import Foundation
import TumoflipDeviceKit

enum DeviceManagerConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed: "Connection failed"
        }
    }

    var isConnected: Bool {
        self == .connected
    }
}

@MainActor
final class DeviceManagerStore: ObservableObject {
    @Published private(set) var devices: [FlipperUSBDevice] = []
    @Published var selectedDeviceID: FlipperUSBDevice.ID?
    @Published private(set) var connectionState: DeviceManagerConnectionState = .disconnected
    @Published private(set) var snapshot: FlipperDeviceSnapshot?
    @Published private(set) var volumes: [FlipperStorageVolume] = []
    @Published private(set) var currentPath = "/ext"
    @Published private(set) var entries: [FlipperFileEntry] = []
    @Published var selectedEntryID: FlipperFileEntry.ID?
    @Published private(set) var isLoadingDirectory = false
    @Published private(set) var message = "Connect a Flipper over USB to begin."

    private let transportCoordinator: TransportCoordinator
    private let activityLog: ActivityLogStore
    private let owner = "Device Manager"
    private var rpc: FlipperRPCSession?
    private var service: FlipperDeviceService?
    private var connectionTask: Task<Void, Never>?
    private var directoryTask: Task<Void, Never>?

    init(transportCoordinator: TransportCoordinator, activityLog: ActivityLogStore) {
        self.transportCoordinator = transportCoordinator
        self.activityLog = activityLog
        refreshDevices()
    }

    var selectedDevice: FlipperUSBDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var selectedEntry: FlipperFileEntry? {
        entries.first { $0.id == selectedEntryID }
    }

    func refreshDevices() {
        transportCoordinator.refreshDevices()
        devices = USBDeviceDiscovery.discover()
        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first?.id
        }
        if devices.isEmpty, connectionState == .disconnected {
            message = "No Flipper USB device found. Connect it with a data cable and refresh."
        }
    }

    func connect() {
        guard connectionTask == nil, !connectionState.isConnected else { return }
        guard let device = selectedDevice else {
            message = "Select a detected Flipper USB device."
            return
        }
        guard transportCoordinator.acquire(.flipperUSB, owner: owner) else {
            message = transportCoordinator.lastConflict ?? "Flipper USB is busy."
            return
        }

        connectionState = .connecting
        message = "Starting a read-only RPC session on \(device.displayName)."
        activityLog.append("Connecting to \(device.path)", source: owner)

        let transport = USBSerialFlipperTransport(path: device.path)
        let rpc = FlipperRPCSession(transport: transport)
        let service = FlipperDeviceService(rpc: rpc)
        self.rpc = rpc
        self.service = service

        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await rpc.start()
                try Task.checkCancellation()

                let snapshot = try await service.snapshot()
                var volumes: [FlipperStorageVolume] = []
                if let sd = try? await service.storageVolume(path: "/ext", title: "SD Card") {
                    volumes.append(sd)
                }
                if let internalStorage = try? await service.storageVolume(path: "/int", title: "Internal") {
                    volumes.append(internalStorage)
                }
                let entries = try await service.list(path: "/ext")
                try Task.checkCancellation()

                self.snapshot = snapshot
                self.volumes = volumes
                self.currentPath = "/ext"
                self.entries = entries
                self.selectedEntryID = nil
                self.connectionState = .connected
                self.message = "Read-only USB session ready."
                self.activityLog.append("Read-only RPC session ready", source: self.owner)
            } catch is CancellationError {
                await rpc.stop()
                self.finishDisconnect(message: "Connection cancelled.")
            } catch {
                await rpc.stop()
                self.connectionState = .failed(error.localizedDescription)
                self.message = error.localizedDescription
                self.activityLog.append(error.localizedDescription, source: self.owner, level: .error)
                self.transportCoordinator.release(.flipperUSB, owner: self.owner)
                self.rpc = nil
                self.service = nil
            }
            self.connectionTask = nil
        }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        directoryTask?.cancel()
        directoryTask = nil
        let rpc = self.rpc
        self.rpc = nil
        service = nil

        Task { [weak self] in
            await rpc?.stop()
            self?.finishDisconnect(message: "Disconnected.")
        }
    }

    func stop() {
        disconnect()
    }

    func openRoot(_ path: String) {
        loadDirectory(path)
    }

    func open(_ entry: FlipperFileEntry) {
        if entry.isDirectory {
            loadDirectory(entry.path)
        } else {
            selectedEntryID = entry.id
        }
    }

    func goUp() {
        guard let parent = try? FlipperPath.parent(of: currentPath), parent != "/" else { return }
        loadDirectory(parent)
    }

    func reloadDirectory() {
        loadDirectory(currentPath)
    }

    func loadDirectory(_ path: String) {
        guard connectionState.isConnected, let service else { return }
        directoryTask?.cancel()
        isLoadingDirectory = true
        selectedEntryID = nil

        directoryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let normalized = try FlipperPath.normalize(path)
                let entries = try await service.list(path: normalized)
                try Task.checkCancellation()
                self.currentPath = normalized
                self.entries = entries
                self.message = entries.isEmpty ? "This folder is empty." : "Read-only browsing."
            } catch is CancellationError {
                return
            } catch {
                self.message = error.localizedDescription
                self.activityLog.append(error.localizedDescription, source: self.owner, level: .warning)
            }
            self.isLoadingDirectory = false
            self.directoryTask = nil
        }
    }

    private func finishDisconnect(message: String) {
        snapshot = nil
        volumes = []
        entries = []
        selectedEntryID = nil
        isLoadingDirectory = false
        connectionState = .disconnected
        self.message = message
        transportCoordinator.release(.flipperUSB, owner: owner)
        activityLog.append(message, source: owner)
    }
}
