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

    /// Diagnostyka: BIFOLD_MCP_TRACE=<plik> zapisuje wiadomości MCP (bez tokenu — token idzie tylko w hello).
    static let traceFile: String? = ProcessInfo.processInfo.environment["BIFOLD_MCP_TRACE"]

    static func trace(_ direction: String, _ data: Data) {
        guard let path = traceFile else { return }
        let line = Data("\(direction) \(String(decoding: data.prefix(4000), as: UTF8.self))\n".utf8)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(line)
            h.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line)
        }
    }

    /// Klienci MCP deklarują możliwości z nowszych wersji specyfikacji (np. Codex:
    /// `elicitation: {form, url}`), których SDK nie dekoduje. Serwer Bifolda nie korzysta
    /// z możliwości klienta, więc w `initialize` zastępujemy je pustym obiektem.
    static func normalizeIncoming(_ frame: Data) -> Data {
        guard frame.count < 64 * 1024,
              var object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              object["method"] as? String == "initialize",
              var params = object["params"] as? [String: Any]
        else { return frame }
        params["capabilities"] = [String: Any]()
        object["params"] = params
        return (try? JSONSerialization.data(withJSONObject: object)) ?? frame
    }

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
                    SocketTransport.trace("→", frame)
                    continuation.yield(SocketTransport.normalizeIncoming(frame))
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
        SocketTransport.trace("←", data)
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
