import BifoldBridgeKit
import BifoldCore
import Foundation
import Testing
@testable import BifoldAgent

/// Prawdziwe CLI agentów w trybie bez interfejsu. Uruchamiane tylko na żądanie
/// (zużywają limit subskrypcji): BIFOLD_E2E_AGENTS=1 swift test --filter AgentE2ETests
/// Można zawęzić: BIFOLD_E2E_ONLY=codex
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BIFOLD_E2E_AGENTS"] == "1"))
struct AgentE2ETests {
    @Test(arguments: AgentKind.allCases)
    func agentReadsSelectionAndNavigates(kind: AgentKind) async throws {
        if let only = ProcessInfo.processInfo.environment["BIFOLD_E2E_ONLY"], only != kind.rawValue { return }
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("raport-e2e.txt", "x")
        try env.tmp.dir("cel")
        await env.workspace.activeTab.reload()
        env.workspace.activeTab.select(mask: "raport-e2e.txt")

        let (session, token) = env.controller.createSession(kind: kind, directory: env.tmp.path)
        let sessionDir = env.runDir.appending(path: "s-\(session.id)")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let prompt = "Call the bifold MCP tool get_selection and tell me the file name. Then call the bifold tool navigate with path \(env.tmp.url.path)/cel and side right. Do not use any other tools. Reply with the file name only."
        let spec = AgentLauncher.spec(
            kind: kind, bridge: bridgeExecutable().path, socket: env.socket.path, token: token, directory: env.tmp.url.path,
            strict: true, sessionDirectory: sessionDir.path, prompt: prompt)
        for (path, contents) in spec.files { try Data(contents.utf8).write(to: URL(filePath: path)) }
        if kind == .antigravity, let reg = spec.persistentRegistration {
            // Rejestracja na czas testu.
            let add = Process()
            add.executableURL = URL(filePath: "/bin/zsh")
            add.arguments = ["-l", "-c", (["agy"] + reg).map(AgentLauncher.shellQuote).joined(separator: " ")]
            try add.run()
            add.waitUntilExit()
        }
        defer {
            if kind == .antigravity {
                let rm = Process()
                rm.executableURL = URL(filePath: "/bin/zsh")
                rm.arguments = ["-l", "-c", "agy mcp remove bifold"]
                try? rm.run()
                rm.waitUntilExit()
            }
        }

        let p = Process()
        p.executableURL = URL(filePath: spec.shell)
        p.arguments = spec.shellArguments
        p.currentDirectoryURL = env.tmp.url
        var e = ProcessInfo.processInfo.environment
        for key in e.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CODEX_") { e.removeValue(forKey: key) }
        for (k, v) in spec.environment { e[k] = v }
        p.environment = e
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        session.cliPID = p.processIdentifier
        let output = await Task.detached { String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }.value
        p.waitUntilExit()
        print("=== \(kind.rawValue) (exit \(p.terminationStatus)) ===\n\(output.suffix(3000))")
        print("activities: \(env.controller.activities.map { "\($0.tool): \($0.status)" })")
        print("connections: \(env.controller.connectionEvents)")
        #expect(env.controller.activities.contains { $0.tool == "get_selection" && $0.status == .succeeded }, "\(kind)")
        #expect(env.workspace.right.activeTab.path == env.tmp.path.appending("cel"), "\(kind)")
        #expect(output.contains("raport-e2e"), "\(kind)")
    }
}
