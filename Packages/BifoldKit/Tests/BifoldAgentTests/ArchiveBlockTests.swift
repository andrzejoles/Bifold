import BifoldCore
import BifoldWorkspace
import Foundation
import MCP
import Testing
@testable import BifoldAgent

/// Archiwum w zablokowanym katalogu: karta otwarta w nim przez użytkownika (albo w historii) nie daje
/// agentowi dostępu do wpisów — blokada sprawdza lokalną ścieżkę pliku archiwum. Elementy kart wyników
/// wyszukiwania sprawdzane po ich prawdziwych ścieżkach.
@MainActor @Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/7zz")))
struct ArchiveBlockTests {
    func call(_ env: AgentEnv, _ session: AgentSession, _ tool: String, _ args: [String: Value] = [:]) async -> (String, Bool) {
        let r = await env.controller.callTool(tool, arguments: args, sessionID: session.id)
        let text = r.content.compactMap { if case let .text(t, _, _) = $0 { t } else { nil } }.joined()
        return (text, r.isError ?? false)
    }

    @Test func entriesOfArchiveInBlockedDirectoryAreBlocked() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("sekrety/src/klucz.txt", "TAJNE-HASLO")
        try env.tmp.file("jawny/b.txt", "b")
        let base = env.tmp.url.path
        let zip = VFSPath.local(base + "/sekrety/k.zip")
        try SevenZip(executable: "/opt/homebrew/bin/7zz").create(zip, format: .zip, base: .local(base + "/sekrety/src"), names: ["klucz.txt"], password: nil)
        env.workspace.settings.agent.blockedPaths = [base + "/sekrety"]

        // Użytkownik otwiera archiwum w lewym panelu; prawy — jawny katalog.
        let left = env.workspace.left.activeTab
        try await env.workspace.enterArchive(zip, in: left)
        try await env.workspace.right.activeTab.navigate(to: .local(base + "/jawny"))
        env.workspace.activeSide = .left
        #expect(left.isInArchive)
        let entry = try #require(left.items.first { $0.name == "klucz.txt" }?.path)
        left.moveCursor(to: try #require(left.visibleItems.firstIndex { $0.path == entry }))

        let blocked = BlockedPaths(for: env.workspace)
        #expect(blocked.isBlocked(left.path) && blocked.isBlocked(entry) && blocked.containsBlocked(left.path))

        let (session, _) = env.session()
        env.approver.answer = true
        let (copy, copyErr) = await call(env, session, "copy", ["destination": .string(base + "/jawny"), "wait": true])
        #expect(copyErr && copy.contains("blocked_path"), "\(copy)")
        #expect(!env.tmp.exists("jawny/klucz.txt") && env.approver.requests.isEmpty)
        let (cmp, cmpErr) = await call(env, session, "compare_files", ["right": .string(base + "/jawny/b.txt")])
        #expect(cmpErr && cmp.contains("blocked_path") && !cmp.contains("TAJNE"), "\(cmp)")
        let (state, _) = await call(env, session, "get_state")
        #expect(state.contains("«zablokowana»") && !state.contains("klucz"), "\(state)")
        let (sel, _) = await call(env, session, "get_selection")
        #expect(!sel.contains("klucz") && !sel.contains("k.zip"), "\(sel)")

        // Wyniki wyszukiwania (użytkownika) z elementem w zablokowanym katalogu.
        let results = try await env.workspace.showResults(title: "w", items: [try LocalFS().itemSync(at: .local(base + "/sekrety/src/klucz.txt"))], side: .right)
        let item = VFSPath(provider: results.path.provider, path: base + "/sekrety/src/klucz.txt")
        #expect(blocked.isBlocked(item) && !blocked.isBlocked(results.path))
    }
}
