import Darwin
import Foundation

public final class USBSerialFlipperTransport: FlipperTransport, @unchecked Sendable {
    public let incomingBytes: AsyncStream<Data>

    private let path: String
    private let stateLock = NSLock()
    private let readQueue = DispatchQueue(label: "com.tumoflip.studio.usb.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "com.tumoflip.studio.usb.write", qos: .userInitiated)
    private let continuation: AsyncStream<Data>.Continuation
    private var fileDescriptor: Int32 = -1
    private var running = false

    public init(path: String) {
        self.path = path
        let stream = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(128))
        incomingBytes = stream.stream
        continuation = stream.continuation
    }

    deinit {
        closeSynchronously(finishStream: true)
    }

    public func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async { [self] in
                do {
                    try openAndStartRPC()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func disconnect() async {
        await withCheckedContinuation { continuation in
            writeQueue.async { [self] in
                closeSynchronously(finishStream: true)
                continuation.resume()
            }
        }
    }

    public func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async { [self] in
                do {
                    let handle = try activeFileDescriptor()
                    try writeAll(data, to: handle)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func openAndStartRPC() throws {
        guard path.hasPrefix("/dev/cu.") else {
            throw FlipperTransportError.invalidDevicePath
        }

        stateLock.lock()
        let alreadyRunning = running
        stateLock.unlock()
        guard !alreadyRunning else { return }

        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            throw FlipperTransportError.cannotOpen(path, String(cString: strerror(errno)))
        }

        do {
            guard fcntl(handle, F_SETFL, 0) != -1 else {
                throw FlipperTransportError.cannotConfigure("fcntl")
            }

            var options = termios()
            guard tcgetattr(handle, &options) == 0 else {
                throw FlipperTransportError.cannotConfigure("tcgetattr")
            }
            cfmakeraw(&options)
            options.c_cflag |= tcflag_t(CLOCAL | CREAD)
            options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE)
            options.c_cflag |= tcflag_t(CS8)
            guard cfsetspeed(&options, speed_t(B115200)) == 0,
                  tcsetattr(handle, TCSANOW, &options) == 0 else {
                throw FlipperTransportError.cannotConfigure("termios")
            }

            tcflush(handle, TCIOFLUSH)
            try writeAll(Data("\rstart_rpc_session\r".utf8), to: handle)
            usleep(150_000)
            tcflush(handle, TCIFLUSH)

            stateLock.lock()
            fileDescriptor = handle
            running = true
            stateLock.unlock()

            readQueue.async { [weak self] in
                self?.readLoop(handle: handle)
            }
        } catch {
            Darwin.close(handle)
            throw error
        }
    }

    private func activeFileDescriptor() throws -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running, fileDescriptor >= 0 else {
            throw FlipperTransportError.disconnected
        }
        return fileDescriptor
    }

    private func writeAll(_ data: Data, to handle: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.write(handle, base.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0 {
                throw FlipperTransportError.cannotOpen(path, String(cString: strerror(errno)))
            } else {
                throw FlipperTransportError.shortWrite
            }
        }
    }

    private func readLoop(handle: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while isRunning(handle: handle) {
            let count = Darwin.read(handle, &buffer, buffer.count)
            if count > 0 {
                continuation.yield(Data(buffer.prefix(count)))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        closeSynchronously(finishStream: true)
    }

    private func isRunning(handle: Int32) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && fileDescriptor == handle
    }

    private func closeSynchronously(finishStream: Bool) {
        stateLock.lock()
        let handle = fileDescriptor
        fileDescriptor = -1
        running = false
        stateLock.unlock()

        if handle >= 0 {
            Darwin.close(handle)
        }
        if finishStream {
            continuation.finish()
        }
    }
}
