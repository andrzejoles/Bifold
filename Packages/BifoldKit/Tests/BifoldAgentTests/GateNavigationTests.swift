import BifoldCore
import BifoldWorkspace
import Foundation
import MCP
import Testing
@testable import BifoldAgent

/// Nawigacja agenta: jedna funkcja celu dla bramki i komendy (`Workspace.navigationText`), znaki
/// sterujące w ścieżkach odrzucane, a karta, która po wywołaniu agenta stanęła w zablokowanym
/// katalogu, wraca do poprzedniego stanu (`blocked_path`).
@MainActor @Suite(.serialized) struct GateNavigationTests {
    func call(_ env: AgentEnv, _ session: AgentSession, _ tool: String, _ args: [String: Value] = [:]) async -> (String, Bool) {
        let r = await env.controller.callTool(tool, arguments: args, sessionID: session.id)
        let text = r.content.compactMap { if case let .text(t, _, _) = $0 { t } else { nil } }.joined()
        return (text, r.isError ?? false)
    }

    func blockedDir(_ env: AgentEnv) throws -> String {
        try env.tmp.file("sekrety/klucz", "TAJNE")
        try env.tmp.file("jawny/a.txt", "a")
        let base = env.tmp.url.path
        env.workspace.settings.agent.blockedPaths = [base + "/sekrety"]
        return base
    }

    /// Bramka przycinała `.whitespaces` (bez `\n`, U+2028), komenda — `.newlines`: „sekrety\n” przechodziło
    /// bramkę jako inny katalog i panel stawał w zablokowanym.
    @Test func lineBreaksInNavigatePathCannotBypassBlockedDirectory() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let base = try blockedDir(env)
        let (session, _) = env.session()
        let tab = env.workspace.activeTab
        for suffix in ["\n", "\r\n", "\u{2028}", "\u{2029}", "\u{85}"] {
            for path in [base + "/sekrety" + suffix, "sekrety" + suffix] {
                let (text, isError) = await call(env, session, "navigate", ["path": .string(path)])
                #expect(isError && (text.contains("permission_denied") || text.contains("blocked_path")), "\(path.debugDescription): \(text)")
                #expect(env.workspace.activeTab === tab && tab.path == env.tmp.path, "\(path.debugDescription) → \(tab.path)")
            }
        }
        // Także w innych argumentach ścieżkowych (lista ścieżek, nowa karta).
        let (sel, selErr) = await call(env, session, "set_selection", ["names": ["sekrety\n"]])
        #expect(selErr && sel.contains("permission_denied"), "\(sel)")
        let (open, openErr) = await call(env, session, "tab_open", ["path": .string(base + "/sekrety\u{2028}")])
        #expect(openErr && env.workspace.activePanel.tabs.count == 1, "\(open)")
        // Zwykła nawigacja nadal działa.
        let (ok, okErr) = await call(env, session, "navigate", ["path": "jawny"])
        #expect(!okErr && env.workspace.activeTab.path.path == base + "/jawny", "\(ok)")
    }

    /// Katalog „Projekt ” (spacja na końcu) jest osiągalny dla agenta — bramka nie obcina już spacji
    /// inaczej niż komenda; nieistniejąca ścieżka ze spacją nadal trafia do katalogu bez spacji.
    @Test func trailingSpaceDirectoryIsReachable() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let base = try blockedDir(env)
        try env.tmp.dir("Projekt ")
        let (session, _) = env.session()
        let (text, isError) = await call(env, session, "navigate", ["path": .string(base + "/Projekt ")])
        #expect(!isError, "\(text)")
        #expect(env.workspace.activeTab.path.path == base + "/Projekt ")
        try await env.workspace.activeTab.navigate(to: env.tmp.path)
        let (trimmed, trimmedErr) = await call(env, session, "navigate", ["path": "jawny  "])
        #expect(!trimmedErr && env.workspace.activeTab.path.path == base + "/jawny", "\(trimmed)")
        // Spacje nie omijają blokady.
        try await env.workspace.activeTab.navigate(to: env.tmp.path)
        let (blocked, blockedErr) = await call(env, session, "navigate", ["path": " sekrety "])
        #expect(blockedErr && blocked.contains("blocked_path"), "\(blocked)")
        #expect(env.workspace.activeTab.path == env.tmp.path)
    }

    /// Ścieżka serwera ze spacją na końcu (`prod:/var/log `) — spacje obcinane jak przed rundą 4,
    /// tak samo w bramce (zamrożony argument) i w funkcji komendy.
    @Test func remotePathTrailingSpaceIsTrimmed() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.workspace.remotes.save(RemoteConnection(alias: "prod", kind: .sftp, host: "127.0.0.1", port: 1, user: "u"), secret: nil)
        #expect(env.workspace.navigationText("prod:/var/log ", relativeTo: env.tmp.path) == "prod:/var/log")
        #expect(env.workspace.parsePath(env.workspace.navigationText(" prod:/var/log \n", relativeTo: env.tmp.path), relativeTo: env.tmp.path)
            == VFSPath(provider: RemoteFS.providerID("prod"), path: "/var/log"))
        let descriptor = try #require(env.workspace.registry.command("panel.navigate")).descriptor
        let freezer = ArgumentFreezer(workspace: env.workspace, blocked: BlockedPaths(for: env.workspace))
        let frozen = try freezer.freeze(descriptor, CommandArguments(["path": .string("prod:/var/log ")]))
        #expect(frozen.arguments.string("path") == "prod:/var/log")
        #expect(frozen.resources.contains { $0.path == VFSPath(provider: RemoteFS.providerID("prod"), path: "/var/log") })
    }

    /// Obrona w głąb: Wstecz do zablokowanego katalogu z historii karty albo wybór karty otwartej w nim
    /// przez użytkownika — bramka nie zna celu, więc stan karty jest przywracany po wywołaniu.
    @Test func historyAndTabSwitchIntoBlockedDirectoryAreReverted() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let base = try blockedDir(env)
        let tab = env.workspace.activeTab
        try await tab.navigate(to: .local(base + "/sekrety"))
        try await tab.navigate(to: .local(base + "/jawny"))
        let (session, _) = env.session()

        let (back, backErr) = await call(env, session, "run_command", ["command": "panel.back"])
        #expect(backErr && back.contains("blocked_path"), "\(back)")
        #expect(env.workspace.activeTab === tab && tab.path.path == base + "/jawny")

        // Karta użytkownika w zablokowanym katalogu.
        let panel = env.workspace.activePanel
        let userTab = panel.newTab(at: .local(base + "/sekrety"), activate: false)
        try await userTab.navigate(to: .local(base + "/sekrety"))
        let index = try #require(panel.tabs.firstIndex { $0 === userTab })
        let (sw, swErr) = await call(env, session, "tab_switch", ["index": .int(index)])
        #expect(swErr && sw.contains("blocked_path"), "\(sw)")
        #expect(panel.activeTab === tab)
        // Karta, w której użytkownik już był w zablokowanym katalogu, nie jest cofana (to nie skutek agenta).
        panel.selectTab(id: userTab.id)
        let (state, stateErr) = await call(env, session, "get_state")
        #expect(!stateErr && state.contains("«zablokowana»") && !state.contains("klucz"), "\(state)")
        #expect(panel.activeTab === userTab)
    }
}
