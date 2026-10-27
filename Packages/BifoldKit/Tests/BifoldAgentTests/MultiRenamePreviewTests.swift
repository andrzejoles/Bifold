import BifoldCore
import BifoldWorkspace
import Foundation
import MCP
import Testing
@testable import BifoldAgent

/// Podgląd zmiany nazw wielu plików (liczony przed oknem zgody, z wyrażeniem regularnym od agenta)
/// nie blokuje głównego wątku: kosztowne wyrażenie nie zawiesza interfejsu.
@MainActor @Suite(.serialized) struct MultiRenamePreviewTests {
    @MainActor final class Ticker {
        var ticks = 0
        var task: Task<Void, Never>?

        func start() {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.ticks += 1
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }

        func stop() { task?.cancel() }
    }

    @Test func expensiveRegexPreviewDoesNotBlockMainActor() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let base = env.tmp.url.path
        var paths: [Value] = []
        for i in 0..<4 {
            let name = String(repeating: "a", count: 22) + "\(i).txt"
            try env.tmp.file("r/" + name, "x")
            paths.append(.string(base + "/r/" + name))
        }
        let (session, _) = env.session()
        env.approver.answer = false
        let ticker = Ticker()
        ticker.start()
        defer { ticker.stop() }
        try? await Task.sleep(for: .milliseconds(30))
        let before = ticker.ticks
        let started = Date()
        let r = await env.controller.callTool("multi_rename", arguments: [
            "paths": .array(paths), "search": "(a+)+b", "regex": true, "replace": "x",
        ], sessionID: session.id)
        let elapsed = Date().timeIntervalSince(started)
        let ticks = ticker.ticks - before
        #expect(r.isError == true)
        // Gdy podgląd trwał zauważalnie, główny wątek w tym czasie dalej obsługiwał zadania.
        if elapsed > 0.3 {
            #expect(Double(ticks) > elapsed / 0.01 / 4, "\(ticks) tików w \(elapsed) s")
        }
    }
}
