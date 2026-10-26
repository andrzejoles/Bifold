import BifoldBridgeKit
import BifoldCore
import BifoldWorkspace
import Darwin
import Foundation
import MCP
import Testing
@testable import BifoldAgent

/// Bramka uprawnień: blokady w wynikach wyszukiwania, wspólne rozwiązywanie ścieżek bramki
/// i komendy, zamrażanie argumentów (TOCTOU), operacje rekurencyjne, zakresy argumentów, dziennik.
@MainActor @Suite(.serialized) struct AgentGateTests {
    func call(_ env: AgentEnv, _ session: AgentSession, _ tool: String, _ args: [String: Value] = [:]) async -> (String, Bool) {
        let r = await env.controller.callTool(tool, arguments: args, sessionID: session.id)
        let text = r.content.compactMap { if case let .text(t, _, _) = $0 { t } else { nil } }.joined()
        return (text, r.isError ?? false)
    }

    /// Katalog z zablokowanym podkatalogiem `secret` (klucz z treścią „TAJNE-HASLO”) i jawnym `public`.
    func secretTree(_ env: AgentEnv) throws -> String {
        try env.tmp.file("secret/key.txt", "TAJNE-HASLO")
        try env.tmp.file("public/a.txt", "TAJNE-HASLO")
        try env.tmp.file("public/b.txt", "jawne")
        env.workspace.settings.agent.blockedPaths = [env.tmp.url.appending(path: "secret").path]
        return env.tmp.url.path
    }

    // MARK: 1. Wyszukiwanie

    @Test func searchResultsSkipBlockedPaths() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let base = try secretTree(env)
        let (session, _) = env.session()

        let (byName, err) = await call(env, session, "search", ["paths": [.string(base)], "nameMask": "*.txt", "includeHidden": true])
        #expect(!err && byName.contains("a.txt"), "\(byName)")
        #expect(!byName.contains("key.txt") && !byName.contains("/secret"))
        #expect(byName.contains("\"untrusted\":true"))
        if env.workspace.settings.toolPath("rg") != nil {
            let (byContent, _) = await call(env, session, "search", ["paths": [.string(base)], "content": "TAJNE", "includeHidden": true])
            #expect(byContent.contains("a.txt") && !byContent.contains("key.txt"), "\(byContent)")
        }
        // Domyślny katalog (bieżący panel) — też bez zablokowanych.
        let (implicit, _) = await call(env, session, "search", ["nameMask": "key*"])
        #expect(!implicit.contains("key.txt"))
        // Duplikaty: grupa z plikiem w zablokowanym katalogu znika (sam a.txt nie jest grupą).
        let (dups, _) = await call(env, session, "find_duplicates", ["paths": [.string(base)]])
        #expect(!dups.contains("key.txt") && !dups.contains("a.txt"), "\(dups)")
        // Zapisane wyszukiwanie z zablokowanym korzeniem.
        env.workspace.savedSearches = [SavedSearch(name: "s", criteria: SearchCriteria(roots: [.local(base + "/secret")], nameMask: "*"))]
        let (saved, savedErr) = await call(env, session, "saved_search_run", ["name": "s"])
        #expect(savedErr && saved.contains("blocked_path"), "\(saved)")
    }

    // MARK: 2. Jedna baza ścieżek względnych dla bramki i komendy

    @Test func relativePathsUseTheCommandsBase() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let base = try secretTree(env)
        try env.tmp.dir("x/y")
        try await env.workspace.left.activeTab.navigate(to: .local(base + "/x/y"))
        try await env.workspace.right.activeTab.navigate(to: .local(base + "/public"))
        env.workspace.activeSide = .left
        let (session, _) = env.session()

        // `right` liczone względem drugiego panelu (public) → ../secret/key.txt.
        let (cmp, cmpErr) = await call(env, session, "compare_files", ["left": .string(base + "/public/a.txt"), "right": "../secret/key.txt"])
        #expect(cmpErr && cmp.contains("blocked_path"), "\(cmp)")
        #expect(!cmp.contains("TAJNE"))
        // `side` — względem karty wskazanego panelu.
        let (nav, navErr) = await call(env, session, "navigate", ["path": "../secret", "side": "right"])
        #expect(navErr && nav.contains("blocked_path"), "\(nav)")
        let (sel, selErr) = await call(env, session, "set_selection", ["names": ["../secret/key.txt"], "side": "right"])
        #expect(selErr && sel.contains("blocked_path"), "\(sel)")
        // Cel domyślny: kursor drugiego panelu w zablokowanym katalogu (otwartym przez użytkownika).
        try await env.workspace.right.activeTab.navigate(to: .local(base + "/secret"), focus: "key.txt")
        let (def, defErr) = await call(env, session, "compare_files", ["left": .string(base + "/public/a.txt")])
        #expect(defErr && def.contains("blocked_path"), "\(def)")
        // Domyślny cel kopiowania (drugi panel) też jest sprawdzany.
        let (copy, copyErr) = await call(env, session, "copy", ["paths": [.string(base + "/public/b.txt")], "wait": true])
        #expect(copyErr && copy.contains("blocked_path"), "\(copy)")
        #expect(!env.tmp.exists("secret/b.txt"))
    }

    // MARK: 3. Prefiks alias: nie omija blokad

    @Test func aliasPrefixCannotReachLocalSecrets() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("docs/secret/id_ed25519", "PRIVATE KEY")
        try env.tmp.dir("docs/sub")
        env.workspace.settings.agent.blockedPaths = [env.tmp.url.appending(path: "docs/secret").path]
        // Atrapa połączenia (bez hasła i bez serwera) — `parsePath` rozpoznaje alias.
        try env.workspace.remotes.save(RemoteConnection(alias: "nas", kind: .sftp, host: "127.0.0.1", port: 1, user: "u"), secret: nil)
        try await env.workspace.activeTab.navigate(to: env.tmp.path.appending("docs/sub"))
        let (session, _) = env.session()
        for tool in ["read_file", "file_info", "list_directory"] {
            let target = tool == "list_directory" ? "nas:/../../secret" : "nas:/../../secret/id_ed25519"
            let (text, isError) = await call(env, session, tool, ["path": .string(target)])
            #expect(isError, "\(tool): \(text)")
            #expect(!text.contains("PRIVATE KEY") && !text.contains("id_ed25519\",\"path"), "\(tool): \(text)")
        }
        // Zwykła ścieżka zdalna w narzędziach lokalnych — czytelny błąd zamiast cichego odczytu lokalnego.
        let (remote, remoteErr) = await call(env, session, "read_file", ["path": "nas:/etc/hosts"])
        #expect(remoteErr && remote.contains("remote_read"), "\(remote)")
    }

    // MARK: 4. Zamrażanie argumentów (TOCTOU)

    @Test func approvedOperationUsesTheFrozenTarget() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("a.txt", "a")
        try env.tmp.file("b.txt", "b")
        let tab = env.workspace.activeTab
        try await tab.navigate(to: env.tmp.path, focus: "a.txt")
        let (session, _) = env.session()
        // W trakcie otwartego okna zgody kursor przechodzi na b.txt.
        env.approver.whileOpen = { _ in tab.cursor = env.tmp.path.appending("b.txt") }
        let (text, isError) = await call(env, session, "rename", ["newName": "renamed.txt"])
        #expect(!isError, "\(text)")
        #expect(env.tmp.exists("renamed.txt") && !env.tmp.exists("a.txt") && env.tmp.exists("b.txt"))
        // Podgląd i wykonanie dotyczą tej samej, absolutnej ścieżki.
        #expect(env.approver.requests.last?.arguments.string("path") == env.tmp.url.path + "/a.txt")
    }

    @Test func callsOfTheSessionWaitWhileApprovalIsOpen() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("a.txt", "a")
        try env.tmp.file("b.txt", "b")
        try await env.workspace.activeTab.navigate(to: env.tmp.path, focus: "a.txt")
        let (session, _) = env.session()
        var cursorMovedDuringApproval = false
        var concurrent: Task<(String, Bool), Never>?
        env.approver.whileOpen = { _ in
            // Agent próbuje przestawić kursor, gdy okno jest otwarte.
            concurrent = Task { @MainActor in await call(env, session, "set_cursor", ["name": "b.txt"]) }
            for _ in 0..<20 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(100))
            cursorMovedDuringApproval = env.workspace.activeTab.cursor == env.tmp.path.appending("b.txt")
        }
        let (text, isError) = await call(env, session, "rename", ["newName": "renamed.txt"])
        #expect(!isError, "\(text)")
        #expect(!cursorMovedDuringApproval)
        let (_, cursorErr) = await concurrent!.value
        #expect(!cursorErr)
        #expect(env.tmp.exists("renamed.txt") && env.tmp.exists("b.txt"))
    }

    @Test func liveStateChangeDuringApprovalIsRejected() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.dir("one")
        try env.tmp.dir("two")
        try await env.workspace.activeTab.navigate(to: env.tmp.path.appending("one"))
        let (session, _) = env.session()
        // mkdir zależy od bieżącego katalogu karty (lokalny czy serwer) — jego zmiana unieważnia zgodę.
        env.approver.whileOpen = { _ in try? await env.workspace.activeTab.navigate(to: env.tmp.path.appending("two")) }
        let (text, isError) = await call(env, session, "mkdir", ["name": "nowy"])
        #expect(isError && text.contains("state_changed"), "\(text)")
        #expect(!env.tmp.exists("one/nowy") && !env.tmp.exists("two/nowy"))
    }

    // MARK: 5. Zakresy argumentów (bez awarii)

    @Test func argumentRangesAreValidated() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("f.txt", "0123456789")
        let (session, _) = env.session()
        let base = env.tmp.url.path
        let (neg, negErr) = await call(env, session, "list_directory", ["path": .string(base), "limit": -1])
        #expect(negErr && neg.contains("limit"), "\(neg)")
        let (huge, hugeErr) = await call(env, session, "list_directory", ["path": .string(base), "limit": 1_000_000_000])
        #expect(hugeErr && huge.contains("10000"), "\(huge)")
        let (far, farErr) = await call(env, session, "read_file", ["path": .string(base + "/f.txt"), "offset": .int(Int.max), "length": 100])
        #expect(!farErr && far.contains("\"length\":0"), "\(far)")
        let (negLen, negLenErr) = await call(env, session, "read_file", ["path": .string(base + "/f.txt"), "length": -5])
        #expect(negLenErr, "\(negLen)")
        let (negOff, negOffErr) = await call(env, session, "read_file", ["path": .string(base + "/f.txt"), "offset": -1])
        #expect(negOffErr, "\(negOff)")
        let (mid, _) = await call(env, session, "read_file", ["path": .string(base + "/f.txt"), "offset": 3, "length": 4])
        #expect(mid.contains("\"text\":\"3456\""), "\(mid)")
        env.approver.answer = true
        let (mr, mrErr) = await call(env, session, "multi_rename", ["paths": [.string(base + "/f.txt")], "nameMask": "[C]", "counterStep": .int(Int.max)])
        #expect(mrErr && mr.contains("counterStep"), "\(mr)")
        #expect(env.tmp.exists("f.txt"))
    }

    // MARK: 7. Operacje rekurencyjne na przodkach zablokowanych ścieżek

    @Test func recursiveOperationsOnAncestorsOfBlockedPathsAreRejected() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let base = try secretTree(env)
        try env.tmp.dir("dst")
        try env.tmp.file("src/secret-like/x.txt", "x")
        let (session, _) = env.session()
        env.approver.answer = true
        for (tool, args): (String, [String: Value]) in [
            ("copy", ["paths": [.string(base)], "destination": .string(base + "/dst"), "wait": true]),
            ("move", ["paths": [.string(base)], "destination": .string(base + "/dst"), "wait": true]),
            ("trash", ["paths": [.string(base)]]),
            ("archive_create", ["paths": [.string(base)], "destination": .string(base + "/dst/a.zip")]),
            ("sync_preview", ["source": .string(base), "destination": .string(base + "/dst")]),
            ("sync_run", ["source": .string(base + "/dst"), "destination": .string(base)]),
        ] {
            let (text, isError) = await call(env, session, tool, args)
            #expect(isError && text.contains("blocked_path"), "\(tool): \(text)")
            #expect(!text.contains("key.txt"), "\(tool): \(text)")
        }
        #expect(env.approver.requests.isEmpty)
        // Element lądujący w zablokowanym miejscu (cel/nazwa) — też odrzucony.
        env.workspace.settings.agent.blockedPaths = [base + "/dst/secret-like"]
        let (into, intoErr) = await call(env, session, "copy", ["paths": [.string(base + "/src/secret-like")], "destination": .string(base + "/dst"), "wait": true])
        #expect(intoErr && into.contains("blocked_path"), "\(into)")
        #expect(!env.tmp.exists("dst/secret-like"))
        // Katalog bez zablokowanych ścieżek — bez zmian (za zgodą).
        let (ok, okErr) = await call(env, session, "copy", ["paths": [.string(base + "/public")], "destination": .string(base + "/dst"), "wait": true])
        #expect(!okErr, "\(ok)")
        #expect(env.tmp.exists("dst/public/b.txt"))
    }

    // MARK: 11–12. Dziennik

    @Test func logHasDigestsInsteadOfFileContentsAndEveryCall() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("poufne.txt", "TRESC-Z-PLIKU")
        let (session, _) = env.session()
        let (read, _) = await call(env, session, "read_file", ["path": .string(env.tmp.url.path + "/poufne.txt")])
        #expect(read.contains("TRESC-Z-PLIKU"))
        let (unknown, unknownErr) = await call(env, session, "no_such_tool")
        #expect(unknownErr && unknown.contains("unknown_tool"))
        let (missing, missingErr) = await call(env, session, "run_command")
        #expect(missingErr && missing.contains("missing_argument"))
        env.controller.closeSession(session.id)
        let (closed, closedErr) = await call(env, session, "get_state")
        #expect(closedErr && closed.contains("session_closed"))
        #expect(!env.controller.activities.contains { $0.status == .running })
        env.controller.log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: env.tmp.url.appending(path: "logs"), includingPropertiesForKeys: nil)
        let all = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!all.contains("TRESC-Z-PLIKU"))
        #expect(all.contains("resultSHA256"))
        #expect(all.contains("unknown_tool") && all.contains("missing_argument") && all.contains("session_closed"))
    }

    // MARK: 15. Odpowiedź ponad ramkę

    @Test func oversizedResponseIsAnError() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("big.txt", String(repeating: "a", count: Wire.maxFrame + 1000))
        env.workspace.settings.agent.maxReadBytes = Int64(Wire.maxFrame) * 2
        let (session, _) = env.session()
        let (text, isError) = await call(env, session, "read_file", ["path": .string(env.tmp.url.path + "/big.txt"), "length": .int(Wire.maxFrame + 1000)])
        #expect(isError && text.contains("too_large"), "\(text.prefix(200))")
        #expect(throws: Wire.Error.self) { try Wire.writeFrame(Data(count: Wire.maxFrame + 1), to: -1) }
    }

    // MARK: 18. Katalog danych aplikacji

    @Test func appDataDirectoryIsAlwaysBlocked() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        // Katalog danych testu (.support) nie ma nic wspólnego z „~/Library/Application Support/Bifold”.
        try FileManager.default.createDirectory(at: env.workspace.paths.root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: env.workspace.paths.root.appending(path: "connections.json"))
        let (session, _) = env.session()
        let (listing, _) = await call(env, session, "list_directory", ["path": .string(env.tmp.url.path), "includeHidden": true])
        #expect(!listing.contains(".support"), "\(listing)")
        let (read, readErr) = await call(env, session, "read_file", ["path": .string(env.workspace.paths.root.path + "/connections.json")])
        #expect(readErr && read.contains("blocked_path"), "\(read)")
    }

    // MARK: 19. Sumy kontrolne i zadania synchronizacji

    @Test func checksumFileCanBeUndoneAndSyncJobKeepsExclude() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        try env.tmp.file("dane.txt", "dane")
        try env.tmp.dir("a")
        try env.tmp.dir("b")
        let (session, _) = env.session()
        let (sum, sumErr) = await call(env, session, "checksum", ["paths": [.string(env.tmp.url.path + "/dane.txt")]])
        #expect(!sumErr, "\(sum)")
        #expect(env.tmp.exists("dane.txt.sha256"))
        let plan = env.workspace.fileOps.undoPlan(forAgentSession: session.id)
        #expect(plan.conflicts.isEmpty, "\(plan.conflicts)")
        _ = await env.workspace.fileOps.execute(plan)
        #expect(!env.tmp.exists("dane.txt.sha256"))

        env.approver.answer = true
        let (saved, savedErr) = await call(env, session, "sync_job_save", [
            "name": "z", "source": .string(env.tmp.url.path + "/a"), "destination": .string(env.tmp.url.path + "/b"), "exclude": ["tmp/x"],
        ])
        #expect(!savedErr, "\(saved)")
        #expect(env.workspace.syncJobs.first?.exclude == ["tmp/x"])
    }

    // MARK: 13. Okno zatwierdzania

    @Test func approvalTextEscapesControlAndBidiCharacters() {
        let name = "faktura\u{202E}fdp.exe\u{1B}[2K\nrm -rf ~\u{200B}"
        let shown = ApprovalText.sanitize(name)
        #expect(!shown.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x1B || $0.value == 0x0A || $0.value == 0x200B })
        #expect(shown.contains("\\u{202E}") && shown.contains("\\u{1B}") && shown.contains("\\u{A}"))
        #expect(ApprovalText.sanitize("Zażółć gęślą jaźń.txt") == "Zażółć gęślą jaźń.txt")
    }
}

/// Uzgadnianie przed uwierzytelnieniem, pętla `accept`, wycieki połączeń, gniazdo innej kopii.
@MainActor @Suite(.serialized) struct AgentServerHardeningTests {
    @Test func slowDripHelloIsDisconnectedByAbsoluteDeadline() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let fd = try Wire.connect(path: env.socket.path)
        defer { close(fd) }
        let started = ContinuousClock.now
        // 1 bajt na sekundę: przy limicie na każdy `read` połączenie trwałoby w nieskończoność.
        let closedAfter: Duration? = await Task.detached {
            var length = UInt32(100).bigEndian
            let header = Data(bytes: &length, count: 4) + Data(repeating: 0x20, count: 100)
            for byte in header {
                var b = byte
                if write(fd, &b, 1) != 1 { return ContinuousClock.now - started }
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 1000) > 0 { return ContinuousClock.now - started }
                if ContinuousClock.now - started > .seconds(12) { return nil }
            }
            return nil
        }.value
        #expect(closedAfter != nil && closedAfter! < .seconds(7), "\(String(describing: closedAfter))")
    }

    @Test func oversizedHelloHeaderIsRejectedImmediately() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let fd = try Wire.connect(path: env.socket.path)
        defer { close(fd) }
        var length = UInt32(Wire.maxFrame).bigEndian
        try Wire.writeAll(Data(bytes: &length, count: 4), to: fd)
        let started = ContinuousClock.now
        let reply = await Task.detached { try? Wire.readFrame(from: fd) }.value
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(reply.flatMap { try? JSONDecoder().decode(Wire.Reply.self, from: $0) }?.type == "error")
    }

    @Test func pendingHandshakesAreLimited() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        for _ in 0..<8 { fds.append(try Wire.connect(path: env.socket.path)) }
        try await Task.sleep(for: .milliseconds(200))
        let extra = try Wire.connect(path: env.socket.path)
        fds.append(extra)
        let started = ContinuousClock.now
        let reply = await Task.detached { try? Wire.readFrame(from: extra) }.value
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(reply.flatMap { try? JSONDecoder().decode(Wire.Reply.self, from: $0) }?.message == "busy")
    }

    @Test func bridgeDisconnectReleasesTheConnection() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let (session, token) = env.session()
        let client = try BridgeClient(socket: env.socket, token: token)
        try await client.initialize()
        #expect(env.controller.connectionCount(session.id) == 1)
        #expect(env.controller.sessions.first { $0.id == session.id }?.connected == true)
        client.terminate()
        for _ in 0..<100 where env.controller.connectionCount(session.id) > 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(env.controller.connectionCount(session.id) == 0)
        #expect(env.controller.sessions.first { $0.id == session.id }?.connected == false)
    }

    /// Połączenie zamknięte tuż po connect: odmowa nie może zakończyć procesu sygnałem SIGPIPE,
    /// a serwer przyjmuje potem kolejne połączenia.
    @Test func connectAndCloseDoesNotKillTheServer() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        for _ in 0..<50 { close(try Wire.connect(path: env.socket.path)) }
        try await Task.sleep(for: .milliseconds(200))
        let (_, token) = env.session()
        let client = try BridgeClient(socket: env.socket, token: token)
        defer { client.terminate() }
        try await client.initialize()
        #expect(try await client.call("get_state").1 == false)
    }

    @Test func secondInstanceDoesNotStealTheSocket() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let other = AgentServer(socketURL: env.socket, registry: SessionRegistry(), onAccept: { fd, _ in close(fd) })
        #expect(throws: AgentServer.StartError.alreadyRunning) { try other.start() }
        other.stop()
        #expect(FileManager.default.fileExists(atPath: env.socket.path))
        #expect(AgentServer.isListening(env.socket.path))
    }
}
