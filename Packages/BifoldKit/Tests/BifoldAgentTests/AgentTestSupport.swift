import BifoldBridgeKit
import BifoldCore
import BifoldWorkspace
import Foundation
@testable import BifoldAgent

/// Atrapa okna zatwierdzania.
@MainActor
final class MockApprover: ApprovalPresenter {
    var answer = true
    var requests: [ApprovalRequest] = []
    func requestApproval(_ request: ApprovalRequest) async -> Bool {
        requests.append(request)
        return answer
    }
}

@MainActor
struct AgentEnv {
    let tmp: TempDir
    let workspace: Workspace
    let controller: AgentController
    let approver: MockApprover
    let socket: URL
    let runDir: URL

    init() async throws {
        tmp = try TempDir()
        // Ścieżka gniazda musi być krótka (limit sun_path = 104 bajty).
        runDir = URL(filePath: "/tmp/bft-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        socket = runDir.appending(path: "agent.sock")
        workspace = Workspace(paths: AppPaths(root: tmp.url.appending(path: ".support")), persists: false, home: tmp.path)
        try await workspace.left.activeTab.navigate(to: tmp.path)
        try await workspace.right.activeTab.navigate(to: tmp.path)
        controller = AgentController(workspace: workspace, socketURL: socket, logDirectory: tmp.url.appending(path: "logs"))
        approver = MockApprover()
        controller.approvals = approver
        try controller.start()
    }

    func shutdown() {
        controller.stop()
        try? FileManager.default.removeItem(at: runDir)
    }

    /// Sesja, której „procesem CLI” jest proces testów (most jest jego potomkiem).
    func session(cliPID: pid_t = getpid()) -> (AgentSession, String) {
        let (s, token) = controller.createSession(kind: .claude, directory: tmp.path)
        s.cliPID = cliPID
        return (s, token)
    }
}

/// Ścieżka zbudowanego mostu `bifold-mcp` (obok pakietu testów).
func bridgeExecutable() -> URL {
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        let candidate = bundle.bundleURL.deletingLastPathComponent().appending(path: "bifold-mcp")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    let fallback = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for sub in [".build/debug/bifold-mcp", ".build/arm64-apple-macosx/debug/bifold-mcp", ".build/out/Products/Debug/bifold-mcp"] {
        let c = fallback.appending(path: sub)
        if FileManager.default.isExecutableFile(atPath: c.path) { return c }
    }
    return fallback.appending(path: ".build/debug/bifold-mcp")
}

/// Klient MCP przez prawdziwy proces mostu (stdio JSON-RPC).
final class BridgeClient: @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var nextID = 1
    private var buffer = Data()

    init(socket: URL, token: String?) throws {
        process.executableURL = bridgeExecutable()
        process.arguments = ["--socket", socket.path]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: Bridge.tokenVariable)
        if let token { env[Bridge.tokenVariable] = token }
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
    }

    var stderr: String {
        String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
    }

    func waitForExit(timeout: Double = 5) async -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return process.isRunning ? nil : process.terminationStatus
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Wysyła żądanie i czeka (poza głównym aktorem) na odpowiedź o tym samym id.
    func request(_ method: String, _ params: [String: Any] = [:], timeout: Double = 10) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = try await readLine(), let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any], obj["id"] as? Int == id {
                return obj
            }
        }
        throw URLError(.timedOut)
    }

    private func readLine() async throws -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            let handle = output.fileHandleForReading
            let chunk = await Task.detached { handle.availableData }.value
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    func initialize() async throws {
        _ = try await request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "test", "version": "1"],
        ])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func toolNames() async throws -> [String] {
        let r = try await request("tools/list")
        let tools = (r["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { $0["name"] as? String }
    }

    /// Zwraca (tekst, isError).
    func call(_ tool: String, _ args: [String: Any] = [:]) async throws -> (String, Bool) {
        let r = try await request("tools/call", ["name": tool, "arguments": args], timeout: 30)
        guard let result = r["result"] as? [String: Any] else { return ("\(r["error"] ?? "?")", true) }
        let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    func terminate() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
