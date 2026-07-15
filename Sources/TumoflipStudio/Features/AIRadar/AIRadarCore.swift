import AppKit
import Combine
import Network
import Foundation
import CoreBluetooth

// AI Radar Bridge — a tiny macOS menu-bar app that collects AI-provider usage
// (reusing the proven Python collector) and serves the latest snapshot over local
// HTTP. The UnleashedCompanion iPhone app fetches it and writes usage.txt to the
// Flipper over BLE. No Sber relay, no direct Mac→Flipper BLE push.

enum Config {
    private static let environment = ProcessInfo.processInfo.environment
    private static let projectRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects/Flipper", isDirectory: true)

    static let python: String = {
        if let override = environment["TUMOFLIP_PYTHON"], !override.isEmpty {
            return override
        }
        return [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/python3"
    }()
    static let repoRoot = environment["TUMOFLIP_AI_RADAR_ROOT"]
        ?? projectRoot.appendingPathComponent("flipper-ai-dashboard", isDirectory: true).path
    static let script   = "bridge/ai_usage_bridge.py"               // relative to repoRoot
    static var manual   = "\(repoRoot)/bridge/providers.local.json"
    static var output   = "\(repoRoot)/bridge/out/usage.txt"
    static let codexDir = "/Applications/Codex.app/Contents/Resources"
    static let httpPort: UInt16 = 8730
    static let defaultInterval: TimeInterval = 120
    static let workerCount: Int = {
        let requested = environment["TUMOFLIP_WORKERS"].flatMap(Int.init) ?? 2
        return min(4, max(1, requested))
    }()
}

// MARK: - Flipper BLE App Bridge

struct AppBridgeFrame {
    let appId: String
    let command: String
    let payload: Data

    static let serviceUUID = CBUUID(string: "7F7D0000-2E31-4C42-8A98-9B2F6B8C0001")
    static let eventsUUID = CBUUID(string: "7F7D0000-2E31-4C42-8A98-9B2F6B8C0002")
    static let commandsUUID = CBUUID(string: "7F7D0000-2E31-4C42-8A98-9B2F6B8C0003")
    static let arfOffloadAppId = "arf_offload"

    static func decode(_ data: Data) -> AppBridgeFrame? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x46, bytes[1] == 0x41, bytes[2] == 0x42, bytes[3] == 0x31 else {
            return nil
        }
        let appIdLen = Int(bytes[4])
        let commandLen = Int(bytes[5])
        let payloadLen = Int(bytes[6]) | (Int(bytes[7]) << 8)
        let totalLen = 8 + appIdLen + commandLen + payloadLen
        guard appIdLen > 0, commandLen > 0, payloadLen <= 172, totalLen <= data.count else {
            return nil
        }
        let appStart = 8
        let commandStart = appStart + appIdLen
        let payloadStart = commandStart + commandLen
        guard
            let appId = String(data: data[appStart..<commandStart], encoding: .utf8),
            let command = String(data: data[commandStart..<payloadStart], encoding: .utf8)
        else {
            return nil
        }
        return AppBridgeFrame(
            appId: appId,
            command: command,
            payload: data[payloadStart..<payloadStart + payloadLen])
    }

    static func encode(appId: String, command: String, payload: Data = Data()) -> Data? {
        let appIdBytes = Array(appId.utf8)
        let commandBytes = Array(command.utf8)
        let payloadBytes = Array(payload)
        guard
            !appIdBytes.isEmpty, appIdBytes.count <= 32,
            !commandBytes.isEmpty, commandBytes.count <= 32,
            payloadBytes.count <= 172
        else {
            return nil
        }

        var frame = Data()
        frame.append(contentsOf: [0x46, 0x41, 0x42, 0x31])
        frame.append(UInt8(appIdBytes.count))
        frame.append(UInt8(commandBytes.count))
        frame.append(UInt8(payloadBytes.count & 0xFF))
        frame.append(UInt8((payloadBytes.count >> 8) & 0xFF))
        frame.append(contentsOf: appIdBytes)
        frame.append(contentsOf: commandBytes)
        frame.append(contentsOf: payloadBytes)
        return frame
    }
}

// MARK: - Allowlisted Relay commands

private struct RelayCommand: Decodable {
    let appId: String
    let command: String
    let run: [String]
    let timeout: TimeInterval
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case appId = "app_id"
        case command
        case run
        case timeout
        case cwd
    }
}

private struct RelayConfig: Decodable {
    let defaultTimeout: TimeInterval
    let commands: [RelayCommand]

    enum CodingKeys: String, CodingKey {
        case defaultTimeout = "default_timeout"
        case commands
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDefaultTimeout = try values.decodeIfPresent(TimeInterval.self, forKey: .defaultTimeout) ?? 8
        defaultTimeout = decodedDefaultTimeout
        let rawCommands = try values.decodeIfPresent([RawRelayCommand].self, forKey: .commands) ?? []
        commands = rawCommands.map {
            RelayCommand(
                appId: $0.appId,
                command: $0.command,
                run: $0.run,
                timeout: $0.timeout ?? decodedDefaultTimeout,
                cwd: $0.cwd
            )
        }
    }
}

private struct RawRelayCommand: Decodable {
    let appId: String
    let command: String
    let run: [String]
    let timeout: TimeInterval?
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case appId = "app_id"
        case command
        case run
        case timeout
        case cwd
    }
}

private final class RelayCommandRunner: @unchecked Sendable {
    private(set) var configPath: String
    private(set) var status = "Relay mappings not loaded"
    private var commands: [String: RelayCommand] = [:]

    init() {
        let environment = ProcessInfo.processInfo.environment
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/Flipper/flipper_relay/mac", isDirectory: true)
        configPath = environment["TUMOFLIP_RELAY_CONFIG"]
            ?? root.appendingPathComponent("commands.local.json").path
        reload()
    }

    var commandCount: Int { commands.count }

    func reload() {
        var url = URL(fileURLWithPath: configPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            let fallback = url.deletingLastPathComponent().appendingPathComponent("commands.example.json")
            if FileManager.default.fileExists(atPath: fallback.path) {
                url = fallback
                configPath = fallback.path
            }
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(RelayConfig.self, from: data)
            var loaded: [String: RelayCommand] = [:]
            for command in decoded.commands where !command.run.isEmpty {
                loaded[key(command.appId, command.command)] = command
            }
            commands = loaded
            status = "\(commands.count) allowlisted command\(commands.count == 1 ? "" : "s")"
        } catch {
            commands = [:]
            status = "Relay config unavailable: \(error.localizedDescription)"
        }
    }

    func mapping(appId: String, command: String) -> RelayCommand? {
        commands[key(appId, command)]
    }

    func execute(
        _ mapping: RelayCommand,
        payload: Data,
        completion: @escaping @Sendable (Bool, String) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            guard let executable = mapping.run.first else {
                completion(false, "empty command")
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(mapping.run.dropFirst())
            if let cwd = mapping.cwd, !cwd.isEmpty {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            var environment = ProcessInfo.processInfo.environment
            environment["FLIPPER_APP_ID"] = mapping.appId
            environment["FLIPPER_COMMAND"] = mapping.command
            environment["FLIPPER_PAYLOAD"] = String(decoding: payload, as: UTF8.self)
            process.environment = environment

            let output = Pipe()
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
            } catch {
                completion(false, error.localizedDescription)
                return
            }

            let deadline = Date().addingTimeInterval(max(0.5, mapping.timeout))
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                completion(false, "timeout")
                return
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            let raw = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = String((raw.isEmpty ? "exit \(process.terminationStatus)" : raw).prefix(120))
            completion(process.terminationStatus == 0, detail)
        }
    }

    private func key(_ appId: String, _ command: String) -> String {
        "\(appId)\u{0}\(command)"
    }
}

// MARK: - KeeLoq brute-force engine
//
// Mirrors the Flipper's own KeeLoq decoder math (lib/subghz/protocols/keeloq*).
// The Flipper offloads the 2^32 search to us: for each candidate it builds a
// device key via a "magic serial" learning scheme, KeeLoq-decrypts the captured
// hop code, and accepts the key if the decrypt's button + discrimination byte
// match the fixed part. Two captures (same serial, different hop) are required so
// the counter check kills false positives. The recovered device key is reported
// back and saved on the Flipper as a SIMPLE-learning key.

private let KEELOQ_NLF: UInt32 = 0x3A5C742E

@inline(__always) private func klBit(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) & 1 }
@inline(__always) private func klBit64(_ x: UInt64, _ n: UInt32) -> UInt32 { UInt32((x >> UInt64(n)) & 1) }
@inline(__always) private func klG5(_ x: UInt32, _ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, _ e: UInt32) -> UInt32 {
    klBit(x, a) &+ klBit(x, b) &* 2 &+ klBit(x, c) &* 4 &+ klBit(x, d) &* 8 &+ klBit(x, e) &* 16
}

/// Simple-learning KeeLoq decrypt (528 NLFSR rounds), identical to
/// subghz_protocol_keeloq_common_decrypt.
@inline(__always) private func keeloqDecrypt(_ data: UInt32, _ key: UInt64) -> UInt32 {
    var x = data
    var r: UInt32 = 0
    while r < 528 {
        let nlf = klBit(KEELOQ_NLF, klG5(x, 0, 8, 19, 25, 30))
        x = (x << 1) ^ klBit(x, 31) ^ klBit(x, 15) ^ klBit64(key, (15 &- r) & 63) ^ nlf
        r &+= 1
    }
    return x
}

// Magic-serial learning key construction (manufacture key -> per-device key).
@inline(__always) private func klMagicSerial1(_ data: UInt32, _ man: UInt64) -> UInt64 {
    (man & 0xFFFFFFFF) | (UInt64(data) << 40) |
        (UInt64(((data & 0xFF) &+ ((data >> 8) & 0xFF)) & 0xFF) << 32)
}
@inline(__always) private func klMagicSerial2(_ data: UInt32, _ man: UInt64) -> UInt64 {
    var result = man & 0x0000_0000_FFFF_FFFF
    result |= UInt64(data & 0xFF) << 56
    result |= UInt64((data >> 8) & 0xFF) << 48
    result |= UInt64((data >> 16) & 0xFF) << 40
    result |= UInt64((data >> 24) & 0xFF) << 32
    return result
}
@inline(__always) private func klMagicSerial3(_ data: UInt32, _ man: UInt64) -> UInt64 {
    (man & 0xFFFF_FFFF_FF00_0000) | (UInt64(data) & 0xFFFFFF)
}

/// Derive the device key for a learning type from a 32-bit brute-force candidate.
/// type1/type2 free the low 32 bits (= candidate); type3 frees high bits, so the
/// candidate is shifted into them.
@inline(__always) private func klDeriveKey(_ type: UInt8, _ fix: UInt32, _ candidate: UInt32) -> UInt64 {
    switch type {
    case 6: return klMagicSerial1(fix, UInt64(candidate))
    case 7: return klMagicSerial2(fix, UInt64(candidate))
    case 8: return klMagicSerial3(fix, UInt64(candidate) << 24)
    default: return klMagicSerial1(fix, UInt64(candidate))
    }
}

private final class AtomicU64 {
    private var value: UInt64 = 0
    private let lock = NSLock()
    func add(_ n: UInt64) { lock.lock(); value &+= n; lock.unlock() }
    func get() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
}

final class KeeloqWorker {
    private let lock = NSLock()
    private var cancelled = false
    private var candidateCount = 0
    private let maxCandidates = 16   // safety cap against a flood of false positives

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Run the search on background threads. Callbacks may fire from any thread.
    func start(learnType: UInt8, fix: UInt32, hop: UInt32, hop2: UInt32,
               progress: @escaping (UInt32, UInt32) -> Void,
               candidate: @escaping (UInt64, UInt32, UInt8) -> Void,
               done: @escaping () -> Void) {
        lock.lock(); cancelled = false; candidateCount = 0; lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            self.run(learnType: learnType, fix: fix, hop: hop, hop2: hop2,
                     progress: progress, candidate: candidate)
            done()
        }
    }

    private func run(learnType: UInt8, fix: UInt32, hop: UInt32, hop2: UInt32,
                     progress: @escaping (UInt32, UInt32) -> Void,
                     candidate: @escaping (UInt64, UInt32, UInt8) -> Void) {
        let btn = fix >> 28
        let endSerial = fix & 0xFF
        let types: [UInt8] = (learnType == 0) ? [6, 7, 8] : [learnType]

        let tested = AtomicU64()
        // Progress ticker: report keys tested + keys/sec once a second.
        let ticker = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        var lastTested: UInt64 = 0
        ticker.schedule(deadline: .now() + 1, repeating: 1)
        ticker.setEventHandler {
            let now = tested.get()
            let perSec = now >= lastTested ? UInt32(min(now - lastTested, 0xFFFFFFFF)) : 0
            lastTested = now
            progress(UInt32(min(now, 0xFFFFFFFF)), perSec)
        }
        ticker.resume()

        let cores = Config.workerCount
        let total: UInt64 = 0x1_0000_0000
        let chunk = total / UInt64(cores)

        DispatchQueue.concurrentPerform(iterations: cores) { idx in
            let lo = UInt64(idx) * chunk
            let hi = (idx == cores - 1) ? total : lo + chunk
            var local: UInt64 = 0
            var c = lo
            while c < hi {
                let cand = UInt32(truncatingIfNeeded: c)
                for t in types {
                    let key = klDeriveKey(t, fix, cand)
                    let dec1 = keeloqDecrypt(hop, key)
                    if (dec1 >> 28) == btn && ((dec1 >> 16) & 0xFF) == endSerial {
                        let dec2 = keeloqDecrypt(hop2, key)
                        if (dec2 >> 28) == btn && ((dec2 >> 16) & 0xFF) == endSerial {
                            let cnt1 = dec1 & 0xFFFF
                            let cnt2 = dec2 & 0xFFFF
                            let d = (cnt2 &- cnt1) & 0xFFFF      // consecutive-ish presses
                            if (d >= 1 && d <= 64) || (d >= 0xFFC0) {
                                self.lock.lock()
                                let overflow = self.candidateCount >= self.maxCandidates
                                if !overflow { self.candidateCount += 1 }
                                if self.candidateCount >= self.maxCandidates { self.cancelled = true }
                                self.lock.unlock()
                                if !overflow { candidate(key, cnt1, t) }
                            }
                        }
                    }
                }
                c &+= 1
                local &+= 1
                if local >= (1 << 20) {
                    tested.add(local); local = 0
                    if self.isCancelled() { break }
                }
            }
            tested.add(local)
        }
        ticker.cancel()
    }
}

// MARK: - PSA brute-force engine (TEA-based, mirrors lib/subghz/protocols/psa.c)
//
// The Flipper sends two TEA words (w0,w1); we search a counter space, derive a
// per-counter TEA key, decrypt, and validate by a 24-bit counter match + CRC.
// Two phases (bf1 / bf2) of 16M each. On a hit we return counter + decrypted
// words; the Flipper finalizes the key.

private let TEA_DELTA: UInt32 = 0x9E3779B9
private let TEA_ROUNDS = 32

private let PSA_BF1_CONST_U4: UInt32 = 0x0E0F5C41
private let PSA_BF1_CONST_U5: UInt32 = 0x0F5C4123
private let PSA_BF1_KEY_SCHEDULE: [UInt32] = [0x4A434915, 0xD6743C2B, 0x1F29D308, 0xE6B79A64]
private let PSA_BF2_KEY_SCHEDULE: [UInt32] = [0x4039C240, 0xEDA92CAB, 0x4306C02A, 0x02192A04]
private let PSA_BF1_START: UInt32 = 0x23000000, PSA_BF1_END: UInt32 = 0x24000000
private let PSA_BF2_START: UInt32 = 0xF3000000, PSA_BF2_END: UInt32 = 0xF4000000

private struct PsaSchedule { var s0: [UInt32]; var s1: [UInt32] }

private func psaBuildSchedule(_ key: [UInt32]) -> PsaSchedule {
    var s0 = [UInt32](repeating: 0, count: TEA_ROUNDS)
    var s1 = s0
    for i in 0..<TEA_ROUNDS {
        let sum0 = UInt32(truncatingIfNeeded: UInt64(i) &* UInt64(TEA_DELTA))
        let sum1 = UInt32(truncatingIfNeeded: UInt64(i + 1) &* UInt64(TEA_DELTA))
        s0[i] = key[Int(sum0 & 3)] &+ sum0
        s1[i] = key[Int((sum1 >> 11) & 3)] &+ sum1
    }
    return PsaSchedule(s0: s0, s1: s1)
}

@inline(__always) private func psaEncSched(_ v0: inout UInt32, _ v1: inout UInt32, _ s: PsaSchedule) {
    var a = v0, b = v1
    for i in 0..<TEA_ROUNDS {
        a = a &+ (s.s0[i] ^ ((((b >> 5) ^ (b << 4)) &+ b)))
        b = b &+ (s.s1[i] ^ ((((a >> 5) ^ (a << 4)) &+ a)))
    }
    v0 = a; v1 = b
}

@inline(__always) private func psaTeaDecrypt(_ v0: inout UInt32, _ v1: inout UInt32, _ k: (UInt32, UInt32, UInt32, UInt32)) {
    var a = v0, b = v1
    var sum = TEA_DELTA &* UInt32(TEA_ROUNDS)
    let key = [k.0, k.1, k.2, k.3]
    for _ in 0..<TEA_ROUNDS {
        var temp = key[Int((sum >> 11) & 3)] &+ sum
        sum = sum &- TEA_DELTA
        b = b &- (temp ^ ((((a >> 5) ^ (a << 4)) &+ a)))
        temp = key[Int(sum & 3)] &+ sum
        a = a &- (temp ^ ((((b >> 5) ^ (b << 4)) &+ b)))
    }
    v0 = a; v1 = b
}

@inline(__always) private func psaTeaCrc(_ v0: UInt32, _ v1: UInt32) -> UInt8 {
    var crc = ((v0 >> 24) & 0xFF) &+ ((v0 >> 16) & 0xFF) &+ ((v0 >> 8) & 0xFF) &+ (v0 & 0xFF)
    crc = crc &+ ((v1 >> 24) & 0xFF) &+ ((v1 >> 16) & 0xFF) &+ ((v1 >> 8) & 0xFF)
    return UInt8(crc & 0xFF)
}

private let psaCrc16Table: [UInt16] = {
    var t = [UInt16](repeating: 0, count: 256)
    for b in 0..<256 {
        var c = UInt16(b) << 8
        for _ in 0..<8 { c = (c & 0x8000) != 0 ? (c << 1) ^ 0x8005 : (c << 1) }
        t[b] = c
    }
    return t
}()

@inline(__always) private func psaCrc16(_ buf: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0
    for byte in buf { crc = (crc << 8) ^ psaCrc16Table[Int(((crc >> 8) ^ UInt16(byte)) & 0xFF)] }
    return crc
}

final class PsaWorker {
    struct Hit { let counter: UInt32; let v0: UInt32; let v1: UInt32 }

    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func start(w0: UInt32, w1: UInt32,
               progress: @escaping (UInt32, UInt32) -> Void,
               result: @escaping (Bool, UInt32, UInt32, UInt32) -> Void) {
        lock.lock(); cancelled = false; lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let start = DispatchTime.now()
            if let hit = self.runPhase(1, w0: w0, w1: w1, start: start, progress: progress) {
                result(true, hit.counter, hit.v0, hit.v1); return
            }
            if self.isCancelled() { result(false, 0, 0, 0); return }
            if let hit = self.runPhase(2, w0: w0, w1: w1, start: start, progress: progress) {
                result(true, hit.counter, hit.v0, hit.v1); return
            }
            result(false, 0, 0, 0)
        }
    }

    private func runPhase(_ phase: Int, w0: UInt32, w1: UInt32, start: DispatchTime,
                          progress: @escaping (UInt32, UInt32) -> Void) -> Hit? {
        let lo = phase == 1 ? PSA_BF1_START : PSA_BF2_START
        let hi = phase == 1 ? PSA_BF1_END : PSA_BF2_END
        let base: UInt32 = phase == 1 ? 0 : 0x1000000     // keys_tested offset for progress
        let sched = phase == 1 ? psaBuildSchedule(PSA_BF1_KEY_SCHEDULE) : PsaSchedule(s0: [], s1: [])

        let tested = AtomicU64()
        let ticker = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        ticker.schedule(deadline: .now() + 1, repeating: 1)
        ticker.setEventHandler {
            let now = tested.get()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            let perSec = elapsed > 0 ? UInt32(min(Double(now) / elapsed, 4e9)) : 0
            progress(UInt32(min(UInt64(base) &+ now, 0xFFFFFFFF)), perSec)
        }
        ticker.resume()

        let hitLock = NSLock()
        var hit: Hit?
        let cores = Config.workerCount
        let span = UInt64(hi - lo)
        let chunk = span / UInt64(cores)

        DispatchQueue.concurrentPerform(iterations: cores) { idx in
            let cStart = lo &+ UInt32(UInt64(idx) * chunk)
            let cEnd = idx == cores - 1 ? hi : lo &+ UInt32(UInt64(idx + 1) * chunk)
            var local: UInt64 = 0
            var counter = cStart
            while counter < cEnd {
                var d0 = w0, d1 = w1
                if phase == 1 {
                    var wk2 = PSA_BF1_CONST_U4, wk3 = counter
                    psaEncSched(&wk2, &wk3, sched)
                    var wk0 = (counter << 8) | 0x0E, wk1 = PSA_BF1_CONST_U5
                    psaEncSched(&wk0, &wk1, sched)
                    psaTeaDecrypt(&d0, &d1, (wk0, wk1, wk2, wk3))
                    if (counter & 0xFFFFFF) == (d0 >> 8), psaTeaCrc(d0, d1) == UInt8(d1 & 0xFF) {
                        hitLock.lock(); hit = Hit(counter: counter, v0: d0, v1: d1); hitLock.unlock()
                        self.cancel()
                    }
                } else {
                    let k = (PSA_BF2_KEY_SCHEDULE[0] ^ counter, PSA_BF2_KEY_SCHEDULE[1] ^ counter,
                             PSA_BF2_KEY_SCHEDULE[2] ^ counter, PSA_BF2_KEY_SCHEDULE[3] ^ counter)
                    psaTeaDecrypt(&d0, &d1, k)
                    if (counter & 0xFFFFFF) == (d0 >> 8) {
                        let cb: [UInt8] = [
                            UInt8((d0 >> 24) & 0xFF), UInt8((d0 >> 8) & 0xFF), UInt8((d0 >> 16) & 0xFF),
                            UInt8(d0 & 0xFF), UInt8((d1 >> 24) & 0xFF), UInt8((d1 >> 16) & 0xFF)]
                        let expected = UInt16(((d1 >> 16) & 0xFF) << 8) | UInt16(d1 & 0xFF)
                        if psaCrc16(cb) == expected {
                            hitLock.lock(); hit = Hit(counter: counter, v0: d0, v1: d1); hitLock.unlock()
                            self.cancel()
                        }
                    }
                }
                counter = counter &+ 1
                local &+= 1
                if local >= (1 << 18) {
                    tested.add(local); local = 0
                    if self.isCancelled() { break }
                }
            }
            tested.add(local)
        }
        ticker.cancel()
        return hit
    }
}

extension Data {
    mutating func appendLE(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

@inline(__always) private func le32(_ p: [UInt8], _ off: Int) -> UInt32 {
    UInt32(p[off]) | (UInt32(p[off + 1]) << 8) | (UInt32(p[off + 2]) << 16) | (UInt32(p[off + 3]) << 24)
}

final class FlipperAppBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandsChar: CBCharacteristic?
    private(set) var status = "BLE App Bridge: starting"
    private(set) var lastAction = "No relay action yet"
    var onStatusChanged: (() -> Void)?
    private let keeloq = KeeloqWorker()
    private let psa = PsaWorker()
    private let relay = RelayCommandRunner()

    var relayStatus: String { relay.status }
    var relayConfigPath: String { relay.configPath }
    var relayCommandCount: Int { relay.commandCount }

    func reloadRelayMappings() {
        relay.reload()
        lastAction = "Relay mappings reloaded"
        onStatusChanged?()
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            status = "BLE App Bridge: scanning"
            central.scanForPeripherals(withServices: [AppBridgeFrame.serviceUUID])
        case .poweredOff:
            status = "BLE App Bridge: Bluetooth off"
        case .unauthorized:
            status = "BLE App Bridge: permission denied"
        default:
            status = "BLE App Bridge: unavailable"
        }
        onStatusChanged?()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        status = "BLE App Bridge: connecting"
        onStatusChanged?()
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "BLE App Bridge: discovering"
        onStatusChanged?()
        peripheral.discoverServices([AppBridgeFrame.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        commandsChar = nil
        self.peripheral = nil
        status = "BLE App Bridge: disconnected"
        onStatusChanged?()
        central.scanForPeripherals(withServices: [AppBridgeFrame.serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            status = "BLE App Bridge: service error \(error.localizedDescription)"
            onStatusChanged?()
            return
        }
        for service in peripheral.services ?? [] where service.uuid == AppBridgeFrame.serviceUUID {
            peripheral.discoverCharacteristics(
                [AppBridgeFrame.eventsUUID, AppBridgeFrame.commandsUUID],
                for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error = error {
            status = "BLE App Bridge: char error \(error.localizedDescription)"
            onStatusChanged?()
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == AppBridgeFrame.eventsUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == AppBridgeFrame.commandsUUID {
                commandsChar = characteristic
            }
        }
        status = commandsChar == nil ? "BLE App Bridge: missing command char" : "BLE App Bridge: ready"
        onStatusChanged?()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard
            error == nil,
            characteristic.uuid == AppBridgeFrame.eventsUUID,
            let data = characteristic.value,
            let frame = AppBridgeFrame.decode(data)
        else {
            return
        }
        if frame.appId == AppBridgeFrame.arfOffloadAppId {
            handleArfOffload(frame)
        } else {
            handleMappedCommand(frame)
        }
    }

    private func handleMappedCommand(_ frame: AppBridgeFrame) {
        guard let mapping = relay.mapping(appId: frame.appId, command: frame.command) else {
            lastAction = "Ignored unmapped \(frame.appId)/\(frame.command)"
            onStatusChanged?()
            return
        }

        lastAction = "Running \(frame.appId)/\(frame.command)"
        onStatusChanged?()
        relay.execute(mapping, payload: frame.payload) { [weak self] ok, detail in
            DispatchQueue.main.async {
                guard let self else { return }
                let result = ok ? "ok" : "error"
                self.lastAction = "\(frame.appId)/\(frame.command): \(result) \(detail)"
                self.sendFrame(
                    appId: frame.appId,
                    command: result,
                    payload: Data("\(result):\(frame.command)".utf8)
                )
                self.onStatusChanged?()
            }
        }
    }

    private func handleArfOffload(_ frame: AppBridgeFrame) {
        switch frame.command {
        case "psa_bf_request":
            startPsa(frame.payload)
        case "psa_bf_cancel":
            psa.cancel()
            status = "BLE App Bridge: PSA cancelled"
        case "keeloq_bf_request":
            startKeeloq(frame.payload)
        case "keeloq_bf_cancel":
            keeloq.cancel()
            status = "BLE App Bridge: Keeloq cancelled"
        default:
            status = "BLE App Bridge: unknown ARF command \(frame.command)"
        }
        onStatusChanged?()
    }

    private func sendReject(_ reason: String) {
        guard
            let peripheral = peripheral,
            let commandsChar = commandsChar,
            let frame = AppBridgeFrame.encode(
                appId: AppBridgeFrame.arfOffloadAppId,
                command: "reject",
                payload: Data(reason.utf8))
        else {
            return
        }
        let writeType: CBCharacteristicWriteType =
            commandsChar.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(frame, for: commandsChar, type: writeType)
    }

    // MARK: - PSA offload

    private func startPsa(_ payload: Data) {
        guard payload.count >= 8 else { sendReject("malformed psa request"); return }
        let p = [UInt8](payload)
        let w0 = le32(p, 0)
        let w1 = le32(p, 4)
        status = "BLE App Bridge: PSA brute-force running…"
        onStatusChanged?()
        psa.start(
            w0: w0, w1: w1,
            progress: { [weak self] tested, perSec in
                self?.sendArf("psa_progress", { var d = Data(); d.appendLE(tested); d.appendLE(perSec); return d }())
            },
            result: { [weak self] success, counter, dv0, dv1 in
                var d = Data([success ? 1 : 0])   // success @ 0
                d.appendLE(counter)               // counter @ 1
                d.appendLE(dv0)                   // dec_v0 @ 5
                d.appendLE(dv1)                   // dec_v1 @ 9
                self?.sendArf("psa_result", d)
                DispatchQueue.main.async {
                    self?.status = success ? "BLE App Bridge: PSA key found" : "BLE App Bridge: PSA — no key"
                    self?.onStatusChanged?()
                }
            })
    }

    // MARK: - Keeloq offload

    private func startKeeloq(_ payload: Data) {
        guard payload.count >= 17 else { sendReject("malformed keeloq request"); return }
        let p = [UInt8](payload)
        let learnType = p[0]
        let fix = le32(p, 1)
        let hop = le32(p, 5)
        let hop2 = le32(p, 9)
        guard hop2 != 0 else {
            sendReject("load 2 signals (same serial) for Keeloq BF")
            return
        }
        status = "BLE App Bridge: Keeloq brute-force running…"
        onStatusChanged?()
        keeloq.start(
            learnType: learnType, fix: fix, hop: hop, hop2: hop2,
            progress: { [weak self] tested, perSec in
                self?.sendArf("keeloq_progress", { var d = Data(); d.appendLE(tested); d.appendLE(perSec); return d }())
            },
            candidate: { [weak self] key, cnt, type in
                var d = Data([1])           // found = 1
                d.appendLE(key)             // mfkey @ 1 (8 bytes)
                d.append(Data(count: 8))    // reserved @ 9 (Flipper ignores)
                d.appendLE(cnt)             // cnt @ 17 (4 bytes)
                d.append(Data(count: 4))    // reserved @ 21
                d.append(type)              // learn_type @ 25
                self?.sendArf("keeloq_result", d)
            },
            done: { [weak self] in
                var d = Data([2])           // found = 2 -> done
                d.append(Data(count: 25))   // pad to >= 26 so the Flipper accepts it
                self?.sendArf("keeloq_result", d)
                DispatchQueue.main.async {
                    self?.status = "BLE App Bridge: Keeloq search done"
                    self?.onStatusChanged?()
                }
            })
    }

    private func sendArf(_ command: String, _ payload: Data) {
        DispatchQueue.main.async {
            self.sendFrame(appId: AppBridgeFrame.arfOffloadAppId, command: command, payload: payload)
        }
    }

    private func sendFrame(appId: String, command: String, payload: Data) {
        guard
            let peripheral,
            let commandsChar,
            let frame = AppBridgeFrame.encode(appId: appId, command: command, payload: payload)
        else { return }
        let writeType: CBCharacteristicWriteType =
            commandsChar.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(frame, for: commandsChar, type: writeType)
    }
}

// MARK: - Collector (shells out to the Python bridge, like sync_ble.sh)

final class Collector: @unchecked Sendable {
    private(set) var lastGood = ""        // last snapshot that had at least one provider
    private(set) var lastRun: Date?
    private(set) var lastOK = false

    // Per-provider memory so a single failed collect (e.g. codex app-server times
    // out for one cycle) doesn't make that provider vanish from the phone/Flipper.
    private var seen: [String: (line: String, date: Date)] = [:]
    private let providerTTL: TimeInterval = 1800   // keep a missing provider 30 min

    private func providerID(_ line: String) -> String? {
        let f = line.components(separatedBy: "|")
        return (f.count >= 2 && f[0] == "provider") ? f[1] : nil
    }

    /// Merge this collect's providers with recently-seen ones (TTL-bounded), so a
    /// transient miss keeps the last-known value instead of dropping the provider.
    private func merge(_ text: String) -> String {
        let now = Date()
        var metaLine = "meta|"
        var order: [String] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            if line.hasPrefix("meta|") { metaLine = line; continue }
            if let id = providerID(line) {
                seen[id] = (line, now)
                if !order.contains(id) { order.append(id) }
            }
        }
        seen = seen.filter { now.timeIntervalSince($0.value.date) <= providerTTL }
        for id in seen.keys where !order.contains(id) { order.append(id) }
        var out = [metaLine]
        for id in order { if let e = seen[id] { out.append(e.line) } }
        return out.joined(separator: "\n") + "\n"
    }

    @discardableResult
    func collect() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Config.python)
        p.arguments = [Config.script, "collect", "--output", Config.output, "--manual", Config.manual]
        p.currentDirectoryURL = URL(fileURLWithPath: Config.repoRoot)
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(Config.codexDir):\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        p.standardOutput = nil; p.standardError = nil
        do { try p.run() } catch { lastRun = Date(); lastOK = false; return false }
        p.waitUntilExit()
        lastRun = Date()
        let text = (try? String(contentsOfFile: Config.output, encoding: .utf8)) ?? ""
        // Only treat it as good if it actually carries a provider line.
        if text.contains("\nprovider|") || text.hasPrefix("provider|") {
            lastGood = merge(text)
            lastOK = true
            return true
        }
        lastOK = false
        return false
    }

    /// What we serve: the freshest good snapshot (never an empty/failed one).
    var snapshot: String { lastGood }
}

// MARK: - Claude Buddy notification queue (Mac → phone → Flipper)

final class BuddyQueue {
    private let lock = NSLock()
    private var items: [[String: String]] = []
    private let maxItems = 50

    func push(text: String, sub: String, sound: String) {
        lock.lock()
        items.append(["text": text, "sub": sub, "sound": sound])
        if items.count > maxItems { items.removeFirst(items.count - maxItems) }
        lock.unlock()
    }

    /// Return queued notifications as a JSON array and clear the queue.
    func drainJSON() -> String {
        lock.lock(); let out = items; items.removeAll(); lock.unlock()
        let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Transparent newline-JSON serial pipe for the full-duplex Claude Buddy path.
/// The Mac relay daemon (Daemon(RelayTransport)) and the iPhone each hold one
/// end; this just shuttles raw UTF-8 line bytes between them:
///   down  = host(daemon) → Flipper   (notify/state/menu …)   POST by daemon, GET by phone
///   up    = Flipper → host(daemon)   (button presses …)      POST by phone, GET by daemon
final class BuddySerialRelay {
    private let lock = NSLock()
    private var down = ""        // daemon → phone → Flipper RX
    private var up = ""          // Flipper TX → phone → daemon
    private let cap = 16 * 1024  // guard against an unread end backing up forever

    func pushDown(_ s: String) { lock.lock(); down += s; if down.utf8.count > cap { down = String(down.suffix(cap)) }; lock.unlock() }
    func pushUp(_ s: String)   { lock.lock(); up   += s; if up.utf8.count   > cap { up   = String(up.suffix(cap))   }; lock.unlock() }
    func drainDown() -> String { lock.lock(); let o = down; down = ""; lock.unlock(); return o }
    func drainUp() -> String   { lock.lock(); let o = up;   up   = ""; lock.unlock(); return o }
    func reset()               { lock.lock(); down = ""; up = ""; lock.unlock() }
}

// MARK: - Minimal HTTP server (Network framework, no dependencies)

final class HTTPServer {
    private var listener: NWListener?
    private let port: NWEndpoint.Port
    private let body: () -> String
    let buddy = BuddyQueue()
    let serial = BuddySerialRelay()
    private(set) var running = false
    private(set) var lastError: String?

    init(port: UInt16, body: @escaping () -> String) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.body = body
    }

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: port)
            // Advertise over Bonjour so the iPhone finds us by name even when the
            // Mac's DHCP IP changes (the iPhone connects to <host>.local, not the IP).
            l.service = NWListener.Service(name: "Tumoflip Studio", type: "_airadar._tcp")
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: .global(qos: .utility))
            listener = l
            running = true
            lastError = nil
        } catch {
            NSLog("AIRadarBridge: listener failed: \(error)")
            running = false
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel(); listener = nil; running = false
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self else { conn.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let method = parts.first.map(String.init) ?? "GET"
            let path = parts.count > 1 ? String(parts[1]) : "/"

            var payload = ""
            var contentType = "text/plain; charset=utf-8"

            let rawBody = request.range(of: "\r\n\r\n").map { String(request[$0.upperBound...]) } ?? ""

            if path.hasPrefix("/health") {
                payload = "ok"
            } else if path.hasPrefix("/buddy/down") {
                // daemon writes host→Flipper bytes; phone reads them
                if method == "POST" { self.serial.pushDown(rawBody); payload = "ok" }
                else { payload = self.serial.drainDown() }
            } else if path.hasPrefix("/buddy/up") {
                // phone posts Flipper→host bytes; daemon reads them
                if method == "POST" { self.serial.pushUp(rawBody); payload = "ok" }
                else { payload = self.serial.drainUp() }
            } else if path.hasPrefix("/buddy/reset") {
                self.serial.reset(); payload = "ok"
            } else if path.hasPrefix("/buddy") {
                if method == "POST" {
                    let f = Self.parseForm(rawBody)
                    self.buddy.push(text: f["text"] ?? "", sub: f["sub"] ?? "", sound: f["sound"] ?? "")
                    payload = "ok"
                } else {
                    payload = self.buddy.drainJSON(); contentType = "application/json"
                }
            } else {
                payload = self.body()
            }
            let header = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: \(contentType)\r\n" +
                "Content-Length: \(payload.utf8.count)\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "Connection: close\r\n\r\n"
            conn.send(content: Data((header + payload).utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    static func parseForm(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let v = String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])
            out[String(kv[0])] = v
        }
        return out
    }
}

// MARK: - Unified application store

@MainActor
final class AIRadarStore: ObservableObject {
    @Published private(set) var bridgeStatus = "BLE App Bridge: starting"
    @Published private(set) var collectionStatus = "Waiting for first collection"
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var snapshot = ""
    @Published private(set) var isListening = false
    @Published private(set) var isCollecting = false
    @Published private(set) var relayStatus = "Relay mappings not loaded"
    @Published private(set) var relayLastAction = "No relay action yet"
    @Published private(set) var relayConfigPath = ""
    @Published private(set) var serviceError: String?
    @Published var interval = Config.defaultInterval {
        didSet { scheduleTimer() }
    }

    private let collector = Collector()
    private let appBridge = FlipperAppBridge()
    private lazy var server = HTTPServer(port: Config.httpPort) { [weak self] in
        self?.collector.snapshot ?? ""
    }
    private var timer: Timer?
    private var started = false

    var endpointURL: String {
        "http://\(ProcessInfo.processInfo.hostName):\(Config.httpPort)/usage.txt"
    }

    init() {
        appBridge.onStatusChanged = { [weak self] in
            Task { @MainActor in self?.refreshBridgeState() }
        }
        refreshBridgeState()
    }

    func start() {
        guard !started else { return }
        started = true
        server.start()
        isListening = server.running
        serviceError = server.lastError
        bridgeStatus = appBridge.status
        collectNow()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        server.stop()
        isListening = false
        started = false
    }

    func collectNow() {
        guard !isCollecting else { return }
        isCollecting = true
        collectionStatus = "Collecting provider usage"
        let collector = self.collector
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let ok = collector.collect()
                return (ok, collector.snapshot, collector.lastRun)
            }.value
            guard let self else { return }
            self.snapshot = result.1
            self.lastUpdated = result.2
            self.collectionStatus = result.0 ? "Usage snapshot ready" : "No provider data returned"
            self.isCollecting = false
        }
    }

    func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpointURL, forType: .string)
    }

    func reloadRelayMappings() {
        appBridge.reloadRelayMappings()
        refreshBridgeState()
    }

    func restartHTTPService() {
        server.stop()
        server.start()
        isListening = server.running
        serviceError = server.lastError
    }

    private func refreshBridgeState() {
        bridgeStatus = appBridge.status
        relayStatus = appBridge.relayStatus
        relayLastAction = appBridge.lastAction
        relayConfigPath = appBridge.relayConfigPath
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard started else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.collectNow() }
        }
    }
}
