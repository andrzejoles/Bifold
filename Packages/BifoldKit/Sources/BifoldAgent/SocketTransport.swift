import BifoldBridgeKit
import Darwin
import Foundation
import Logging
import MCP
import Synchronization

/// Transport MCP po stronie aplikacji: ramki gniazda ⇄ wiadomości JSON-RPC.
///
/// Deskryptor należy do transportu: zamykany dokładnie raz, na kolejce zapisu (po ostatnim zapisie)
/// i dopiero po zakończeniu wątku czytającego — żaden odczyt ani zapis nie trafi do numeru
/// deskryptora ponownie użytego przez system.
public actor SocketTransport: Transport {
    public nonisolated let logger = Logger(label: "bifold.agent.transport")
    private let fd: Int32
    private let stream: AsyncThrowingStream<Data, any Swift.Error>
    private let continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation
    private let writeQueue = DispatchQueue(label: "bifold.agent.write")
    /// Stan deskryptora — zmieniany tylko na `writeQueue`.
    private let fdClosed = Mutex<Bool>(false)
    private var started = false
    private var closed = false
    private let onClose: @Sendable () -> Void

    /// Diagnostyka (tylko kompilacja Debug): BIFOLD_MCP_TRACE=<plik> zapisuje wiadomości MCP
    /// (bez tokenu — token idzie tylko w hello) do pliku 0600.
    static let traceFile: String? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["BIFOLD_MCP_TRACE"]
        #else
        nil
        #endif
    }()

    static func trace(_ direction: String, _ data: Data) {
        guard let path = traceFile else { return }
        let line = Data("\(direction) \(String(decoding: data.prefix(4000), as: UTF8.self))\n".utf8)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        fchmod(fd, 0o600)
        try? Wire.writeAll(line, to: fd)
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

    /// Zamyka deskryptor (raz) — wywoływane na `writeQueue`.
    private nonisolated func closeDescriptor() {
        fdClosed.withLock { done in
            guard !done else { return }
            done = true
            close(fd)
        }
    }

    public func connect() async throws {
        guard !started, !closed else { return }
        started = true
        let fd = fd, continuation = continuation, onClose = onClose, queue = writeQueue
        let reader = Thread { [self] in
            while true {
                do {
                    let frame = try Wire.readFrame(from: fd)
                    SocketTransport.trace("→", frame)
                    continuation.yield(SocketTransport.normalizeIncoming(frame))
                } catch {
                    continuation.finish()
                    // Zamknięcie po ostatnim zapisie w kolejce; wątek czytający już nie czyta.
                    queue.async { self.closeDescriptor() }
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
        let started = started, fd = fd
        writeQueue.async { [self] in
            guard !fdClosed.withLock({ $0 }) else { return }
            if started {
                // Budzi wątek czytający (EOF) — to on zamknie deskryptor.
                shutdown(fd, SHUT_RDWR)
            } else {
                closeDescriptor()
            }
        }
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        guard !closed else { throw MCPError.connectionClosed }
        let fd = fd
        SocketTransport.trace("←", data)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Swift.Error>) in
            writeQueue.async { [self] in
                guard !fdClosed.withLock({ $0 }) else {
                    c.resume(throwing: MCPError.connectionClosed)
                    return
                }
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
