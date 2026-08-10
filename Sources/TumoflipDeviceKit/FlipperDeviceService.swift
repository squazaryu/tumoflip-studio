import Foundation

public struct FlipperFileEntry: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: UInt32

    public init(name: String, path: String, isDirectory: Bool, size: UInt32) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
    }
}

public struct FlipperStorageVolume: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let title: String
    public let totalSpace: UInt64
    public let freeSpace: UInt64

    public init(path: String, title: String, totalSpace: UInt64, freeSpace: UInt64) {
        self.path = path
        self.title = title
        self.totalSpace = totalSpace
        self.freeSpace = freeSpace
    }
}

public struct FlipperDeviceSnapshot: Equatable, Sendable {
    public let properties: [String: String]

    public init(properties: [String: String]) {
        self.properties = properties
    }

    public var name: String {
        properties["hardware_name"].flatMap { $0.isEmpty ? nil : $0 } ?? "Flipper Zero"
    }

    public var hardware: String {
        guard let version = properties["hardware_ver"], !version.isEmpty else { return name }
        return "\(name) v\(version)"
    }

    public var firmware: String {
        let origin = properties["firmware_origin_fork"]
            ?? properties["firmware_origin"]
            ?? properties["firmware_branch"]
        let version = properties["firmware_version"]
        return [origin, version]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
            .joined(separator: " ")
    }

    public var commit: String? {
        properties["firmware_commit"].flatMap { $0.isEmpty ? nil : $0 }
    }

    public var apiVersion: String? {
        guard let major = properties["firmware_api_major"] else { return nil }
        return "\(major).\(properties["firmware_api_minor"] ?? "0")"
    }

    public var batteryLevel: Int? {
        properties["charge_level"].flatMap(Int.init)
    }
}

public enum FlipperPathError: Error, LocalizedError, Equatable {
    case invalidPath(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            "Invalid Flipper path: \(path)"
        }
    }
}

public enum FlipperPath {
    public static func normalize(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else { throw FlipperPathError.invalidPath(path) }
        if components.isEmpty { return "/" }
        return "/" + components.joined(separator: "/")
    }

    public static func join(directory: String, name: String) throws -> String {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw FlipperPathError.invalidPath(name)
        }
        let directory = try normalize(directory)
        return directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    public static func parent(of path: String) throws -> String {
        let normalized = try normalize(path)
        guard normalized != "/" else { return "/" }
        let parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().path
        return try normalize(parent)
    }
}

public final class FlipperDeviceService: Sendable {
    private let rpc: FlipperRPCSession

    public init(rpc: FlipperRPCSession) {
        self.rpc = rpc
    }

    public func snapshot() async throws -> FlipperDeviceSnapshot {
        let device = try await properties { main in
            main.content = .systemDeviceInfoRequest(PBSystem_DeviceInfoRequest())
        }
        let power = try await properties { main in
            main.content = .systemPowerInfoRequest(PBSystem_PowerInfoRequest())
        }
        return FlipperDeviceSnapshot(properties: device.merging(power) { first, _ in first })
    }

    public func storageVolume(path: String, title: String) async throws -> FlipperStorageVolume {
        let normalized = try FlipperPath.normalize(path)
        let responses = try await rpc.command { main in
            var request = PBStorage_InfoRequest()
            request.path = normalized
            main.content = .storageInfoRequest(request)
        }
        guard let info = responses.compactMap({ response -> PBStorage_InfoResponse? in
            if case .storageInfoResponse(let value) = response.content { return value }
            return nil
        }).first else {
            throw FlipperRPCError.invalidResponse
        }
        return FlipperStorageVolume(
            path: normalized,
            title: title,
            totalSpace: info.totalSpace,
            freeSpace: info.freeSpace
        )
    }

    public func list(path: String) async throws -> [FlipperFileEntry] {
        let normalized = try FlipperPath.normalize(path)
        let responses = try await rpc.command { main in
            var request = PBStorage_ListRequest()
            request.path = normalized
            main.content = .storageListRequest(request)
        }

        var entries: [FlipperFileEntry] = []
        for response in responses {
            guard case .storageListResponse(let list) = response.content else { continue }
            for file in list.file where file.name != "." && file.name != ".." {
                entries.append(FlipperFileEntry(
                    name: file.name,
                    path: try FlipperPath.join(directory: normalized, name: file.name),
                    isDirectory: file.type == .dir,
                    size: file.size
                ))
            }
        }
        return Self.sorted(entries)
    }

    public static func sorted(_ entries: [FlipperFileEntry]) -> [FlipperFileEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func properties(
        _ configure: @escaping @Sendable (inout PB_Main) -> Void
    ) async throws -> [String: String] {
        let responses = try await rpc.command(configure)
        var output: [String: String] = [:]
        for response in responses {
            switch response.content {
            case .systemDeviceInfoResponse(let value):
                if !value.key.isEmpty { output[value.key] = value.value }
            case .systemPowerInfoResponse(let value):
                if !value.key.isEmpty { output[value.key] = value.value }
            default:
                continue
            }
        }
        return output
    }
}
