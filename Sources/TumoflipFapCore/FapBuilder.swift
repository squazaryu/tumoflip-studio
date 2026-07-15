import Foundation

public struct FapManifest: Equatable, Sendable {
    public let appid: String
    public let name: String
    public let entryPoint: String
    public let category: String
    public let version: String?
    public let distPath: String?

    public init(
        appid: String,
        name: String,
        entryPoint: String,
        category: String,
        version: String?,
        distPath: String?
    ) {
        self.appid = appid
        self.name = name
        self.entryPoint = entryPoint
        self.category = category
        self.version = version
        self.distPath = distPath
    }
}

public struct BuildResult: Equatable, Sendable {
    public let manifest: FapManifest
    public let fapURL: URL
    public let buildAPIVersion: String?
}

public struct FirmwareInfo: Equatable, Sendable {
    public let rootURL: URL
    public let origin: String
    public let targetHW: String
    public let distSuffix: String
    public let updateVersionString: String
    public let sdkAPIVersion: String

    public var formattedText: String {
        [
            "Firmware SDK",
            "firmware_root: \(rootURL.path)",
            "firmware_origin: \(origin)",
            "firmware_target: f\(targetHW)",
            "dist_suffix: \(distSuffix)",
            "update_version_string: \(updateVersionString)",
            "sdk_api_version: \(sdkAPIVersion)",
        ].joined(separator: "\n")
    }
}

public struct FlipperUSBDeviceInfo: Equatable, Sendable {
    public let port: String
    public let fields: [String: String]

    public var firmwareVersion: String? { fields["firmware_version"] }
    public var firmwareOrigin: String? { fields["firmware_origin_fork"] ?? fields["firmware_origin"] }
    public var hardwareTarget: String? { fields["firmware_target"] ?? fields["hardware_target"] }
    public var firmwareCommit: String? { fields["firmware_commit"] }
    public var firmwareCommitDirty: String? { fields["firmware_commit_dirty"] }

    public var firmwareAPIVersion: String? {
        guard let major = fields["firmware_api_major"], let minor = fields["firmware_api_minor"] else {
            return fields["firmware_api"]
        }
        return "\(major).\(minor)"
    }

    public var formattedText: String {
        var lines = [
            "USB device",
            "usb_port: \(port)",
            "device_firmware_origin: \(firmwareOrigin ?? "-")",
            "device_firmware_version: \(firmwareVersion ?? "-")",
            "device_hardware_target: \(hardwareTarget ?? "-")",
            "device_firmware_api: \(firmwareAPIVersion ?? "-")",
        ]
        if let firmwareCommit, !firmwareCommit.isEmpty {
            lines.append("device_firmware_commit: \(firmwareCommit)")
        }
        if let firmwareCommitDirty, !firmwareCommitDirty.isEmpty {
            lines.append("device_firmware_dirty: \(firmwareCommitDirty)")
        }
        return lines.joined(separator: "\n")
    }

    public func compatibilityFindings(against firmware: FirmwareInfo) -> [String] {
        var findings: [String] = []
        if let firmwareOrigin, firmwareOrigin != firmware.origin {
            findings.append("origin \(firmwareOrigin) != SDK \(firmware.origin)")
        }
        if let firmwareVersion, firmwareVersion != firmware.distSuffix {
            findings.append("version \(firmwareVersion) != SDK \(firmware.distSuffix)")
        }
        if let hardwareTarget, hardwareTarget != firmware.targetHW {
            findings.append("target f\(hardwareTarget) != SDK f\(firmware.targetHW)")
        }
        if let firmwareAPIVersion, firmwareAPIVersion != firmware.sdkAPIVersion {
            findings.append("API \(firmwareAPIVersion) != SDK \(firmware.sdkAPIVersion)")
        }
        if firmwareCommitDirty == "true" || firmwareCommitDirty == "1" {
            findings.append("device firmware reports dirty commit")
        }
        return findings
    }
}

public struct CompatibilityReport: Equatable, Sendable {
    public let firmware: FirmwareInfo
    public let device: FlipperUSBDeviceInfo?
    public let manifest: FapManifest
    public let fapURL: URL
    public let fapSizeBytes: UInt64
    public let installRelativePath: String
    public let buildAPIVersion: String?

    public var formattedText: String {
        let sizeText = ByteCountFormatter.string(
            fromByteCount: Int64(fapSizeBytes),
            countStyle: .file
        )
        let lines = [
            "Compatibility report",
            "firmware_root: \(firmware.rootURL.path)",
            "firmware_origin: \(firmware.origin)",
            "firmware_target: f\(firmware.targetHW)",
            "dist_suffix: \(firmware.distSuffix)",
            "update_version_string: \(firmware.updateVersionString)",
            "sdk_api_version: \(firmware.sdkAPIVersion)",
            "fbt_api_version: \(buildAPIVersion ?? "not reported")",
        ] + deviceReportLines + [
            "appid: \(manifest.appid)",
            "name: \(manifest.name)",
            "entry_point: \(manifest.entryPoint)",
            "category: \(manifest.category)",
            "version: \(manifest.version ?? "-")",
            "dist_path: \(manifest.distPath ?? "-")",
            "install_path: \(installRelativePath)",
            "fap_path: \(fapURL.path)",
            "fap_size: \(fapSizeBytes) bytes (\(sizeText))",
        ]
        return lines.joined(separator: "\n")
    }

    private var deviceReportLines: [String] {
        guard let device else { return ["device: not checked"] }
        let findings = device.compatibilityFindings(against: firmware)
        return [
            "usb_port: \(device.port)",
            "device_firmware_origin: \(device.firmwareOrigin ?? "-")",
            "device_firmware_version: \(device.firmwareVersion ?? "-")",
            "device_hardware_target: \(device.hardwareTarget.map { "f\($0)" } ?? "-")",
            "device_firmware_api: \(device.firmwareAPIVersion ?? "-")",
            "device_firmware_commit: \(device.firmwareCommit ?? "-")",
            "device_firmware_dirty: \(device.firmwareCommitDirty ?? "-")",
            "device_sdk_match: \(findings.isEmpty ? "yes" : "no")",
        ] + findings.map { "device_sdk_mismatch: \($0)" }
    }
}

public enum FapBuilderError: LocalizedError, Equatable {
    case missingApplicationFam(URL)
    case malformedManifest(String)
    case invalidAppID(String)
    case firmwareRootMissing(URL)
    case fbtMissing(URL)
    case sourceDirectoryMissing(URL)
    case appSlotOccupied(URL)
    case appSlotPointsElsewhere(slot: URL, expected: URL, actual: String)
    case fbtFailed(command: String, exitCode: Int32, output: String)
    case builtFapNotFound(String)
    case firmwareMetadataMissing(URL, String)
    case usbDeviceInfoFailed(String)
    case deviceSDKMismatch([String])
    case sdRootMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .missingApplicationFam(let url):
            return "application.fam was not found at \(url.path)."
        case .malformedManifest(let reason):
            return "application.fam is incomplete: \(reason)."
        case .invalidAppID(let appid):
            return "Invalid appid '\(appid)'. Use lowercase latin letters, digits, and underscores; it must start with a letter."
        case .firmwareRootMissing(let url):
            return "Firmware root does not exist: \(url.path)."
        case .fbtMissing(let url):
            return "FBT script was not found: \(url.path)."
        case .sourceDirectoryMissing(let url):
            return "Source directory does not exist: \(url.path)."
        case .appSlotOccupied(let url):
            return "Firmware applications_user slot is occupied by a real directory: \(url.path)."
        case .appSlotPointsElsewhere(let slot, let expected, let actual):
            return "App slot \(slot.path) is a symlink to \(actual), not \(expected.path)."
        case .fbtFailed(let command, let exitCode, let output):
            return "Command failed (\(exitCode)): \(command)\n\(output)"
        case .builtFapNotFound(let appid):
            return "Built .fap for appid '\(appid)' was not found in firmware build output."
        case .firmwareMetadataMissing(let url, let detail):
            return "Firmware metadata is missing or unreadable at \(url.path): \(detail)."
        case .usbDeviceInfoFailed(let detail):
            return "Could not read Flipper USB device info: \(detail)."
        case .deviceSDKMismatch(let findings):
            return "Connected Flipper does not match the selected SDK:\n"
                + findings.map { "- \($0)" }.joined(separator: "\n")
        case .sdRootMissing(let url):
            return "SD root does not exist: \(url.path)."
        }
    }
}

public struct FapBuildOptions: Equatable, Sendable {
    public var compact: Bool
    public var debug: Bool

    public init(compact: Bool = true, debug: Bool = false) {
        self.compact = compact
        self.debug = debug
    }
}

public final class FapBuilderService: @unchecked Sendable {
    public static let defaultFirmwareRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects/Flipper/unleashed-firmware", isDirectory: true)

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func parseManifest(appDir: URL) throws -> FapManifest {
        let famURL = appDir.appendingPathComponent("application.fam")
        guard fileManager.fileExists(atPath: famURL.path) else {
            throw FapBuilderError.missingApplicationFam(famURL)
        }

        let text = try String(contentsOf: famURL, encoding: .utf8)
        guard let appid = stringField("appid", in: text), !appid.isEmpty else {
            throw FapBuilderError.malformedManifest("missing appid")
        }
        guard isValidAppID(appid) else {
            throw FapBuilderError.invalidAppID(appid)
        }
        guard let name = stringField("name", in: text), !name.isEmpty else {
            throw FapBuilderError.malformedManifest("missing name")
        }
        guard let entryPoint = stringField("entry_point", in: text), !entryPoint.isEmpty else {
            throw FapBuilderError.malformedManifest("missing entry_point")
        }

        return FapManifest(
            appid: appid,
            name: name,
            entryPoint: entryPoint,
            category: stringField("fap_category", in: text) ?? "Tools",
            version: stringField("fap_version", in: text),
            distPath: stringField("fap_dist_path", in: text)
        )
    }

    public func firmwareInfo(firmwareRoot: URL = FapBuilderService.defaultFirmwareRoot) throws -> FirmwareInfo {
        try validateFirmwareRoot(firmwareRoot)

        let fbtOptionsURL = firmwareRoot.appendingPathComponent("fbt_options.py")
        guard fileManager.fileExists(atPath: fbtOptionsURL.path) else {
            throw FapBuilderError.firmwareMetadataMissing(fbtOptionsURL, "fbt_options.py was not found")
        }

        let text = try String(contentsOf: fbtOptionsURL, encoding: .utf8)
        let environment = ProcessInfo.processInfo.environment
        let distSuffix = environment["DIST_SUFFIX"]
            ?? pythonStringConstant("DIST_SUFFIX", in: text)
            ?? "local"
        let updateVersionString = environment["UPDATE_VERSION_STRING"]
            ?? pythonStringConstant("UPDATE_VERSION_STRING", in: text)
            ?? distSuffix

        return FirmwareInfo(
            rootURL: firmwareRoot.standardizedFileURL,
            origin: environment["FIRMWARE_ORIGIN"]
                ?? pythonStringConstant("FIRMWARE_ORIGIN", in: text)
                ?? "-",
            targetHW: environment["TARGET_HW"]
                ?? pythonLiteralConstant("TARGET_HW", in: text)
                ?? "7",
            distSuffix: distSuffix,
            updateVersionString: updateVersionString,
            sdkAPIVersion: try readSDKAPIVersion(firmwareRoot: firmwareRoot)
        )
    }

    public func readUSBDeviceInfo(
        firmwareRoot: URL = FapBuilderService.defaultFirmwareRoot,
        port: String = "auto",
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> FlipperUSBDeviceInfo {
        try validateFirmwareRoot(firmwareRoot)
        let scriptsPath = firmwareRoot.appendingPathComponent("scripts")
        guard fileManager.fileExists(atPath: scriptsPath.path) else {
            throw FapBuilderError.firmwareMetadataMissing(scriptsPath, "scripts directory was not found")
        }

        let python = preferredPythonCommand()
        logger("Reading Flipper USB device_info (\(port)) using \(python.displayName)")
        let output = try ProcessRunner.run(
            executable: python.executable,
            arguments: ["-c", Self.deviceInfoPythonScript, port],
            currentDirectory: firmwareRoot,
            environment: ["PYTHONPATH": scriptsPath.path],
            timeoutSeconds: 12
        )
        if !output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard output.exitCode == 0 else {
            throw FapBuilderError.usbDeviceInfoFailed(output.stderr + output.stdout)
        }
        let info = try parseUSBDeviceInfoJSON(output.stdout)
        logger(info.formattedText)
        return info
    }

    public func createTemplate(at appDir: URL, appid: String, name: String? = nil) throws -> FapManifest {
        guard isValidAppID(appid) else {
            throw FapBuilderError.invalidAppID(appid)
        }

        try fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        let appName = (name?.isEmpty == false) ? name! : title(from: appid)
        let entryPoint = "\(appid)_app"
        let logTag = title(from: appid).replacingOccurrences(of: " ", with: "")
        let fam = """
        App(
            appid="\(appid)",
            name="\(appName)",
            apptype=FlipperAppType.EXTERNAL,
            entry_point="\(entryPoint)",
            requires=["gui", "notification"],
            stack_size=2 * 1024,
            fap_category="Tools",
            fap_version="0.1",
            fap_author="tumoflip",
            fap_description="Minimal Tumoflip FAP template.",
        )
        """
        let cSource = """
        #include <furi.h>
        #include <gui/gui.h>
        #include <gui/view_port.h>
        #include <input/input.h>

        typedef struct {
            FuriMutex* mutex;
            bool running;
        } \(appid)_state_t;

        static void \(appid)_draw(Canvas* canvas, void* context) {
            UNUSED(context);
            canvas_clear(canvas);
            canvas_set_font(canvas, FontPrimary);
            canvas_draw_str(canvas, 3, 14, "\(appName)");
            canvas_set_font(canvas, FontSecondary);
            canvas_draw_str(canvas, 3, 32, "Built with Tumoflip");
            canvas_draw_str(canvas, 3, 47, "Press Back to exit");
        }

        static void \(appid)_input(InputEvent* event, void* context) {
            \(appid)_state_t* state = context;
            if((event->type == InputTypeShort) && (event->key == InputKeyBack)) {
                furi_mutex_acquire(state->mutex, FuriWaitForever);
                state->running = false;
                furi_mutex_release(state->mutex);
            }
        }

        int32_t \(entryPoint)(void* p) {
            UNUSED(p);
            FURI_LOG_I("\(logTag)", "Starting");

            \(appid)_state_t state = {
                .mutex = furi_mutex_alloc(FuriMutexTypeNormal),
                .running = true,
            };

            ViewPort* view_port = view_port_alloc();
            view_port_draw_callback_set(view_port, \(appid)_draw, &state);
            view_port_input_callback_set(view_port, \(appid)_input, &state);

            Gui* gui = furi_record_open(RECORD_GUI);
            gui_add_view_port(gui, view_port, GuiLayerFullscreen);

            while(true) {
                furi_mutex_acquire(state.mutex, FuriWaitForever);
                bool running = state.running;
                furi_mutex_release(state.mutex);
                if(!running) break;
                view_port_update(view_port);
                furi_delay_ms(100);
            }

            gui_remove_view_port(gui, view_port);
            furi_record_close(RECORD_GUI);
            view_port_free(view_port);
            furi_mutex_free(state.mutex);

            FURI_LOG_I("\(logTag)", "Stopped");
            return 0;
        }
        """

        try fam.write(to: appDir.appendingPathComponent("application.fam"), atomically: true, encoding: .utf8)
        try cSource.write(to: appDir.appendingPathComponent("\(appid).c"), atomically: true, encoding: .utf8)

        return try parseManifest(appDir: appDir)
    }

    @discardableResult
    public func build(
        appDir: URL,
        firmwareRoot: URL = FapBuilderService.defaultFirmwareRoot,
        options: FapBuildOptions = FapBuildOptions(),
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> BuildResult {
        let sourceDir = appDir.standardizedFileURL
        guard fileManager.fileExists(atPath: sourceDir.path) else {
            throw FapBuilderError.sourceDirectoryMissing(sourceDir)
        }
        try validateFirmwareRoot(firmwareRoot)
        let manifest = try parseManifest(appDir: sourceDir)

        let fbtOutput = try withAppSymlink(appDir: sourceDir, appid: manifest.appid, firmwareRoot: firmwareRoot) {
            let args = [
                "COMPACT=\(options.compact ? "1" : "0")",
                "DEBUG=\(options.debug ? "1" : "0")",
                "fap_\(manifest.appid)",
            ]
            return try runFBT(args: args, firmwareRoot: firmwareRoot, logger: logger)
        }

        let fapURL = try findBuiltFap(appid: manifest.appid, firmwareRoot: firmwareRoot)
        logger("Built \(fapURL.path)")
        return BuildResult(
            manifest: manifest,
            fapURL: fapURL,
            buildAPIVersion: apiVersion(fromFBTOutput: fbtOutput)
        )
    }

    @discardableResult
    public func buildCompatibilityReport(
        appDir: URL,
        firmwareRoot: URL = FapBuilderService.defaultFirmwareRoot,
        options: FapBuildOptions = FapBuildOptions(),
        includeUSBDevice: Bool = false,
        usbPort: String = "auto",
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> CompatibilityReport {
        let firmware = try firmwareInfo(firmwareRoot: firmwareRoot)
        let device = includeUSBDevice
            ? try readUSBDeviceInfo(firmwareRoot: firmwareRoot, port: usbPort, logger: logger)
            : nil
        let result = try build(appDir: appDir, firmwareRoot: firmwareRoot, options: options, logger: logger)
        let installPath = installRelativePath(
            for: result.manifest,
            fapFileName: result.fapURL.lastPathComponent
        )
        let attributes = try fileManager.attributesOfItem(atPath: result.fapURL.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0

        let report = CompatibilityReport(
            firmware: firmware,
            device: device,
            manifest: result.manifest,
            fapURL: result.fapURL,
            fapSizeBytes: size,
            installRelativePath: installPath,
            buildAPIVersion: result.buildAPIVersion
        )
        logger(report.formattedText)
        return report
    }

    @discardableResult
    public func installToSD(
        appDir: URL,
        firmwareRoot: URL = FapBuilderService.defaultFirmwareRoot,
        sdRoot: URL,
        options: FapBuildOptions = FapBuildOptions(),
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> URL {
        guard fileManager.fileExists(atPath: sdRoot.path) else {
            throw FapBuilderError.sdRootMissing(sdRoot)
        }

        let result = try build(appDir: appDir, firmwareRoot: firmwareRoot, options: options, logger: logger)
        let relativePath = installRelativePath(for: result.manifest, fapFileName: result.fapURL.lastPathComponent)
        let destination = sdRoot.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: result.fapURL, to: destination)
        logger("Installed \(destination.path)")
        return destination
    }

    public func launchOverUSB(
        appDir: URL,
        firmwareRoot: URL = FapBuilderService.defaultFirmwareRoot,
        options: FapBuildOptions = FapBuildOptions(),
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        let sourceDir = appDir.standardizedFileURL
        guard fileManager.fileExists(atPath: sourceDir.path) else {
            throw FapBuilderError.sourceDirectoryMissing(sourceDir)
        }
        try validateFirmwareRoot(firmwareRoot)
        let manifest = try parseManifest(appDir: sourceDir)

        try withAppSymlink(appDir: sourceDir, appid: manifest.appid, firmwareRoot: firmwareRoot) {
            let args = [
                "COMPACT=\(options.compact ? "1" : "0")",
                "DEBUG=\(options.debug ? "1" : "0")",
                "launch",
                "APPSRC=\(manifest.appid)",
            ]
            _ = try runFBT(args: args, firmwareRoot: firmwareRoot, logger: logger)
        }
    }

    @discardableResult
    public func buildAndRunOnConnectedFlipper(
        appDir: URL,
        firmwareRoot: URL = FapBuilderService.defaultFirmwareRoot,
        usbPort: String = "auto",
        options: FapBuildOptions = FapBuildOptions(),
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> CompatibilityReport {
        logger("Automatic USB build/run")
        let report = try buildCompatibilityReport(
            appDir: appDir,
            firmwareRoot: firmwareRoot,
            options: options,
            includeUSBDevice: true,
            usbPort: usbPort,
            logger: logger
        )
        guard let device = report.device else {
            throw FapBuilderError.usbDeviceInfoFailed("device_info was not read")
        }
        let findings = device.compatibilityFindings(against: report.firmware)
        guard findings.isEmpty else {
            throw FapBuilderError.deviceSDKMismatch(findings)
        }
        logger("Connected Flipper matches selected SDK.")
        try launchOverUSB(appDir: appDir, firmwareRoot: firmwareRoot, options: options, logger: logger)
        logger("Launched \(report.manifest.name) on \(device.port).")
        return report
    }

    public func installRelativePath(for manifest: FapManifest, fapFileName: String) -> String {
        if let distPath = manifest.distPath, !distPath.isEmpty {
            return distPath.replacingOccurrences(of: "{filename}", with: fapFileName)
        }
        let category = sanitizePathComponent(manifest.category.isEmpty ? "Tools" : manifest.category)
        return "apps/\(category)/\(fapFileName)"
    }

    private func validateFirmwareRoot(_ firmwareRoot: URL) throws {
        guard fileManager.fileExists(atPath: firmwareRoot.path) else {
            throw FapBuilderError.firmwareRootMissing(firmwareRoot)
        }
        let fbt = firmwareRoot.appendingPathComponent("fbt")
        guard fileManager.fileExists(atPath: fbt.path) else {
            throw FapBuilderError.fbtMissing(fbt)
        }
    }

    private func withAppSymlink<T>(
        appDir: URL,
        appid: String,
        firmwareRoot: URL,
        body: () throws -> T
    ) throws -> T {
        let applicationsUser = firmwareRoot.appendingPathComponent("applications_user")
        let slot = applicationsUser.appendingPathComponent(appid)
        let expected = appDir.standardizedFileURL.resolvingSymlinksInPath()

        var createdSymlink = false
        if fileManager.fileExists(atPath: slot.path) {
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: slot.path) {
                let resolvedDestination: URL
                if destination.hasPrefix("/") {
                    resolvedDestination = URL(fileURLWithPath: destination)
                } else {
                    resolvedDestination = slot.deletingLastPathComponent().appendingPathComponent(destination)
                }
                let actual = resolvedDestination.standardizedFileURL.resolvingSymlinksInPath()
                guard actual.path == expected.path else {
                    throw FapBuilderError.appSlotPointsElsewhere(
                        slot: slot,
                        expected: expected,
                        actual: actual.path
                    )
                }
            } else if slot.standardizedFileURL.resolvingSymlinksInPath().path != expected.path {
                throw FapBuilderError.appSlotOccupied(slot)
            }
        } else {
            try fileManager.createSymbolicLink(at: slot, withDestinationURL: expected)
            createdSymlink = true
        }

        defer {
            if createdSymlink {
                try? fileManager.removeItem(at: slot)
            }
        }

        return try body()
    }

    private func runFBT(
        args: [String],
        firmwareRoot: URL,
        logger: @escaping @Sendable (String) -> Void
    ) throws -> String {
        let command = "./fbt " + args.joined(separator: " ")
        logger(command)
        let output = try ProcessRunner.run(
            executable: firmwareRoot.appendingPathComponent("fbt"),
            arguments: args,
            currentDirectory: firmwareRoot
        )
        if !output.stdout.isEmpty {
            logger(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !output.stderr.isEmpty {
            logger(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard output.exitCode == 0 else {
            throw FapBuilderError.fbtFailed(
                command: command,
                exitCode: output.exitCode,
                output: output.stdout + output.stderr
            )
        }
        return output.stdout + output.stderr
    }

    private func findBuiltFap(appid: String, firmwareRoot: URL) throws -> URL {
        let buildRoot = firmwareRoot.appendingPathComponent("build")
        guard let enumerator = fileManager.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: []
        ) else {
            throw FapBuilderError.builtFapNotFound(appid)
        }

        var matches: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "\(appid).fap" else { continue }
            guard url.path.contains("/.extapps/") else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            matches.append((url, values?.contentModificationDate ?? .distantPast))
        }

        guard let newest = matches.sorted(by: { $0.modified > $1.modified }).first else {
            throw FapBuilderError.builtFapNotFound(appid)
        }
        return newest.url
    }

    private func stringField(_ field: String, in text: String) -> String? {
        let pattern = #"\b\#(field)\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }

    private func pythonStringConstant(_ name: String, in text: String) -> String? {
        let pattern = #"(?m)^\s*\#(name)\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }

    private func pythonLiteralConstant(_ name: String, in text: String) -> String? {
        let pattern = #"(?m)^\s*\#(name)\s*=\s*([A-Za-z0-9_."'-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private func readSDKAPIVersion(firmwareRoot: URL) throws -> String {
        let apiSymbols = firmwareRoot.appendingPathComponent("targets/f7/api_symbols.csv")
        guard fileManager.fileExists(atPath: apiSymbols.path) else {
            throw FapBuilderError.firmwareMetadataMissing(apiSymbols, "api_symbols.csv was not found")
        }

        let text = try String(contentsOf: apiSymbols, encoding: .utf8)
        let pattern = #"(?m)^Version,\+,([^,\r\n]+)"#
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: range),
           match.numberOfRanges >= 2,
           let valueRange = Range(match.range(at: 1), in: text) {
            return String(text[valueRange])
        }
        throw FapBuilderError.firmwareMetadataMissing(apiSymbols, "Version,+ entry was not found")
    }

    private func apiVersion(fromFBTOutput output: String) -> String? {
        let pattern = #"API version\s+([0-9]+(?:\.[0-9]+)*)\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[valueRange])
    }

    private func parseUSBDeviceInfoJSON(_ stdout: String) throws -> FlipperUSBDeviceInfo {
        guard let jsonLine = stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") }) else {
            throw FapBuilderError.usbDeviceInfoFailed("device_info JSON was not found")
        }
        let data = Data(String(jsonLine).utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? String,
              let fields = object["fields"] as? [String: String] else {
            throw FapBuilderError.usbDeviceInfoFailed("device_info JSON is malformed")
        }
        return FlipperUSBDeviceInfo(port: port, fields: fields)
    }

    private func preferredPythonCommand() -> PythonCommand {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        directories.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ])

        var checked = Set<String>()
        for name in ["python3.12", "python3.11", "python3.10"] {
            for directory in directories {
                let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
                guard checked.insert(path).inserted else { continue }
                if fileManager.isExecutableFile(atPath: path) {
                    return PythonCommand(
                        executable: URL(fileURLWithPath: path),
                        displayName: path
                    )
                }
            }
        }

        return PythonCommand(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            displayName: "/usr/bin/python3"
        )
    }

    private func isValidAppID(_ appid: String) -> Bool {
        appid.range(of: #"^[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil
    }

    private func title(from appid: String) -> String {
        appid
            .split(separator: "_")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private func sanitizePathComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let deviceInfoPythonScript = #"""
import json
import logging
import sys

from flipper.storage import FlipperStorage
from flipper.utils.cdc import resolve_port

logging.basicConfig(level=logging.ERROR)
logger = logging.getLogger("tumoflip-fap")
requested_port = sys.argv[1] if len(sys.argv) > 1 else "auto"
port = resolve_port(logger, requested_port)
if not port:
    print("Flipper USB CDC port was not found", file=sys.stderr)
    sys.exit(2)

with FlipperStorage(port) as storage:
    storage.send_and_wait_eol("device_info\r")
    raw = storage.read.until(storage.CLI_PROMPT).decode("utf-8", "replace")

fields = {}
for line in raw.replace("\r", "\n").split("\n"):
    line = line.strip()
    if not line or line == ">:" or line.startswith(">:"):
        continue
    if ":" not in line:
        continue
    key, value = line.split(":", 1)
    key = key.strip()
    value = value.strip()
    if key:
        fields[key] = value

print(json.dumps({"port": port, "fields": fields}, sort_keys=True))
"""#
}

private struct ProcessOutput: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private struct PythonCommand: Sendable {
    let executable: URL
    let displayName: String
}

private enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
            }
            process.environment = merged
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        var didTimeOut = false
        if let timeoutSeconds {
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
                didTimeOut = true
                process.terminate()
                if semaphore.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
            }
        } else {
            process.waitUntilExit()
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        return ProcessOutput(
            exitCode: didTimeOut ? 124 : process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: (String(data: stderrData, encoding: .utf8) ?? "")
                + (didTimeOut ? "\nProcess timed out." : "")
        )
    }
}
