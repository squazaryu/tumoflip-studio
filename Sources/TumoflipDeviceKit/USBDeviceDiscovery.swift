import Foundation

public struct FlipperUSBDevice: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

public enum USBDeviceDiscovery {
    public static func discover(in directory: URL = URL(fileURLWithPath: "/dev")) -> [FlipperUSBDevice] {
        let paths = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.map(\.path) ?? []

        return flipperDevices(in: paths)
    }

    public static func flipperDevices(in paths: [String]) -> [FlipperUSBDevice] {
        paths.compactMap { path in
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            guard name.hasPrefix("cu."), name.contains("usbmodem"), name.contains("flip") else {
                return nil
            }
            return FlipperUSBDevice(path: path)
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
