import BifoldBridgeKit
import BifoldCore
import Darwin
import Foundation
import Synchronization

/// Wynik próby połączenia (do dziennika i testów).
public enum ConnectionEvent: Sendable, Equatable {
    case accepted(sessionID: String, pid: pid_t)
    case rejected(reason: String, pid: pid_t?)
}

/// Serwer gniazda Unix dla mostów `bifold-mcp`. Bez portów TCP. Każde połączenie przechodzi:
/// UID rozmówcy → ramka `hello` z tokenem (≤ 5 s) → token w stałym czasie → PID mostu musi
/// pochodzić od procesu CLI sesji. Dopiero potem połączenie trafia do `onAccept`.
public final class AgentServer: @unchecked Sendable {
    public let socketURL: URL
    let registry: SessionRegistry
    let onAccept: @Sendable (Int32, AgentSession) -> Void
    let onEvent: @Sendable (ConnectionEvent) -> Void
    private let state = Mutex<(fd: Int32, running: Bool)>((-1, false))
    /// Wyłącza sprawdzanie przodków (tylko testy jednostkowe uwierzytelniania).
    var verifyAncestry = true
    public var helloTimeout: Double = 5

    public init(
        socketURL: URL, registry: SessionRegistry,
        onAccept: @escaping @Sendable (Int32, AgentSession) -> Void,
        onEvent: @escaping @Sendable (ConnectionEvent) -> Void = { _ in }
    ) {
        self.socketURL = socketURL
        self.registry = registry
        self.onAccept = onAccept
        self.onEvent = onEvent
    }

    public enum StartError: Error, Equatable {
        case insecureDirectory(String)
        case socket(Int32)
        case pathTooLong
    }

    public func start() throws {
        let dir = socketURL.deletingLastPathComponent().path(percentEncoded: false)
        try Self.prepareDirectory(dir)
        let path = socketURL.path(percentEncoded: false)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw StartError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw StartError.socket(e)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            throw StartError.socket(e)
        }
        state.withLock { $0 = (fd, true) }
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "bifold.agent.accept"
        thread.start()
    }

    public func stop() {
        let fd = state.withLock { s -> Int32 in
            let fd = s.fd
            s = (-1, false)
            return fd
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(socketURL.path(percentEncoded: false))
    }

    /// Katalog gniazda: tworzony z 0700, musi należeć do bieżącego użytkownika i nie być dowiązaniem.
    static func prepareDirectory(_ dir: String) throws {
        var st = stat()
        if lstat(dir, &st) != 0 {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(dir, &st) == 0 else { throw StartError.insecureDirectory(dir) }
        }
        guard st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { throw StartError.insecureDirectory(dir) }
        if st.st_mode & 0o777 != 0o700 { chmod(dir, 0o700) }
    }

    private func acceptLoop(_ listenFD: Int32) {
        while state.withLock({ $0.running }) {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread { [self] in handshake(client) }
            t.name = "bifold.agent.handshake"
            t.start()
        }
    }

    private func reject(_ fd: Int32, _ reason: String, pid: pid_t?) {
        // Zdarzenie przed odpowiedzią: kto odczyta odmowę, widzi ją już w dzienniku połączeń.
        onEvent(.rejected(reason: reason, pid: pid))
        if let data = try? JSONEncoder().encode(Wire.Reply.error(reason)) { try? Wire.writeFrame(data, to: fd) }
        close(fd)
    }

    func handshake(_ fd: Int32) {
        // 1. UID rozmówcy.
        guard let peer = PeerCredentials.of(fd) else {
            reject(fd, "peer_unknown", pid: nil)
            return
        }
        guard peer.uid == getuid() else {
            reject(fd, "peer_uid", pid: peer.pid)
            return
        }
        // 2. Ramka hello z tokenem w ograniczonym czasie.
        Wire.setReadTimeout(fd, seconds: helloTimeout)
        guard let data = try? Wire.readFrame(from: fd), data.count < 4096,
              let hello = try? JSONDecoder().decode(Wire.Hello.self, from: data), hello.type == "hello"
        else {
            reject(fd, "no_hello", pid: peer.pid)
            return
        }
        // 3. Token (stały czas).
        guard let session = registry.authenticate(token: hello.token) else {
            reject(fd, "bad_token", pid: peer.pid)
            return
        }
        // 4. Proces po drugiej stronie musi być potomkiem procesu CLI tej sesji.
        if verifyAncestry {
            guard let cli = session.cliPID, ProcessTree.ancestry(of: peer.pid).contains(cli) else {
                reject(fd, "not_descendant", pid: peer.pid)
                return
            }
        }
        Wire.setReadTimeout(fd, seconds: 0)
        guard let welcome = try? JSONEncoder().encode(Wire.Reply.welcome), (try? Wire.writeFrame(welcome, to: fd)) != nil else {
            close(fd)
            return
        }
        onEvent(.accepted(sessionID: session.id, pid: peer.pid))
        onAccept(fd, session)
    }
}

/// UID i PID procesu po drugiej stronie gniazda Unix.
public enum PeerCredentials {
    // <sys/un.h>: SOL_LOCAL 0, LOCAL_PEERPID 0x002
    static let solLocal: Int32 = 0
    static let localPeerPID: Int32 = 0x002

    public static func of(_ fd: Int32) -> (uid: uid_t, pid: pid_t)? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, solLocal, localPeerPID, &pid, &len) == 0, pid > 0 else { return nil }
        return (uid, pid)
    }
}
