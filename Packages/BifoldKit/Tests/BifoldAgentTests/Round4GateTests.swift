import BifoldCore
import BifoldWorkspace
import Foundation
import MCP
import Testing
@testable import BifoldAgent

/// Czwarta runda przeglądu: rekurencyjne odczyty (rozmiar katalogu), baza celu kopiowania,
/// porównanie katalogów i plik sum przez bramkę.
@MainActor @Suite(.serialized) struct Round4GateTests {
    func call(_ env: AgentEnv, _ session: AgentSession, _ tool: String, _ args: [String: Value] = [:]) async -> (String, Bool) {
        let r = await env.controller.callTool(tool, arguments: args, sessionID: session.id)
        let text = r.content.compactMap { if case let .text(t, _, _) = $0 { t } else { nil } }.joined()
        return (text, r.isError ?? false)
    }

    /// Rozmiar katalogu obejmuje całe poddrzewo — przodek zablokowanej ścieżki jest odrzucany.
    @Test func dirSizeOfAncestorOfBlockedPathIsRejected() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("dom/.ssh/id_ed25519", String(repeating: "k", count: 411))
        try env.tmp.file("dom/a.txt", "a")
        try env.tmp.file("jawny/b.txt", "bb")
        let base = env.tmp.url.path
        env.workspace.settings.agent.blockedPaths = [base + "/dom/.ssh"]
        let (session, _) = env.session()
        let (text, isError) = await call(env, session, "dir_size", ["paths": [.string(base + "/dom")]])
        #expect(isError && text.contains("blocked_path"), "\(text)")
        #expect(!text.contains("411"))
        // Domyślny cel (element pod kursorem) też.
        try await env.workspace.activeTab.navigate(to: env.tmp.path, focus: "dom")
        let (implicit, implicitErr) = await call(env, session, "dir_size")
        #expect(implicitErr && implicit.contains("blocked_path"), "\(implicit)")
        let (ok, okErr) = await call(env, session, "dir_size", ["paths": [.string(base + "/jawny")]])
        #expect(!okErr && ok.contains("\"bytes\":2"), "\(ok)")
    }

    /// Względny cel kopiowania liczony jak w komendzie: od lokalnego katalogu aktywnego panelu.
    @Test func relativeCopyDestinationUsesActivePanelLikeTheCommand() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("x/plik.txt", "p")
        try env.tmp.dir("public")
        let base = env.tmp.url.path
        try await env.workspace.left.activeTab.navigate(to: .local(base + "/x"))
        try await env.workspace.right.activeTab.navigate(to: .local(base + "/public"))
        env.workspace.activeSide = .left
        env.approver.answer = true
        let (session, _) = env.session()
        let (text, isError) = await call(env, session, "copy", ["paths": [.string(base + "/x/plik.txt")], "destination": "kopia/", "wait": true])
        #expect(!isError, "\(text)")
        #expect(env.approver.requests.last?.arguments.string("destination") == base + "/x/kopia/")
        #expect(env.tmp.exists("x/kopia/plik.txt") && !env.tmp.exists("public/kopia"))
        // Blokada sprawdzana dla tej samej ścieżki, którą wykona komenda.
        env.workspace.settings.agent.blockedPaths = [base + "/x/tajne"]
        let (blocked, blockedErr) = await call(env, session, "copy", ["paths": [.string(base + "/x/plik.txt")], "destination": "tajne/", "wait": true])
        #expect(blockedErr && blocked.contains("blocked_path"), "\(blocked)")
        #expect(!env.tmp.exists("x/tajne"))
    }

    @Test func compareDirsAndChecksumVerifyThroughGateHideBlockedFiles() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("L/.netrc", "TAJNE")
        try env.tmp.file("L/a.txt", "a")
        try env.tmp.file("R/b.txt", "b")
        let base = env.tmp.url.path
        let key = try Checksums.hash(.local(base + "/L/.netrc"), algorithm: .sha256)
        try env.tmp.file("L/sumy.sha256", Checksums.format([(hash: key, relativePath: ".netrc")]))
        env.workspace.settings.agent.blockedPaths = [base + "/L/.netrc"]
        try await env.workspace.left.activeTab.navigate(to: .local(base + "/L"))
        try await env.workspace.right.activeTab.navigate(to: .local(base + "/R"))
        let (session, _) = env.session()
        let (cmp, cmpErr) = await call(env, session, "compare_dirs")
        #expect(!cmpErr && cmp.contains("a.txt") && cmp.contains("\"untrusted\":true"), "\(cmp)")
        #expect(!cmp.contains(".netrc"), "\(cmp)")
        let (sums, sumsErr) = await call(env, session, "checksum_verify", ["paths": [.string(base + "/L/sumy.sha256")]])
        #expect(!sumsErr && sums.contains("invalid") && !sums.contains("\"status\":\"ok\""), "\(sums)")
        #expect(sums.contains("\"untrusted\":true"))
    }
}
