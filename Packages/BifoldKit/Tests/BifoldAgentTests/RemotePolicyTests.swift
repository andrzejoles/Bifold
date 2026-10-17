import BifoldCore
import BifoldWorkspace
import Foundation
import MCP
import Testing
@testable import BifoldAgent

@MainActor @Suite(.serialized, .enabled(if: rclonePath != nil)) struct RemotePolicyTests {
    func call(_ env: AgentEnv, _ session: AgentSession, _ tool: String, _ args: [String: Value]) async -> (String, Bool) {
        let r = await env.controller.callTool(tool, arguments: args, sessionID: session.id)
        let text = r.content.compactMap { if case let .text(t, _, _) = $0 { t } else { nil } }.joined()
        return (text, r.isError ?? false)
    }

    @Test func leastPrivilegeAcrossServers() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown(); env.workspace.remotes.stop() }
        let sftp = try TestServer("sftp")
        let ftp = try TestServer("ftp")
        try sftp.root.file("logi/app.log", "linia z serwera")
        try ftp.root.file("pub/plik.txt", "ftp")
        try env.tmp.file("lokalny.txt", "L")
        let remotes = env.workspace.remotes!
        try remotes.save(RemoteConnection(alias: "prod-logi", kind: .sftp, host: "127.0.0.1", port: sftp.port, user: "u"), secret: "tajne")
        try remotes.save(RemoteConnection(alias: "ftp-pub", kind: .ftp, host: "127.0.0.1", port: ftp.port, user: "u"), secret: "tajne")
        defer { remotes.keychain.delete("prod-logi"); remotes.keychain.delete("ftp-pub") }
        let (session, _) = env.session()

        // Odczyt z SFTP — dozwolony, tylko po aliasie.
        let (list, listErr) = await call(env, session, "remote_list", ["alias": "prod-logi", "path": "/logi"])
        #expect(!listErr && list.contains("app.log"), "\(list)")
        #expect(!list.contains("127.0.0.1"))
        let (read, _) = await call(env, session, "remote_read", ["alias": "prod-logi", "path": "/logi/app.log"])
        #expect(read.contains("linia z serwera"))
        let (conns, _) = await call(env, session, "remote_connections", [:])
        #expect(conns.contains("prod-logi") && !conns.contains("127.0.0.1") && !conns.contains("\"u\""))

        // Zapis na SFTP — zabroniony nawet po zgodzie.
        env.approver.answer = true
        let (up, upErr) = await call(env, session, "copy", ["paths": [.string(env.tmp.url.path + "/lokalny.txt")], "destination": "prod-logi:/logi", "wait": true])
        #expect(upErr && up.contains("permission_denied"), "\(up)")
        #expect(!sftp.root.exists("logi/lokalny.txt"))
        let (mk, mkErr) = await call(env, session, "navigate", ["path": "prod-logi:/logi"])
        #expect(!mkErr, "\(mk)")
        let (mkdir, mkdirErr) = await call(env, session, "mkdir", ["name": "nowy"])
        #expect(mkdirErr && mkdir.contains("permission_denied"))

        // Zapis na FTP — za zgodą.
        env.approver.requests = []
        env.approver.answer = false
        let (denied, deniedErr) = await call(env, session, "copy", ["paths": [.string(env.tmp.url.path + "/lokalny.txt")], "destination": "ftp-pub:/pub", "wait": true])
        #expect(deniedErr && denied.contains("rejected_by_user") && env.approver.requests.count == 1)
        env.approver.answer = true
        let (_, okErr) = await call(env, session, "copy", ["paths": [.string(env.tmp.url.path + "/lokalny.txt")], "destination": "ftp-pub:/pub", "wait": true])
        #expect(!okErr)
        #expect(try ftp.root.read("pub/lokalny.txt") == "L")

        // FTP → SFTP (zasób tylko do odczytu) — zabronione.
        _ = await call(env, session, "navigate", ["path": "ftp-pub:/pub"])
        let (cross, crossErr) = await call(env, session, "copy", ["paths": ["ftp-pub:/pub/plik.txt"], "destination": "prod-logi:/logi", "wait": true])
        #expect(crossErr && cross.contains("permission_denied"), "\(cross)")
        #expect(!sftp.root.exists("logi/plik.txt"))
    }
}
