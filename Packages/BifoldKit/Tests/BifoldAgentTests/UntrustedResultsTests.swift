import BifoldCore
import BifoldWorkspace
import Foundation
import MCP
import Testing
@testable import BifoldAgent

/// Wyniki z nazwami z dysku (woluminy, tytuły zadań, pominięte elementy cofania i zmiany nazw)
/// są dla agenta oznaczone jako niezaufane, a w dzienniku — tylko rozmiar i skrót.
@MainActor @Suite(.serialized) struct UntrustedResultsTests {
    func call(_ env: AgentEnv, _ session: AgentSession, _ tool: String, _ args: [String: Value] = [:]) async -> (String, Bool) {
        let r = await env.controller.callTool(tool, arguments: args, sessionID: session.id)
        let text = r.content.compactMap { if case let .text(t, _, _) = $0 { t } else { nil } }.joined()
        return (text, r.isError ?? false)
    }

    @Test func diskDerivedResultsAreUntrusted() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let (session, _) = env.session()
        let (volumes, volumesErr) = await call(env, session, "run_command", ["command": "tools.volumes"])
        #expect(!volumesErr && volumes.contains("\"untrusted\":true"), "\(volumes)")
        let (jobs, jobsErr) = await call(env, session, "list_jobs")
        #expect(!jobsErr && jobs.contains("\"untrusted\":true"), "\(jobs)")

        // Zmiana nazw z konfliktem: pominięty element (nazwa z dysku) w wyniku.
        try env.tmp.file("r/a.txt", "a")
        try env.tmp.file("r/b.txt", "b")
        let base = env.tmp.url.path
        env.approver.answer = true
        let (mr, mrErr) = await call(env, session, "multi_rename", ["paths": [.string(base + "/r/a.txt"), .string(base + "/r/b.txt")], "nameMask": "x"])
        #expect(!mrErr && mr.contains("\"untrusted\":true") && mr.contains("skipped"), "\(mr)")
        let (undo, undoErr) = await call(env, session, "undo")
        #expect(!undoErr && undo.contains("\"untrusted\":true"), "\(undo)")

        #expect(AgentController.fileDataCommands.isSuperset(of: ["tools.volumes", "device.list", "queue.list", "file.multiRename", "edit.undo"]))
    }
}
