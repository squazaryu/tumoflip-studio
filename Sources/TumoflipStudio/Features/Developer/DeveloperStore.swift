import Foundation
import TumoflipFapCore

@MainActor
final class DeveloperStore: ObservableObject {
    @Published var firmwarePath = FapBuilderService.defaultFirmwareRoot.path
    @Published var appSourcePath = ""
    @Published var usbPort = "auto"
    @Published private(set) var status = "Ready"
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false

    private let service = FapBuilderService()
    private weak var transportCoordinator: TransportCoordinator?
    private let activityLog: ActivityLogStore
    private let transportOwner = "FAP Builder"

    init(transportCoordinator: TransportCoordinator, activityLog: ActivityLogStore) {
        self.transportCoordinator = transportCoordinator
        self.activityLog = activityLog
    }

    func inspectFirmware() {
        let firmwareURL = URL(fileURLWithPath: firmwarePath)
        run(title: "Inspecting firmware", requiresUSB: false) { service, logger in
            try service.firmwareInfo(firmwareRoot: firmwareURL).formattedText
        }
    }

    func readDeviceInfo() {
        let firmwareURL = URL(fileURLWithPath: firmwarePath)
        let port = usbPort
        run(title: "Reading Flipper", requiresUSB: true) { service, logger in
            try service.readUSBDeviceInfo(
                firmwareRoot: firmwareURL,
                port: port,
                logger: logger
            ).formattedText
        }
    }

    func buildReport(includeDevice: Bool) {
        guard !appSourcePath.isEmpty else {
            status = "Select a FAP source directory"
            return
        }
        let appURL = URL(fileURLWithPath: appSourcePath)
        let firmwareURL = URL(fileURLWithPath: firmwarePath)
        let port = usbPort
        run(title: "Building compatibility report", requiresUSB: includeDevice) { service, logger in
            try service.buildCompatibilityReport(
                appDir: appURL,
                firmwareRoot: firmwareURL,
                includeUSBDevice: includeDevice,
                usbPort: port,
                logger: logger
            ).formattedText
        }
    }

    func buildAndRun() {
        guard !appSourcePath.isEmpty else {
            status = "Select a FAP source directory"
            return
        }
        let appURL = URL(fileURLWithPath: appSourcePath)
        let firmwareURL = URL(fileURLWithPath: firmwarePath)
        let port = usbPort
        run(title: "Building and launching FAP", requiresUSB: true) { service, logger in
            try service.buildAndRunOnConnectedFlipper(
                appDir: appURL,
                firmwareRoot: firmwareURL,
                usbPort: port,
                logger: logger
            ).formattedText
        }
    }

    func clearOutput() {
        output = ""
        status = "Ready"
    }

    private func run(
        title: String,
        requiresUSB: Bool,
        operation: @escaping @Sendable (FapBuilderService, @escaping @Sendable (String) -> Void) throws -> String
    ) {
        guard !isRunning else { return }
        if requiresUSB,
           transportCoordinator?.acquire(.flipperUSB, owner: transportOwner) == false {
            status = transportCoordinator?.lastConflict ?? "Flipper USB is busy"
            return
        }

        let service = self.service
        isRunning = true
        status = title
        output = ""
        activityLog.append(title, source: transportOwner)

        let logger: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try operation(service, logger)
                }.value
                append(result)
                status = "Completed"
                activityLog.append("Completed", source: transportOwner)
            } catch {
                status = error.localizedDescription
                append("Error: \(error.localizedDescription)")
                activityLog.append(error.localizedDescription, source: transportOwner, level: .error)
            }
            isRunning = false
            if requiresUSB {
                transportCoordinator?.release(.flipperUSB, owner: transportOwner)
            }
        }
    }

    private func append(_ line: String) {
        guard !line.isEmpty else { return }
        if !output.isEmpty { output += "\n" }
        output += line
    }
}
