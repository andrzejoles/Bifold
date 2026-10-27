import BifoldCore
import BifoldWorkspace
import Foundation
import MCP
import Testing
@testable import BifoldAgent

/// Komendy kolejki z podanym `job`: nieznany identyfikator to błąd, a nie „wszystkie aktywne zadania”
/// (okno zgody pokazało jedno id, a `queue.cancel` anulowało wszystkie zadania użytkownika).
@MainActor @Suite(.serialized) struct QueueCommandTests {
    func call(_ env: AgentEnv, _ session: AgentSession, _ tool: String, _ args: [String: Value] = [:]) async -> (String, Bool) {
        let r = await env.controller.callTool(tool, arguments: args, sessionID: session.id)
        let text = r.content.compactMap { if case let .text(t, _, _) = $0 { t } else { nil } }.joined()
        return (text, r.isError ?? false)
    }

    @Test func unknownJobIDIsAnErrorNotAllJobs() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let jobs = env.workspace.jobs
        try env.tmp.file("a/x.txt", "x")
        try env.tmp.dir("b")
        let base = env.tmp.url.path
        let request = TransferRequest(kind: .copy, sources: [.local(base + "/a/x.txt")], destinationDirectory: .local(base + "/b"))
        // Zadanie A: zakończone i usunięte z listy (np. przez pasek zadań).
        let a = jobs.enqueue(.transfer(request), title: "A")
        #expect(await jobs.wait(for: a) == .completed)
        jobs.remove(a.id)
        // Zadanie B: czeka w kolejce (bez wolnego miejsca na wykonanie).
        jobs.maxConcurrent = 0
        let b = jobs.enqueue(.transfer(TransferRequest(kind: .copy, sources: [.local(base + "/a/x.txt")], destinationDirectory: .local(base + "/a"))), title: "B")
        defer { jobs.cancel(b) }
        #expect(!b.state.isFinished)

        let (session, _) = env.session()
        env.approver.answer = true
        for tool in ["queue_cancel", "queue_pause"] {
            let (text, isError) = await call(env, session, tool, ["job": .string(a.id.uuidString)])
            #expect(isError && text.contains("job"), "\(tool): \(text)")
            #expect(b.state == .queued, "\(tool): \(b.state)")
        }
        let (bad, badErr) = await call(env, session, "queue_cancel", ["job": "nie-uuid"])
        #expect(badErr && b.state == .queued, "\(bad)")
        // Bez `job` — nadal wszystkie aktywne (opisane w parametrze).
        let (all, allErr) = await call(env, session, "queue_cancel")
        #expect(!allErr && b.state == .cancelled, "\(all)")
    }
}
