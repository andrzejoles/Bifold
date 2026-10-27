import BifoldCore
import BifoldWorkspace
import Foundation
import MCP
import Testing
@testable import BifoldAgent

/// Limit wywołań obejmuje każde wywołanie (także `unknown_tool`, `missing_argument`, nieistniejącą
/// komendę w `run_command`), a seria odmów `rate_limited` to jeden wiersz dziennika z licznikiem —
/// zalew wywołaniami nie zapełni dysku ani nie zablokuje głównego wątku odświeżaniem aktywności.
@MainActor @Suite(.serialized) struct RateLimitTests {
    func logLines(_ env: AgentEnv, _ session: AgentSession) throws -> [String] {
        env.controller.log.flush()
        let dir = env.tmp.url.appending(path: "logs")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(session.id) }
        return try files.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map(String.init) }
    }

    @Test func floodOfInvalidCallsIsRateLimitedAndAggregatedInLog() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        env.workspace.settings.agent.callsPerMinute = 5
        let (session, _) = env.session()
        var codes: [String: Int] = [:]
        for i in 0..<10_000 {
            let r: CallTool.Result
            switch i % 3 {
            case 0: r = await env.controller.callTool("no_such_tool", arguments: [:], sessionID: session.id)
            case 1: r = await env.controller.callTool("run_command", arguments: [:], sessionID: session.id)
            default: r = await env.controller.callTool("run_command", arguments: ["command": "no.such.command"], sessionID: session.id)
            }
            let text = r.content.compactMap { if case let .text(t, _, _) = $0 { t } else { nil } }.joined()
            let code = String(text.prefix { $0 != ":" })
            codes[code, default: 0] += 1
        }
        #expect(codes["rate_limited"] == 10_000 - 5, "\(codes)")
        #expect(env.controller.activities.count <= 10, "\(env.controller.activities.count)")
        // Poprawne narzędzie w trakcie serii też jest odrzucane; koniec sesji zapisuje licznik serii (jeden wiersz).
        let state = await env.controller.callTool("get_state", arguments: [:], sessionID: session.id)
        #expect(state.isError == true)
        env.controller.closeSession(session.id)
        let lines = try logLines(env, session)
        #expect(lines.count <= 12, "\(lines.count) wierszy")
        #expect(lines.contains { $0.contains("\"rateLimitedCount\":9996") }, "\(lines)")
    }
}
