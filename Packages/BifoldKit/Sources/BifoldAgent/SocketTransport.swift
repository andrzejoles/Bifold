import BifoldBridgeKit
import Darwin
import Foundation
import Logging
import MCP

/// Transport MCP po stronie aplikacji: ramki gniazda ⇄ wiadomości JSON-RPC.
public actor SocketTransport: Transport {
    public nonisolated let logger = Logger(label: "bifold.agent.transport")
    private let fd: Int32
    private let stream: AsyncThrowingStream<Data, any Swift.Error>
    private let continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation
    private let writeQueue = DispatchQueue(label: "bifold.agent.write")
    private var started = false
    private var closed = false
    private let onClose: @Sendable () -> Void

    public init(fd: Int32, onClose: @escaping @Sendable () -> Void = {}) {
        self.fd = fd
        self.onClose = onClose
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    public func connect() async throws {
        guard !started else { return }
        started = true
        let fd = fd, continuation = continuation, onClose = onClose
        let reader = Thread {
            while true {
                do {
                    let frame = try Wire.readFrame(from: fd)
                    continuation.yield(frame)
                } catch {
                    continuation.finish()
                    onClose()
                    return
                }
            }
        }
        reader.name = "bifold.agent.read"
        reader.start()
    }

    public func disconnect() async {
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
        close(fd)
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        guard !closed else { throw MCPError.connectionClosed }
        let fd = fd
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Swift.Error>) in
            writeQueue.async {
                do {
                    try Wire.writeFrame(data, to: fd)
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, any Swift.Error> { stream }
}
