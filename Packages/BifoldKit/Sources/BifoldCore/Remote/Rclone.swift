import Darwin
import Foundation
import Synchronization

public enum RemoteError: Error, LocalizedError, Equatable, Sendable {
    case toolMissing
    case notRunning
    case rc(String, status: Int)
    case protocolError(String)
    case unknownRemote(String)
    case ssh(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing: L10n.tr("Serwery i chmury wymagają rclone (brew install rclone)")
        case .notRunning: L10n.tr("rclone nie działa")
        case let .rc(m, status): L10n.tr("rclone (\(status)): \(m)")
        case .protocolError(let m): L10n.tr("rclone: błąd protokołu (\(m))")
        case .ssh(let m): "SSH: \(m)"
        case .unknownRemote(let a): L10n.tr("Nieznane połączenie: \(a)")
        }
    }
}

/// Koordynator limitu prędkości: `core/bwlimit` działa na wszystkie transfery procesu rclone naraz,
/// więc limit wynika ze wszystkich zadań — najmniejszy z limitów zadań niewstrzymanych, a 1 B/s
/// (pauza — rclone nie ma pauzy zadania) tylko wtedy, gdy wstrzymane są wszystkie.
public final class RcloneBandwidth: Sendable {
    struct Entry: Sendable, Equatable {
        var paused: Bool
        var limit: Int64
    }

    private let state = Mutex<(entries: [UUID: Entry], applied: String?)>(([:], nil))
    private let apply: @Sendable (String) -> Void

    public init(apply: @escaping @Sendable (String) -> Void) {
        self.apply = apply
    }

    static func rate(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "off" }
        let running = entries.filter { !$0.paused }
        guard !running.isEmpty else { return "1" }
        return running.map(\.limit).filter { $0 > 0 }.min().map { "\($0)" } ?? "off"
    }

    public func update(_ id: UUID, paused: Bool, limit: Int64) {
        change { $0[id] = Entry(paused: paused, limit: limit) }
    }

    public func remove(_ id: UUID) {
        change { $0[id] = nil }
    }

    /// Zmiana i ustawienie limitu pod blokadą (kolejność wywołań `core/bwlimit` = kolejność zmian).
    private func change(_ body: (inout [UUID: Entry]) -> Void) {
        state.withLock { s in
            body(&s.entries)
            let rate = Self.rate(Array(s.entries.values))
            if rate != s.applied {
                s.applied = rate
                apply(rate)
            }
        }
    }
}

/// Proces `rclone rcd` z API zdalnego sterowania na gnieździe Unix (bez portów TCP) i z
/// konfiguracją tylko w pamięci (`--config ""`) — dane logowania nie trafiają do pliku.
public final class Rclone: Sendable {
    public let executable: String
    public let socket: URL
    private let process = Mutex<Process?>(nil)
    /// Wspólny limit prędkości wszystkich zadań tego procesu (`core/bwlimit` jest globalny).
    public let bandwidth: RcloneBandwidth

    public init(executable: String, socket: URL) {
        self.executable = executable
        self.socket = socket
        let path = socket.path
        bandwidth = RcloneBandwidth { rate in
            _ = try? Rclone.decode(Rclone.post(socket: path, path: "/core/bwlimit", body: Data(#"{"rate":"\#(rate)"}"#.utf8)))
        }
    }

    public var isRunning: Bool { process.withLock { $0?.isRunning ?? false } }

    /// Plik z PID procesu `rcd` (obok gniazda) — po awarii aplikacji stary proces z hasłami w pamięci
    /// jest zamykany przy następnym starcie.
    var pidFile: String { socket.deletingPathExtension().path + ".pid" }

    public func start() throws {
        if isRunning { return }
        let dir = socket.deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        killOrphan()
        unlink(socket.path)
        let p = Process()
        p.executableURL = URL(filePath: executable)
        p.arguments = ["rcd", "--rc-addr", "unix://" + socket.path, "--rc-no-auth", "--config", "", "--rc-job-expire-duration", "10m", "--log-level", "NOTICE"]
        var env = ProcessInfo.processInfo.environment
        // Bez dziedziczenia ewentualnej konfiguracji rclone użytkownika.
        env.removeValue(forKey: "RCLONE_CONFIG")
        env.removeValue(forKey: "RCLONE_CONFIG_PASS")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process.withLock { $0 = p }
        FileManager.default.createFile(atPath: pidFile, contents: Data("\(p.processIdentifier)\n".utf8), attributes: [.posixPermissions: 0o600])
        // Czekamy na gniazdo.
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socket.path), (try? callSync("rc/noop", [:])) != nil { return }
            if !p.isRunning { break }
            usleep(50_000)
        }
        // Nieudany start: proces nie może zostać osierocony.
        stop()
        throw RemoteError.notRunning
    }

    public func stop() {
        let p = process.withLock { p in
            defer { p = nil }
            return p
        }
        if let p, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning, Date() < deadline { usleep(20_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        unlink(socket.path)
        unlink(pidFile)
    }

    /// Kończy proces z pliku PID, jeśli to nadal `rclone rcd` na tym gnieździe (PID mógł zostać
    /// użyty ponownie przez inny program — wtedy nic nie robi).
    func killOrphan() {
        defer { unlink(pidFile) }
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
              let args = Self.arguments(of: pid), args.count > 1,
              (args[0] as NSString).lastPathComponent == "rclone", args.contains("rcd"), args.contains("unix://" + socket.path)
        else { return }
        kill(pid, SIGTERM)
        for _ in 0..<100 where kill(pid, 0) == 0 { usleep(20_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Argumenty procesu (`KERN_PROCARGS2`) — tylko procesy tego samego użytkownika.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        // Ścieżka programu, potem zera wyrównania, potem argv.
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    // MARK: API

    public func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: params)
        let socket = socket
        let data = try await runBlocking(qos: .userInitiated) { try Self.post(socket: socket.path, path: "/" + method, body: body) }
        return try Self.decode(data)
    }

    public func callSync(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: params)
        return try Self.decode(try Self.post(socket: socket.path, path: "/" + method, body: body))
    }

    static func decode(_ response: (status: Int, body: Data)) throws -> [String: Any] {
        let obj = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        guard (200..<300).contains(response.status) else {
            throw RemoteError.rc(obj["error"] as? String ?? String(decoding: response.body.prefix(300), as: UTF8.self), status: response.status)
        }
        return obj
    }

    /// Minimalny klient HTTP/1.1 po gnieździe Unix (`Connection: close`, obsługa chunked).
    static func post(socket path: String, path urlPath: String, body: Data) throws -> (status: Int, body: Data) {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RemoteError.notRunning }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw RemoteError.protocolError("socket path") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw RemoteError.notRunning }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var request = Data("POST \(urlPath) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        request.append(body)
        try request.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; throw RemoteError.protocolError("write") }
                off += n
            }
        }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { if errno == EINTR { continue }; throw RemoteError.protocolError("read") }
            if n == 0 { break }
            response.append(chunk, count: n)
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { throw RemoteError.protocolError("headers") }
        let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        var payload = Data(response[split.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        let status = Int(lines.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
        if lines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }) {
            payload = dechunk(payload)
        }
        return (status, payload)
    }

    static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        while i < data.endIndex {
            guard let lineEnd = data[i...].range(of: Data("\r\n".utf8)) else { break }
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[start..<end])
            i = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }

    // MARK: Wygodne operacje

    public struct ListEntry: Sendable, Hashable {
        public var name: String
        public var path: String
        public var size: Int64
        public var isDirectory: Bool
        public var modified: Date?
    }

    /// Daty RFC 3339 z ułamkami sekund (formater tworzony na wywołanie — nie jest Sendable).
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    public func list(fs: String, remote: String, recursive: Bool = false, filesOnly: Bool = false) async throws -> [ListEntry] {
        let r = try await call("operations/list", ["fs": fs, "remote": remote, "opt": ["recurse": recursive, "filesOnly": filesOnly]])
        let list = r["list"] as? [[String: Any]] ?? []
        return list.map { e in
            let mod = (e["ModTime"] as? String).flatMap(Self.parseDate)
            return ListEntry(
                name: e["Name"] as? String ?? "", path: e["Path"] as? String ?? "",
                size: (e["Size"] as? NSNumber)?.int64Value ?? 0, isDirectory: e["IsDir"] as? Bool ?? false, modified: mod)
        }
    }
}
