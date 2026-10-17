import BifoldCore
import Foundation
import Testing
@testable import BifoldAgent

@MainActor @Suite struct ActivityTests {
    @Test func activityStatusIsUpdated() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let (s, _) = env.session()
        let r = await env.controller.callTool("get_state", arguments: [:], sessionID: s.id)
        #expect(r.isError == false)
        #expect(env.controller.activities.last?.status == .succeeded)
        _ = await env.controller.callTool("read_file", arguments: ["path": "/nonexistent"], sessionID: s.id)
        if case .failed = env.controller.activities.last?.status {} else { Issue.record("\(String(describing: env.controller.activities.last?.status))") }
    }
}
