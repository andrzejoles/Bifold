import BifoldBridgeKit
import BifoldCore
import Darwin
import Foundation
import Testing
@testable import BifoldAgent

/// Gniazdo serwera agenta i połączenia sesji nie mogą przechodzić do procesów uruchamianych przez
/// `forkpty` (terminal, CLI agenta) — inaczej jedna sesja agenta przejmowałaby połączenia innej.
@MainActor @Suite(.serialized) struct DescriptorInheritanceTests {
    /// Ścieżka gniazda Unix, z którym związany jest deskryptor (`nil` dla innych deskryptorów).
    static func unixPath(_ fd: Int32) -> String? {
        var addr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard rc == 0, addr.sun_family == sa_family_t(AF_UNIX) else { return nil }
        return withUnsafeBytes(of: addr.sun_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    @Test func serverAndSessionSocketsAreCloseOnExec() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let (_, token) = env.session()
        let client = try BridgeClient(socket: env.socket, token: token)
        defer { client.terminate() }
        try await client.initialize()
        let path = env.socket.path(percentEncoded: false)
        let sockets = FileDescriptors.openDescriptors().filter { Self.unixPath($0) == path }
        // Gniazdo nasłuchujące i przyjęte połączenie sesji.
        #expect(sockets.count >= 2)
        for fd in sockets { #expect(FileDescriptors.isCloseOnExec(fd), "deskryptor \(fd) przeszedłby do terminala") }
    }

    @Test func markAllCloseOnExecCoversInheritableDescriptors() throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        #expect(!FileDescriptors.isCloseOnExec(fds[0]) && !FileDescriptors.isCloseOnExec(fds[1]))
        #expect(FileDescriptors.openDescriptors().contains(fds[0]))
        FileDescriptors.markAllCloseOnExec()
        #expect(FileDescriptors.isCloseOnExec(fds[0]) && FileDescriptors.isCloseOnExec(fds[1]))
        #expect(!FileDescriptors.isCloseOnExec(STDERR_FILENO))
    }
}
