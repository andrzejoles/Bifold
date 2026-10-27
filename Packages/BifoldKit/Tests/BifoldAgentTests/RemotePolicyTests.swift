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
        defer { try? remotes.keychain.delete("prod-logi"); try? remotes.keychain.delete("ftp-pub") }
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

    /// Synchronizacja z domyślnymi końcami (drugi panel na SFTP) i zapisane zadanie z celem SFTP
    /// podlegają zasadzie najmniejszego poziomu — zapis na SFTP jest dla agenta zabroniony nawet za zgodą.
    @Test func syncToReadOnlyServerIsDenied() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown(); env.workspace.remotes.stop() }
        let sftp = try TestServer("sftp")
        try sftp.root.file("logi/app.log", "linia")
        // Katalog źródłowy bez katalogu danych testu (.support — zablokowany jak dane aplikacji).
        try env.tmp.file("src/lokalny.txt", "L")
        try await env.workspace.left.activeTab.navigate(to: env.tmp.path.appending("src"))
        let remotes = env.workspace.remotes!
        try remotes.save(RemoteConnection(alias: "prod-logi", kind: .sftp, host: "127.0.0.1", port: sftp.port, user: "u"), secret: "tajne")
        defer { try? remotes.keychain.delete("prod-logi") }
        let (session, _) = env.session()
        env.approver.answer = true

        // Drugi panel na serwerze, synchronizacja bez jawnych końców.
        let (nav, navErr) = await call(env, session, "navigate", ["path": "prod-logi:/logi", "side": "right"])
        #expect(!navErr, "\(nav)")
        env.workspace.activeSide = .left
        #expect(RemoteFS.alias(of: env.workspace.otherTab.path) == "prod-logi")
        let (run, runErr) = await call(env, session, "sync_run", ["mode": "mirror"])
        #expect(runErr && run.contains("permission_denied"), "\(run)")
        #expect(env.approver.requests.isEmpty)

        // Zapisane zadanie (np. przez użytkownika) z celem na SFTP.
        env.workspace.syncJobs = [SyncJob(name: "na-serwer", source: env.tmp.url.path + "/src", destination: "prod-logi:/logi", mode: .mirror)]
        let (saved, savedErr) = await call(env, session, "sync_job_run", ["name": "na-serwer"])
        #expect(savedErr && saved.contains("permission_denied"), "\(saved)")
        #expect(env.approver.requests.isEmpty)
        #expect(!sftp.root.exists("logi/lokalny.txt"))
        #expect(sftp.root.exists("logi/app.log"))
    }
}
