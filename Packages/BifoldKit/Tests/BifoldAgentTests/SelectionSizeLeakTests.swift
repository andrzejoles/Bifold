import BifoldCore
import BifoldWorkspace
import Foundation
import MCP
import Testing
@testable import BifoldAgent

/// Rozmiar katalogu-przodka zablokowanej ścieżki nie trafia do agenta przez zaznaczenie
/// (`selection.toggle` liczy rozmiar katalogu, `get_selection` oddawał `directorySizes`) —
/// odejmując rozmiary jawnych podkatalogów, agent poznałby rozmiar i liczbę plików `~/.ssh`.
@MainActor @Suite(.serialized) struct SelectionSizeLeakTests {
    func call(_ env: AgentEnv, _ session: AgentSession, _ tool: String, _ args: [String: Value] = [:]) async -> (String, Bool) {
        let r = await env.controller.callTool(tool, arguments: args, sessionID: session.id)
        let text = r.content.compactMap { if case let .text(t, _, _) = $0 { t } else { nil } }.joined()
        return (text, r.isError ?? false)
    }

    func waitForSize(_ tab: Tab, _ path: VFSPath) async {
        let deadline = Date().addingTimeInterval(5)
        while tab.directorySizes[path] == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func selectionDoesNotRevealSizeOfAncestorOfBlockedPath() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("dom/.ssh/id_ed25519", String(repeating: "k", count: 411))
        try env.tmp.file("dom/a.txt", "a")
        try env.tmp.file("jawny/b.txt", "bb")
        let base = env.tmp.url.path
        env.workspace.settings.agent.blockedPaths = [base + "/dom/.ssh"]
        let tab = env.workspace.activeTab
        await tab.reload()
        let dom = VFSPath.local(base + "/dom")
        let jawny = VFSPath.local(base + "/jawny")
        let (session, _) = env.session()

        // Agent: kursor na katalogu, Spacja (zaznaczenie liczy rozmiar), odczyt zaznaczenia.
        let (cur, curErr) = await call(env, session, "set_cursor", ["name": "dom"])
        #expect(!curErr && tab.cursorItem?.path == dom, "\(cur)")
        let (toggle, toggleErr) = await call(env, session, "run_command", ["command": "selection.toggle"])
        #expect(!toggleErr, "\(toggle)")
        #expect(tab.selection.contains(dom))
        // Rozmiar katalogu z blokadą w poddrzewie nie jest dla agenta nawet liczony.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(tab.directorySizes[dom] == nil)
        let (sel, selErr) = await call(env, session, "get_selection")
        #expect(!selErr && sel.contains("/dom"), "\(sel)")
        #expect(!sel.contains("\"size\"") && !sel.contains("\"files\"") && !sel.contains("411"), "\(sel)")

        // Rozmiar policzony przez użytkownika (Spacja w oknie) też nie przecieka.
        if let item = tab.items.first(where: { $0.path == dom }) { tab.calculateSize(of: item) }
        await waitForSize(tab, dom)
        #expect(tab.directorySizes[dom] != nil)
        let (user, _) = await call(env, session, "get_selection")
        #expect(!user.contains("\"size\"") && !user.contains("411"), "\(user)")

        // Jawny katalog — rozmiar jest.
        tab.clearSelection()
        _ = await call(env, session, "set_cursor", ["name": "jawny"])
        _ = await call(env, session, "run_command", ["command": "selection.toggle"])
        await waitForSize(tab, jawny)
        let (ok, _) = await call(env, session, "get_selection")
        #expect(ok.contains("\"size\":2") && ok.contains("\"files\":1"), "\(ok)")
    }
}
