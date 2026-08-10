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

    private static let cliPrompt = Data(">: ".utf8)
    private static let handshakeBufferLimit = 256

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
            try enterRPCMode(handle: handle)

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

    /// A newly opened VCP may still be starting its CLI and printing the MOTD.
    /// Synchronize on the real prompt instead of assuming a fixed delay, then
    /// discard only the textual transition emitted before RPC owns the pipe.
    private func enterRPCMode(handle: Int32) throws {
        let promptDeadline = Date().addingTimeInterval(4)
        var received = Data()

        while Date() < promptDeadline {
            try writeAll(Data("\r".utf8), to: handle)
            guard tcdrain(handle) == 0 else {
                throw FlipperTransportError.cannotConfigure("tcdrain")
            }

            let retryDeadline = min(promptDeadline, Date().addingTimeInterval(0.4))
            while Date() < retryDeadline {
                if let bytes = try readAvailable(handle: handle, waitMilliseconds: 80) {
                    received.append(bytes)
                    if received.count > Self.handshakeBufferLimit {
                        received.removeFirst(received.count - Self.handshakeBufferLimit)
                    }
                    if received.range(of: Self.cliPrompt) != nil {
                        try startRPCCommand(handle: handle)
                        return
                    }
                }
            }
        }

        throw FlipperTransportError.rpcHandshakeTimedOut
    }

    private func startRPCCommand(handle: Int32) throws {
        try writeAll(Data("start_rpc_session\r".utf8), to: handle)
        guard tcdrain(handle) == 0 else {
            throw FlipperTransportError.cannotConfigure("tcdrain")
        }

        let deadline = Date().addingTimeInterval(2)
        var lastTextAt = Date()
        var receivedText = false

        while Date() < deadline {
            if try readAvailable(handle: handle, waitMilliseconds: 50) != nil {
                receivedText = true
                lastTextAt = Date()
                continue
            }

            let quietFor = Date().timeIntervalSince(lastTextAt)
            if (receivedText && quietFor >= 0.2) || (!receivedText && quietFor >= 0.5) {
                return
            }
        }

        throw FlipperTransportError.rpcHandshakeTimedOut
    }

    private func readAvailable(handle: Int32, waitMilliseconds: Int32) throws -> Data? {
        var descriptor = pollfd(fd: handle, events: Int16(POLLIN), revents: 0)
        var result: Int32
        repeat {
            result = Darwin.poll(&descriptor, 1, waitMilliseconds)
        } while result < 0 && errno == EINTR

        guard result >= 0 else {
            throw FlipperTransportError.cannotOpen(path, String(cString: strerror(errno)))
        }
        guard result > 0 else { return nil }
        guard descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
            throw FlipperTransportError.disconnected
        }
        guard descriptor.revents & Int16(POLLIN) != 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = Darwin.read(handle, &buffer, buffer.count)
        if count > 0 {
            return Data(buffer.prefix(count))
        } else if count < 0, errno == EINTR || errno == EAGAIN {
            return nil
        } else if count < 0 {
            throw FlipperTransportError.cannotOpen(path, String(cString: strerror(errno)))
        } else {
            throw FlipperTransportError.disconnected
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
