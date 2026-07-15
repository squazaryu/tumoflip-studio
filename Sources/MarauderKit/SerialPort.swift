import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct PortInfo: Identifiable, Hashable, Sendable {
    public var id: String { device }
    public let device: String
    public let isFlipper: Bool   // /dev/cu.usbmodem* — порт Flipper (его держит sber_relay_bridge)
    public let isESP32: Bool     // wchusbserial / SLAB / usbserial
    public var label: String {
        if isFlipper { return "\(device)  · Flipper (USB-UART bridge)" }
        if isESP32 { return "\(device)  · ESP32" }
        return device
    }
}

/// Чтение/запись serial-порта через termios. Фоновый поток отдаёт строки в onLine
/// (на главной очереди). Порт открывается только по open() и освобождается close().
public final class SerialPort: @unchecked Sendable {
    public var onLine: ((String) -> Void)?
    public var onStatus: ((Bool, String) -> Void)?

    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "marauder.serial.read")
    private var running = false
    private var buffer = Data()
    public private(set) var path: String = ""

    public init() {}

    /// Список serial-портов с пометками Flipper/ESP32. Flipper намеренно не выбирается автодетектом.
    public static func listPorts() -> [PortInfo] {
        let dev = "/dev"
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dev)) ?? []
        var ports: [PortInfo] = []
        // не-serial устройства, которые macOS тоже показывает как cu.* (BT-аудио и т.п.)
        let excluded = ["bluetooth", "debug-console", "headphone", "headset",
                        "airpod", "wirelessiap", "beats", "buds", "speaker"]
        for name in items where name.hasPrefix("cu.") {
            let full = "\(dev)/\(name)"
            let low = name.lowercased()
            if excluded.contains(where: { low.contains($0) }) { continue }
            let isFlipper = low.contains("usbmodem") || low.contains("flip")
            let isESP32 = ["wchusbserial", "slab", "usbserial", "cp210"].contains { low.contains($0) }
            // показываем только USB-подобные порты (реальный serial)
            if !(isESP32 || isFlipper || low.contains("usb")) { continue }
            ports.append(PortInfo(device: full, isFlipper: isFlipper, isESP32: isESP32))
        }
        // ESP32 вперёд, Flipper в конец
        return ports.sorted { a, b in
            if a.isFlipper != b.isFlipper { return !a.isFlipper }
            if a.isESP32 != b.isESP32 { return a.isESP32 }
            return a.device < b.device
        }
    }

    /// Наиболее вероятный порт ESP32. Flipper-порты НЕ выбираются.
    public static func autodetect() -> String? {
        listPorts().first { $0.isESP32 && !$0.isFlipper }?.device
    }

    public var isOpen: Bool { fd >= 0 }

    @discardableResult
    public func open(path: String, baud: Int = 115200) -> Result<Void, SerialError> {
        close()
        #if canImport(Darwin)
        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else { return .failure(.cannotOpen(path, String(cString: strerror(errno)))) }
        // блокирующее чтение
        if fcntl(handle, F_SETFL, 0) == -1 {
            Darwin.close(handle)
            return .failure(.cannotConfigure("fcntl"))
        }
        var tio = termios()
        if tcgetattr(handle, &tio) != 0 {
            Darwin.close(handle)
            return .failure(.cannotConfigure("tcgetattr"))
        }
        cfmakeraw(&tio)                            // raw-режим; VMIN=1, VTIME=0
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)    // игнор модемных линий, разрешить чтение
        tio.c_cflag &= ~tcflag_t(PARENB)           // без чётности
        tio.c_cflag &= ~tcflag_t(CSTOPB)           // 1 стоп-бит
        tio.c_cflag &= ~tcflag_t(CSIZE)
        tio.c_cflag |= tcflag_t(CS8)               // 8 бит
        cfsetispeed(&tio, speed_t(baud))           // на BSD/macOS Bxxxx == само число
        cfsetospeed(&tio, speed_t(baud))
        if tcsetattr(handle, TCSANOW, &tio) != 0 {
            Darwin.close(handle)
            return .failure(.cannotConfigure("tcsetattr"))
        }
        fd = handle
        self.path = path
        running = true
        onStatus?(true, path)
        queue.async { [weak self] in self?.readLoop() }
        return .success(())
        #else
        return .failure(.cannotOpen(path, "platform not supported"))
        #endif
    }

    public func close() {
        running = false
        #if canImport(Darwin)
        if fd >= 0 { Darwin.close(fd) }
        #endif
        let wasOpen = fd >= 0
        fd = -1
        buffer.removeAll()
        if wasOpen { onStatus?(false, path) }
    }

    @discardableResult
    public func send(_ command: String) -> Bool {
        guard fd >= 0 else { return false }
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let data = Array(line.utf8)
        #if canImport(Darwin)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if written > 0 {
            DispatchQueue.main.async { [weak self] in self?.onLine?(">> \(command)") }
            return true
        }
        #endif
        return false
    }

    private func readLoop() {
        #if canImport(Darwin)
        var chunk = [UInt8](repeating: 0, count: 1024)
        while running && fd >= 0 {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                flushLines()
            } else if n == 0 {
                continue
            } else {
                if errno == EINTR { continue }
                break
            }
        }
        // выход не по stop() — значит обрыв связи: закрыть и уведомить
        if running {
            running = false
            if fd >= 0 { Darwin.close(fd); fd = -1 }
            let p = path
            DispatchQueue.main.async { [weak self] in self?.onStatus?(false, p) }
        }
        #endif
    }

    private func flushLines() {
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if lineData.isEmpty { continue }
            let line = String(decoding: lineData, as: UTF8.self)
            DispatchQueue.main.async { [weak self] in self?.onLine?(line) }
        }
    }
}

public enum SerialError: Error, CustomStringConvertible {
    case cannotOpen(String, String)
    case cannotConfigure(String)
    public var description: String {
        switch self {
        case .cannotOpen(let p, let e): "Cannot open \(p): \(e)"
        case .cannotConfigure(let s): "Cannot configure serial port (\(s))"
        }
    }
}
