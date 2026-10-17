import Darwin
import Foundation

/// Most MCP: stdio (wiadomości JSON rozdzielone znakiem nowej linii) ⇄ gniazdo Unix aplikacji.
/// Most nie interpretuje wiadomości — cała logika i polityka uprawnień są w aplikacji.
public enum Bridge {
    public static let tokenVariable = "BIFOLD_AGENT_TOKEN"
    public static let socketVariable = "BIFOLD_AGENT_SOCKET"

    public struct Options {
        public var socketPath: String
        public var token: String

        public init(socketPath: String, token: String) {
            self.socketPath = socketPath
            self.token = token
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case missingToken
        case missingSocket
        case rejected(String)
        case connection(String)

        public var description: String {
            switch self {
            case .missingToken: "brak \(Bridge.tokenVariable) — most działa tylko w sesji agenta uruchomionej z aplikacji"
            case .missingSocket: "brak ścieżki gniazda (--socket)"
            case .rejected(let m): "aplikacja odrzuciła połączenie: \(m)"
            case .connection(let m): "nie można połączyć się z aplikacją: \(m)"
            }
        }
    }

    /// Opcje z argumentów (`--socket <ścieżka>`) i środowiska. Token: zmienna środowiskowa
    /// procesu, a jeśli CLI agenta jej nie przekazało — środowisko najbliższego przodka
    /// (proces CLI uruchomiony przez aplikację), nigdy plik ani argument.
    public static func options(arguments: [String], environment: [String: String]) throws -> Options {
        var socket = environment[socketVariable]
        if let i = arguments.firstIndex(of: "--socket"), i + 1 < arguments.count { socket = arguments[i + 1] }
        guard let socket, !socket.isEmpty else { throw Failure.missingSocket }
        if let token = environment[tokenVariable], !token.isEmpty {
            return Options(socketPath: socket, token: token)
        }
        for pid in ProcessTree.ancestry(of: getpid()).dropFirst() {
            if let token = ProcessTree.environmentValue(tokenVariable, of: pid), !token.isEmpty {
                return Options(socketPath: socket, token: token)
            }
        }
        throw Failure.missingToken
    }

    /// Łączy się, przechodzi uzgadnianie i przekazuje dane do końca jednego ze strumieni.
    public static func run(_ options: Options, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) throws {
        let fd: Int32
        do {
            fd = try Wire.connect(path: options.socketPath)
        } catch {
            throw Failure.connection("\(error)")
        }
        defer { close(fd) }

        let hello = Wire.Hello(token: options.token, pid: getpid())
        try Wire.writeFrame(JSONEncoder().encode(hello), to: fd)
        Wire.setReadTimeout(fd, seconds: 10)
        let replyData: Data
        do {
            replyData = try Wire.readFrame(from: fd)
        } catch {
            throw Failure.rejected("brak odpowiedzi (\(error))")
        }
        let reply = try JSONDecoder().decode(Wire.Reply.self, from: replyData)
        guard reply.type == "welcome" else { throw Failure.rejected(reply.message ?? "?") }
        Wire.setReadTimeout(fd, seconds: 0)

        // gniazdo → stdout
        let socketToStdout = Thread {
            while true {
                guard let frame = try? Wire.readFrame(from: fd) else { break }
                var line = frame
                line.append(0x0A)
                if (try? Wire.writeAll(line, to: output)) == nil { break }
            }
            // Aplikacja zamknęła sesję — kończymy proces mostu.
            exit(0)
        }
        socketToStdout.start()

        // stdin → gniazdo (linie)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(input, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let trimmed = line.filter { $0 != 0x0D }
                if trimmed.isEmpty { continue }
                try Wire.writeFrame(Data(trimmed), to: fd)
            }
            if buffer.count > Wire.maxFrame { throw Failure.connection("za długa wiadomość") }
        }
        shutdown(fd, SHUT_WR)
    }
}
