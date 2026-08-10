import Foundation
import SwiftProtobuf

public enum FlipperRPCError: Error, LocalizedError, Equatable {
    case notStarted
    case timedOut
    case disconnected
    case status(PB_CommandStatus)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notStarted:
            "The Flipper RPC session has not started."
        case .timedOut:
            "The Flipper did not respond in time."
        case .disconnected:
            "Flipper disconnected."
        case .status(let status):
            "Flipper RPC error: \(status)"
        case .invalidResponse:
            "The Flipper returned an invalid response."
        }
    }
}

private final class RPCCommandGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if held {
                waiters.append(continuation)
                lock.unlock()
            } else {
                held = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        let next = waiters.isEmpty ? nil : waiters.removeFirst()
        if next == nil { held = false }
        lock.unlock()
        next?.resume()
    }
}

private final class RPCResponseRouter: @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<PB_Main, Error>.Continuation

    private let lock = NSLock()
    private var pending: [UInt32: Continuation] = [:]
    private var terminalError: Error?

    func open(commandID: UInt32) -> AsyncThrowingStream<PB_Main, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            if let terminalError {
                lock.unlock()
                continuation.finish(throwing: terminalError)
                return
            }
            pending[commandID] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.remove(commandID: commandID)
            }
        }
    }

    func route(_ message: PB_Main) {
        guard message.commandID != 0 else { return }

        lock.lock()
        let continuation = pending[message.commandID]
        if !message.hasNext_p || message.commandStatus != .ok {
            pending[message.commandID] = nil
        }
        lock.unlock()

        guard let continuation else { return }
        if message.commandStatus != .ok {
            continuation.finish(throwing: FlipperRPCError.status(message.commandStatus))
        } else {
            continuation.yield(message)
            if !message.hasNext_p {
                continuation.finish()
            }
        }
    }

    func fail(commandID: UInt32, error: Error) {
        lock.lock()
        let continuation = pending.removeValue(forKey: commandID)
        lock.unlock()
        continuation?.finish(throwing: error)
    }

    func failAll(_ error: Error) {
        lock.lock()
        terminalError = error
        let continuations = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        continuations.forEach { $0.finish(throwing: error) }
    }

    private func remove(commandID: UInt32) {
        lock.lock()
        pending[commandID] = nil
        lock.unlock()
    }
}

public final class FlipperRPCSession: @unchecked Sendable {
    private let transport: FlipperTransport
    private let gate = RPCCommandGate()
    private let router = RPCResponseRouter()
    private let stateLock = NSLock()
    private var decoder = DelimitedProtobufDecoder()
    private var readerTask: Task<Void, Never>?
    private var nextCommandID: UInt32 = 1
    private var started = false

    public init(transport: FlipperTransport) {
        self.transport = transport
    }

    public func start() async throws {
        guard !isStarted() else { return }

        try await transport.connect()
        setStarted(true)

        readerTask = Task { [weak self, transport] in
            do {
                for await bytes in transport.incomingBytes {
                    try self?.ingest(bytes)
                }
                self?.router.failAll(FlipperRPCError.disconnected)
            } catch {
                self?.router.failAll(error)
            }
        }
    }

    public func stop() async {
        setStarted(false)
        readerTask?.cancel()
        readerTask = nil
        router.failAll(FlipperRPCError.disconnected)
        await transport.disconnect()
    }

    @discardableResult
    public func command(
        timeout: TimeInterval = 30,
        _ configure: @escaping @Sendable (inout PB_Main) -> Void
    ) async throws -> [PB_Main] {
        await gate.acquire()
        defer { gate.release() }

        let (canSend, commandID) = commandContext()

        guard canSend else { throw FlipperRPCError.notStarted }
        try Task.checkCancellation()

        var request = PB_Main()
        request.commandID = commandID
        configure(&request)

        let stream = router.open(commandID: commandID)
        do {
            let payload = try request.serializedData()
            try await transport.send(DelimitedProtobufDecoder.encode(payload))
            return try await collect(stream: stream, timeout: timeout)
        } catch {
            router.fail(commandID: commandID, error: error)
            throw error
        }
    }

    private func collect(
        stream: AsyncThrowingStream<PB_Main, Error>,
        timeout: TimeInterval
    ) async throws -> [PB_Main] {
        try await withThrowingTaskGroup(of: [PB_Main].self) { group in
            group.addTask {
                var messages: [PB_Main] = []
                for try await message in stream {
                    messages.append(message)
                }
                return messages
            }
            group.addTask {
                let nanoseconds = UInt64(max(timeout, 0.1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw FlipperRPCError.timedOut
            }
            defer { group.cancelAll() }

            guard let result = try await group.next() else {
                throw FlipperRPCError.invalidResponse
            }
            if result.isEmpty {
                throw FlipperRPCError.invalidResponse
            }
            return result
        }
    }

    private func ingest(_ bytes: Data) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        for payload in try decoder.append(bytes) {
            let message = try PB_Main(serializedBytes: payload)
            router.route(message)
        }
    }

    private func isStarted() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return started
    }

    private func setStarted(_ value: Bool) {
        stateLock.lock()
        started = value
        stateLock.unlock()
    }

    private func commandContext() -> (Bool, UInt32) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let commandID = nextCommandID
        nextCommandID &+= 1
        if nextCommandID == 0 { nextCommandID = 1 }
        return (started, commandID)
    }
}
