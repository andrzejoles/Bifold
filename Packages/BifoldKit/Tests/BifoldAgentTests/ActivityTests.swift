import BifoldCore
import Foundation
import MCP
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

    /// Panel aktywności pokazuje nazwę narzędzia, argumenty i wynik bez znaków bidi i separatorów wierszy.
    @Test func activityTextIsSanitized() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let (s, _) = env.session()
        try env.tmp.file("f/\u{202E}fdp.exe", "x")
        _ = await env.controller.callTool("list_directory", arguments: ["path": "f"], sessionID: s.id)
        let listed = try #require(env.controller.activities.last)
        #expect(!listed.detailText.unicodeScalars.contains { $0.value == 0x202E } && listed.detailText.contains("\\u{202E}"), "\(listed.detailText)")
        _ = await env.controller.callTool("zły\u{2028}fałszywy wiersz", arguments: ["path": "a\u{2028}b"], sessionID: s.id)
        let unknown = try #require(env.controller.activities.last)
        for text in [unknown.toolText, unknown.detailText] {
            #expect(!text.unicodeScalars.contains { $0.value == 0x2028 } && text.contains("\\u{2028}"), "\(text)")
        }
    }
}
