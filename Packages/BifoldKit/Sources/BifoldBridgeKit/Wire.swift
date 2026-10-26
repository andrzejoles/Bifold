import Darwin
import Foundation

/// Protokół gniazda między mostem `bifold-mcp` a aplikacją: ramki = 4 bajty długości
/// (big-endian) + treść. Pierwsza ramka od mostu to `hello` (JSON), odpowiedź aplikacji to
/// `welcome` albo `error`. Potem ramki niosą wiadomości MCP (JSON-RPC) bez zmian.
public enum Wire {
    public static let protocolVersion = 1
    /// Limit pojedynczej ramki — większa oznacza błąd protokołu i rozłączenie.
    public static let maxFrame = 4 * 1024 * 1024

    public enum Error: Swift.Error, Equatable {
        case closed
        case frameTooLarge(Int)
        case io(Int32)
        case timeout
    }

    /// Pierwsza ramka mostu. PID mostu aplikacja bierze z jądra (`LOCAL_PEERPID`), nie z ramki.
    public struct Hello: Codable, Sendable, Equatable {
        public var type = "hello"
        public var token: String
        public var version: Int

        public init(token: String, version: Int = Wire.protocolVersion) {
            self.token = token
            self.version = version
        }
    }

    public struct Reply: Codable, Sendable, Equatable {
        public var type: String
        public var message: String?

        public static let welcome = Reply(type: "welcome", message: nil)
        public static func error(_ message: String) -> Reply { Reply(type: "error", message: message) }
    }

    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    /// Zapis ramki (blokujący). Ramka ponad limit nie jest wysyłana — odbiorca i tak by się rozłączył.
    public static func writeFrame(_ payload: Data, to fd: Int32) throws {
        guard payload.count <= maxFrame else { throw Error.frameTooLarge(payload.count) }
        try writeAll(encode(payload), to: fd)
    }

    public static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, base + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Error.io(errno)
                }
                offset += n
            }
        }
    }

    /// Odczyt ramki (blokujący). `Error.closed` przy końcu strumienia.
    /// - Parameters:
    ///   - maxLength: limit długości sprawdzany na nagłówku, przed przydzieleniem pamięci
    ///   - deadline: bezwzględny termin całej ramki (`Error.timeout`) — powolne sączenie bajtów
    ///     nie przedłuża go, w przeciwieństwie do `SO_RCVTIMEO` liczonego dla każdego `read`.
    public static func readFrame(from fd: Int32, maxLength: Int = maxFrame, deadline: ContinuousClock.Instant? = nil) throws -> Data {
        let header = try readExactly(4, from: fd, deadline: deadline)
        let length = Int(header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard length <= min(maxLength, maxFrame) else { throw Error.frameTooLarge(length) }
        return try readExactly(length, from: fd, deadline: deadline)
    }

    static func readExactly(_ count: Int, from fd: Int32, deadline: ContinuousClock.Instant? = nil) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { buf in
            while offset < count {
                if let deadline { try waitReadable(fd, until: deadline) }
                let n = Darwin.read(fd, buf.baseAddress! + offset, count - offset)
                if n == 0 { throw Error.closed }
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw Error.timeout }
                    throw Error.io(errno)
                }
                offset += n
            }
        }
        return data
    }

    /// Czeka (poll), aż gniazdo będzie miało dane, najdłużej do terminu.
    static func waitReadable(_ fd: Int32, until deadline: ContinuousClock.Instant) throws {
        while true {
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { throw Error.timeout }
            let ms = Int32(clamping: max(1, left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000))
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, ms)
            if r > 0 { return }
            if r == 0 { throw Error.timeout }
            if errno != EINTR { throw Error.io(errno) }
        }
    }

    /// Ustawia limit czasu odczytu gniazda (0 = bez limitu).
    public static func setReadTimeout(_ fd: Int32, seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Łączy się z gniazdem Unix.
    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.io(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw Error.io(ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw Error.io(e)
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
}

/// Informacje o procesach (łańcuch rodziców, środowisko procesu tego samego użytkownika).
public enum ProcessTree {
    public static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Łańcuch od `pid` w górę do `launchd` (włącznie z `pid`).
    public static func ancestry(of pid: pid_t, limit: Int = 64) -> [pid_t] {
        var chain: [pid_t] = [pid]
        var current = pid
        while chain.count < limit, let p = parent(of: current), p > 0, p != current {
            chain.append(p)
            if p == 1 { break }
            current = p
        }
        return chain
    }

    /// Zmienna środowiskowa innego procesu tego samego użytkownika (KERN_PROCARGS2).
    public static func environmentValue(_ name: String, of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        // Ścieżka programu, potem dopełnienie zerami.
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        // argv
        var seen = 0
        while i < size, seen < argc {
            while i < size, buffer[i] != 0 { i += 1 }
            i += 1
            seen += 1
        }
        // envp
        let prefix = Array((name + "=").utf8)
        while i < size, buffer[i] != 0 {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            let entry = buffer[start..<i]
            if entry.starts(with: prefix) {
                return String(decoding: entry.dropFirst(prefix.count), as: UTF8.self)
            }
            i += 1
        }
        return nil
    }
}
