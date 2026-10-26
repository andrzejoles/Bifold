import BifoldBridgeKit
import BifoldCore
import BifoldWorkspace
import Darwin
import Foundation
import Testing
@testable import BifoldAgent

@MainActor @Suite(.serialized) struct AgentSecurityTests {
    @Test func socketPermissions() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        var st = stat()
        #expect(lstat(env.runDir.path, &st) == 0 && st.st_mode & 0o777 == 0o700)
        #expect(lstat(env.socket.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(st.st_mode & S_IFMT == S_IFSOCK)
    }

    @Test func connectionWithoutHelloIsDropped() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let fd = try Wire.connect(path: env.socket.path)
        defer { close(fd) }
        // Brak ramki hello → po limicie czasu serwer odrzuca i zamyka połączenie.
        let reply = await Task.detached { try? Wire.readFrame(from: fd) }.value
        let decoded = reply.flatMap { try? JSONDecoder().decode(Wire.Reply.self, from: $0) }
        #expect(decoded?.type == "error")
        #expect(env.controller.connectionEvents.contains { if case .rejected("no_hello", _) = $0 { true } else { false } })
    }

    @Test func missingAndWrongTokenAreRejected() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        _ = env.session()

        let noToken = try BridgeClient(socket: env.socket, token: nil)
        #expect(await noToken.waitForExit() == 1)

        let wrong = try BridgeClient(socket: env.socket, token: SessionRegistry.base64url([UInt8](repeating: 7, count: 32)))
        #expect(await wrong.waitForExit() == 1)
        #expect(wrong.stderr.contains("bad_token"))
    }

    @Test func processOutsideAgentTreeIsRejected() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        // „Proces CLI” sesji to obcy proces — most (potomek testów) nie pochodzi od niego.
        let stranger = Process()
        stranger.executableURL = URL(filePath: "/bin/sleep")
        stranger.arguments = ["10"]
        try stranger.run()
        defer { stranger.terminate() }
        let (_, token) = env.session(cliPID: stranger.processIdentifier)
        let client = try BridgeClient(socket: env.socket, token: token)
        #expect(await client.waitForExit() == 1)
        #expect(client.stderr.contains("not_descendant"))
    }

    @Test func closedSessionTokenIsInvalid() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let (session, token) = env.session()
        env.controller.closeSession(session.id)
        let client = try BridgeClient(socket: env.socket, token: token)
        #expect(await client.waitForExit() == 1)
    }

    @Test func toolsWithLevelNoneAreHidden() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let (_, token) = env.session()
        let client = try BridgeClient(socket: env.socket, token: token)
        defer { client.terminate() }
        try await client.initialize()
        let names = try await client.toolNames()
        #expect(names.contains("get_state") && names.contains("get_selection") && names.contains("navigate") && names.contains("copy"))
        #expect(names.contains("run_command"))
        // Komendy z poziomem „Brak” nie mają narzędzi.
        let r = try await client.request("tools/list")
        let tools = ((r["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let runCommand = tools.first { $0["name"] as? String == "run_command" }?["description"] as? String ?? ""
        for hidden in ["file.deletePermanently", "tools.terminal", "tools.runCommand", "file.edit", "tools.commandLine"] {
            #expect(!runCommand.contains(hidden + " "), "\(hidden)")
        }
        let (text, isError) = try await client.call("run_command", ["command": "file.deletePermanently", "arguments": ["paths": ["x"]]])
        #expect(isError && text.contains("permission_denied"))
    }

    @Test func blockedPathsAreInaccessible() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("secret/id_ed25519", "PRIVATE KEY")
        try env.tmp.file("public/readme.txt", "hello")
        try FileManager.default.createSymbolicLink(atPath: env.tmp.url.appending(path: "public/link").path, withDestinationPath: env.tmp.url.appending(path: "secret").path)
        env.workspace.settings.agent.blockedPaths = [env.tmp.url.appending(path: "secret").path]
        let (_, token) = env.session()
        let client = try BridgeClient(socket: env.socket, token: token)
        defer { client.terminate() }
        try await client.initialize()

        let base = env.tmp.url.path
        for path in ["\(base)/secret/id_ed25519", "\(base)/public/../secret/id_ed25519", "\(base)/public/link/id_ed25519"] {
            let (text, isError) = try await client.call("read_file", ["path": path])
            #expect(isError && text.contains("blocked_path"), "\(path): \(text)")
            #expect(!text.contains("PRIVATE KEY"))
        }
        let (listing, _) = try await client.call("list_directory", ["path": base])
        #expect(listing.contains("public"))
        #expect(!listing.contains("\"secret\""))
        let (ok, okError) = try await client.call("read_file", ["path": "\(base)/public/readme.txt"])
        #expect(!okError && ok.contains("hello") && ok.contains("untrusted"))
        let (nav, navError) = try await client.call("navigate", ["path": "\(base)/secret"])
        #expect(navError && nav.contains("blocked_path"))
    }

    @Test func readLimitAndBinary() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("big.txt", String(repeating: "a", count: 5000))
        FileManager.default.createFile(atPath: env.tmp.url.appending(path: "bin.dat").path, contents: Data([0, 1, 2, 3, 0, 255]))
        env.workspace.settings.agent.maxReadBytes = 1000
        let (_, token) = env.session()
        let client = try BridgeClient(socket: env.socket, token: token)
        defer { client.terminate() }
        try await client.initialize()
        let (big, _) = try await client.call("read_file", ["path": env.tmp.url.path + "/big.txt"])
        #expect(big.contains("too_large"))
        let (part, _) = try await client.call("read_file", ["path": env.tmp.url.path + "/big.txt", "offset": 10, "length": 100])
        #expect(part.contains("\"length\":100"))
        let (bin, _) = try await client.call("read_file", ["path": env.tmp.url.path + "/bin.dat"])
        #expect(bin.contains("\"binary\":true"))
        let (hex, _) = try await client.call("read_file", ["path": env.tmp.url.path + "/bin.dat", "hex": true])
        #expect(hex.contains("00 01 02 03"))
    }

    @Test func approvalIsRequiredAndRespected() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("a.txt", "a")
        try env.tmp.dir("dst")
        let (_, token) = env.session()
        let client = try BridgeClient(socket: env.socket, token: token)
        defer { client.terminate() }
        try await client.initialize()

        env.approver.answer = false
        let (denied, deniedError) = try await client.call("copy", ["paths": [env.tmp.url.path + "/a.txt"], "destination": env.tmp.url.path + "/dst", "wait": true])
        #expect(deniedError && denied.contains("rejected_by_user"))
        #expect(!env.tmp.exists("dst/a.txt"))
        #expect(env.approver.requests.count == 1)
        #expect(env.approver.requests[0].preview.fileCount == 1)

        env.approver.answer = true
        let (_, okError) = try await client.call("copy", ["paths": [env.tmp.url.path + "/a.txt"], "destination": env.tmp.url.path + "/dst", "wait": true])
        #expect(!okError)
        #expect(env.tmp.exists("dst/a.txt"))

        // Nawigacja (poziom „Pełny”) nie pyta.
        let before = env.approver.requests.count
        let (_, navError) = try await client.call("navigate", ["path": env.tmp.url.path + "/dst"])
        #expect(!navError && env.approver.requests.count == before)
        #expect(env.workspace.activeTab.path == env.tmp.path.appending("dst"))

        // run_command dla komendy „Pełny” zmieniającej ustawienia → wymaga zgody.
        _ = try await client.call("run_command", ["command": "view.toggleHidden"])
        #expect(env.approver.requests.count == before + 1)
    }

    @Test func agentReadsSelectionAndNavigates() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("x.jpg", "1")
        try env.tmp.file("y.txt", "22")
        await env.workspace.activeTab.reload()
        env.workspace.activeTab.select(mask: "*.jpg")
        let (_, token) = env.session()
        let client = try BridgeClient(socket: env.socket, token: token)
        defer { client.terminate() }
        try await client.initialize()
        let (sel, _) = try await client.call("get_selection")
        #expect(sel.contains("x.jpg") && !sel.contains("y.txt"))
        _ = try await client.call("select", ["mask": "*.txt"])
        #expect(env.workspace.activeTab.selection.count == 2)
        let (state, _) = try await client.call("get_state")
        #expect(state.contains("\"selectedCount\":2"))
        _ = try await client.call("set_view", ["mode": "thumbnails"])
        #expect(env.workspace.activeTab.viewMode == .thumbnails)
    }

    @Test func rateLimit() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        env.workspace.settings.agent.callsPerMinute = 3
        let (_, token) = env.session()
        let client = try BridgeClient(socket: env.socket, token: token)
        defer { client.terminate() }
        try await client.initialize()
        for _ in 0..<3 { #expect(try await client.call("get_state").1 == false) }
        let (text, isError) = try await client.call("get_state")
        #expect(isError && text.contains("rate_limited"))
    }

    @Test func undoAgentSessionRestoresState() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("docs/a.txt", "a")
        try env.tmp.file("docs/b.txt", "b")
        let snapshot = try tree(env.tmp.url)
        let (session, token) = env.session()
        let client = try BridgeClient(socket: env.socket, token: token)
        defer { client.terminate() }
        try await client.initialize()
        let docs = env.tmp.url.path + "/docs"
        _ = try await client.call("navigate", ["path": docs])
        #expect(try await client.call("mkdir", ["name": "archiwum"]).1 == false)
        #expect(try await client.call("move", ["paths": [docs + "/a.txt"], "destination": docs + "/archiwum", "wait": true]).1 == false)
        #expect(try await client.call("rename", ["path": docs + "/b.txt", "newName": "B.md"]).1 == false)
        #expect(try await client.call("copy", ["paths": [docs + "/B.md"], "destination": docs + "/archiwum", "wait": true]).1 == false)
        #expect(try await client.call("set_tags", ["paths": [docs + "/B.md"], "tags": ["Czerwony"]]).1 == false)
        #expect(try tree(env.tmp.url) != snapshot)

        let plan = env.workspace.fileOps.undoPlan(forAgentSession: session.id)
        #expect(plan.conflicts.isEmpty)
        let result = await env.workspace.fileOps.execute(plan)
        #expect(result.errors.isEmpty)
        #expect(try tree(env.tmp.url) == snapshot)
        #expect(try LocalFS().tagsSync(of: env.tmp.path.appending("docs/b.txt")).isEmpty)
    }

    @Test func agentLogIsWrittenWithoutToken() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let (_, token) = env.session()
        let client = try BridgeClient(socket: env.socket, token: token)
        defer { client.terminate() }
        try await client.initialize()
        _ = try await client.call("get_state")
        env.controller.log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: env.tmp.url.appending(path: "logs"), includingPropertiesForKeys: nil)
        let all = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(all.contains("get_state"))
        #expect(!all.contains(token))
    }

    func tree(_ url: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for case let rel as String in FileManager.default.enumerator(atPath: url.path)! where !rel.hasPrefix(".support") && !rel.hasPrefix("logs") {
            let full = url.appending(path: rel)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir)
            out[rel] = isDir.boolValue ? "<dir>" : (try? String(contentsOf: full, encoding: .utf8)) ?? "?"
        }
        return out
    }
}

@Suite struct AgentUnitTests {
    @Test func constantTimeCompareAndBase64() {
        let a: [UInt8] = Array(0..<32)
        #expect(SessionRegistry.constantTimeEqual(a, a))
        #expect(!SessionRegistry.constantTimeEqual(a, Array(a.reversed())))
        #expect(!SessionRegistry.constantTimeEqual(a, Array(a.prefix(31))))
        #expect(SessionRegistry.decodeBase64url(SessionRegistry.base64url(a)) == a)
    }

    @Test func tokensAreUniqueAnd256Bit() {
        let r = SessionRegistry()
        let (_, t1) = r.create(kind: .codex, directory: .root)
        let (_, t2) = r.create(kind: .codex, directory: .root)
        #expect(t1 != t2)
        #expect(SessionRegistry.decodeBase64url(t1)?.count == 32)
        #expect(r.authenticate(token: t1) != nil)
        #expect(r.authenticate(token: "x") == nil)
    }

    @Test func blockedPathNormalization() throws {
        let home = "/Users/test"
        let b = BlockedPaths(["~/.ssh", "~/Library/Keychains"], home: home)
        #expect(b.isBlocked("/Users/test/.ssh"))
        #expect(b.isBlocked("/Users/test/.SSH/id_rsa"))
        #expect(b.isBlocked("/Users/test/Documents/../.ssh/config"))
        #expect(!b.isBlocked("/Users/test/.sshx"))
        #expect(!b.isBlocked("/Users/test/Documents"))
        // APFS nie rozróżnia normalizacji Unicode: ta sama nazwa w NFD też jest zablokowana.
        let polish = BlockedPaths(["~/Prywatne/Zażółć"], home: home)
        #expect(polish.isBlocked("/Users/test/Prywatne/" + "Zażółć".decomposedStringWithCanonicalMapping + "/plan.txt"))
        #expect(polish.isBlocked("/Users/test/prywatne/ZAŻÓŁĆ"))
    }

    @MainActor @Test func leastPrivilege() {
        let s = SessionRegistry().create(kind: .claude, directory: .root).0
        let registry = CommandRegistry.standard()
        let copy = registry.command("file.copy")!.descriptor
        let nav = registry.command("panel.navigate")!.descriptor
        var settings = AgentSettings()
        #expect(AgentPolicy.effectiveAccess(command: copy, session: s, settings: settings) == .approval)
        #expect(AgentPolicy.effectiveAccess(command: nav, session: s, settings: settings) == .full)
        #expect(AgentPolicy.effectiveAccess(command: nav, session: s, settings: settings, viaRunCommand: true) == .approval)
        settings.accessOverrides["file.copy"] = .read
        #expect(AgentPolicy.effectiveAccess(command: copy, session: s, settings: settings) == .read)
        // Nadpisanie nie podnosi poziomu.
        settings.accessOverrides["file.copy"] = .full
        #expect(AgentPolicy.effectiveAccess(command: copy, session: s, settings: settings) == .approval)
        #expect(AgentPolicy.decide(level: .read, effect: .modifiesFiles) != .allow)
        #expect(AgentPolicy.decide(level: .read, effect: .uiState) == .allow)
        #expect(AgentPolicy.decide(level: .approval, effect: .modifiesFiles) == .needsApproval)
    }

    @Test func launchSpecsKeepTokenOutOfArguments() {
        for kind in AgentKind.allCases {
            let spec = AgentLauncher.spec(kind: kind, bridge: "/App/bifold-mcp", socket: "/tmp/s.sock", token: "SECRET", directory: "/tmp", strict: true, sessionDirectory: "/tmp/sess")
            #expect(!spec.shellArguments.joined().contains("SECRET"), "\(kind)")
            #expect(!spec.files.values.joined().contains("SECRET"), "\(kind)")
            #expect(spec.environment[Bridge.tokenVariable] == "SECRET")
            #expect(spec.shellArguments.last!.hasPrefix("exec "))
        }
        let claude = AgentLauncher.spec(kind: .claude, bridge: "/b", socket: "/s", token: "T", directory: "/", strict: true, sessionDirectory: "/x")
        #expect(claude.displayCommand.contains("--strict-mcp-config"))
        #expect(claude.displayCommand.contains("mcp__bifold__*"))
        let codex = AgentLauncher.spec(kind: .codex, bridge: "/b", socket: "/s", token: "T", directory: "/", strict: true, sessionDirectory: "/x")
        #expect(codex.displayCommand.contains("read-only"))
        let agy = AgentLauncher.spec(kind: .antigravity, bridge: "/b", socket: "/s", token: "T", directory: "/", strict: true, sessionDirectory: "/x")
        #expect(agy.persistentRegistration != nil)
    }

    @Test func processEnvironmentOfAncestor() {
        setenv("BIFOLD_TEST_VAR", "abc", 1)
        // Środowisko bieżącego procesu (ten sam UID) — z KERN_PROCARGS2 widać wartości z chwili startu,
        // więc sprawdzamy tylko, że parser nie zawodzi dla zmiennej PATH.
        #expect(ProcessTree.environmentValue("PATH", of: getpid()) != nil)
        #expect(ProcessTree.ancestry(of: getpid()).count >= 2)
    }
}
