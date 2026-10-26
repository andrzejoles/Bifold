import Foundation
import Testing
@testable import BifoldCore
@testable import BifoldWorkspace

/// Testowy serwer SSH bez roota (tylko bieżący użytkownik, logowanie kluczem). Domyślnie jak stary
/// AIX: wyłącznie stare algorytmy i bez podsystemu SFTP — działa tylko klasyczne SCP.
final class TestSSHD {
    let dir: TempDir
    let root: TempDir
    let port: Int
    let process: Process
    let clientKey: String
    let clientConfig: String
    let knownHosts: String
    static let passphrase = "tajne hasło klucza"

    init(sftp: Bool = false) throws {
        dir = try TempDir()
        root = try TempDir()
        let d = dir.url.path
        func keygen(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
            p.arguments = ["-q"] + args
            try p.run()
            p.waitUntilExit()
        }
        try keygen(["-t", "rsa", "-b", "2048", "-N", "", "-f", d + "/host_rsa"])
        try keygen(["-t", "ed25519", "-N", Self.passphrase, "-f", d + "/client_key"])
        try FileManager.default.copyItem(atPath: d + "/client_key.pub", toPath: d + "/authorized_keys")
        clientKey = d + "/client_key"
        clientConfig = d + "/ssh_config"
        knownHosts = d + "/known_hosts"
        try Data().write(to: URL(filePath: clientConfig))
        var lastError = ""
        for _ in 0..<5 {
            let port = Int.random(in: 20000...45000)
            let config = """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(d)/host_rsa
            PidFile \(d)/sshd.pid
            AuthorizedKeysFile \(d)/authorized_keys
            UsePAM no
            StrictModes no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            HostKeyAlgorithms ssh-rsa
            PubkeyAcceptedAlgorithms +ssh-rsa
            KexAlgorithms diffie-hellman-group14-sha1
            Ciphers aes128-cbc
            \(sftp ? "Subsystem sftp internal-sftp" : "")
            """
            try Data(config.utf8).write(to: URL(filePath: d + "/sshd_config"))
            let p = Process()
            p.executableURL = URL(filePath: "/usr/sbin/sshd")
            p.arguments = ["-D", "-f", d + "/sshd_config", "-E", d + "/sshd.log"]
            try p.run()
            for _ in 0..<50 where p.isRunning {
                if (try? String(contentsOfFile: d + "/sshd.log", encoding: .utf8))?.contains("Server listening") == true {
                    self.port = port
                    process = p
                    return
                }
                usleep(50_000)
            }
            p.terminate()
            lastError = (try? String(contentsOfFile: d + "/sshd.log", encoding: .utf8)) ?? ""
        }
        throw RemoteError.ssh("sshd: \(lastError)")
    }

    func connection(_ alias: String, kind: RemoteKind = .scp, legacy: Bool = true) -> RemoteConnection {
        RemoteConnection(alias: alias, kind: kind, host: "127.0.0.1", port: port, user: NSUserName(), path: root.url.path,
                         keyFile: clientKey, legacyAlgorithms: legacy)
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
    }
}

/// Bramka agenta przepuszczająca wszystko (test sprawdza samą komendę, nie politykę).
final class AllowAllGate: AgentInvocationGate {
    func authorize(_ command: Command, context: CommandContext) async throws {}
}

let sshdAvailable = FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") && FileManager.default.isExecutableFile(atPath: "/usr/bin/scp")

@Suite struct ScpParserTests {
    /// Wyjście `ls -la` z AIX 6.1 (grupy „system”/„staff”, pliki urządzeń, dowiązania, daty bez roku).
    @Test func aixListing() throws {
        let text = """
        total 48
        drwxr-xr-x    5 oracle   dba             256 Oct 17 09:15 .
        drwxr-xr-x   22 root     system         4096 Jan 12  2024 ..
        -rw-r--r--    1 oracle   dba         1048576 Mar  3  2025 alert_PROD.log
        -rwsr-x---    1 root     system        12345 Oct 16 23:59 suid prog
        drwxr-x---    2 oracle   dba             256 Sep  1 08:00 trace (stare)
        lrwxrwxrwx    1 oracle   dba              17 Oct 17 09:15 current -> trace (stare)
        crw-rw-rw-    1 root     system      2,  2 Oct 17 08:00 null
        -rw-------    1 oracle   dba               0 Dec 31 23:00 przyszły.txt
        """
        let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
        let dir = VFSPath(provider: ProviderID("remote:aix"), path: "/u01")
        let items = ScpFS.parseListing(text, in: dir, now: now)
        #expect(items.map(\.name) == ["alert_PROD.log", "suid prog", "trace (stare)", "current", "null", "przyszły.txt"])
        #expect(items[0].size == 1_048_576 && items[0].kind == .file && items[0].permissions == 0o644)
        #expect(items[1].permissions == 0o4750)
        #expect(items[2].isDirectory && items[3].kind == .symlink && items[4].kind == .other && items[4].size == 0)
        let cal = Calendar(identifier: .gregorian)
        #expect(cal.component(.year, from: items[0].modified!) == 2025)
        #expect(cal.component(.year, from: items[1].modified!) == 2026 && cal.component(.hour, from: items[1].modified!) == 23)
        // „Dec 31” bez roku przy dacie bieżącej w październiku to zeszły rok.
        #expect(cal.component(.year, from: items[5].modified!) == 2025)
        #expect(items[2].path.path == "/u01/trace (stare)")
    }

    @Test func escapingAndEncoding() throws {
        #expect(String(decoding: try SSHSession.scpEscape("/a b/(1)&'x'.txt", .utf8), as: UTF8.self) == "/a\\ b/\\(1\\)\\&\\'x\\'.txt")
        #expect(String(decoding: try SSHSession.scpEscape("/zażółć", .utf8), as: UTF8.self) == "/zażółć")
        #expect(throws: VFSError.self) { try SSHSession.scpEscape("/a\nb", .utf8) }
        #expect(SSHSession.shellQuote("it's") == "'it'\\''s'")
        // ISO-8859-2: „ą” = 0xB1, „ś” = 0xB6; nazwy z NFD zamieniane na NFC.
        #expect(try NameEncoding.latin2.encode("ąś") == [0xB1, 0xB6])
        #expect(try NameEncoding.utf8.encode("a\u{0328}") == [0xC4, 0x85])
        #expect(NameEncoding.latin2.decode(Data([0xB1, 0xB6])) == "ąś")
        #expect(throws: VFSError.self) { try NameEncoding.latin2.encode("😀") }
    }

    /// Argumenty idą do procesu bajt w bajt (Foundation.Process zamieniłby je na NFD).
    @Test func spawnPassesExactBytes() throws {
        let r = try Spawn.run("/bin/echo", [Array("zażółć".utf8)], environment: [:])
        #expect(Array(r.output) == Array("zażółć\n".utf8))
        let latin = try Spawn.run("/bin/echo", [try NameEncoding.latin2.encode("ą")], environment: [:])
        #expect(Array(latin.output) == [0xB1, 0x0A])
    }

    @Test func spawnCancelAndPause() throws {
        let start = Date()
        #expect(throws: VFSError.self) {
            try Spawn.run("/bin/sleep", [Array("5".utf8)], environment: [:], isCancelled: { Date().timeIntervalSince(start) > 0.3 })
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func hostAndUserCannotInjectOptions() throws {
        let dir = try TempDir()
        for host in ["-oProxyCommand=x", "a b", "host;rm"] {
            #expect(throws: VFSError.self) { try SSHSession(config: .init(host: host), runDirectory: dir.url, secret: { nil }) }
        }
        #expect(throws: VFSError.self) { try SSHSession(config: .init(host: "h", user: "-oX"), runDirectory: dir.url, secret: { nil }) }
    }
}

@MainActor @Suite(.serialized, .enabled(if: sshdAvailable)) struct ScpServerTests {
    func setup(_ sshd: TestSSHD) async throws -> (TempDir, Workspace, MockUI) {
        let tmp = try TempDir()
        try tmp.dir("L")
        try tmp.dir("R")
        let (ws, ui) = try await makeWorkspace(tmp, left: "L", right: "R")
        ws.remotes.sshConfigFile = sshd.clientConfig
        ws.remotes.sshKnownHostsFile = sshd.knownHosts
        return (tmp, ws, ui)
    }

    @Test func scpOnlyServerWithLegacyAlgorithms() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws, ui) = try await setup(sshd)
        defer { ws.remotes.stop() }
        try sshd.root.file("plik z spacją.txt", "abc")
        try sshd.root.file("kat (1)/pod/a&b'c.txt", "x")
        try sshd.root.file("zażółć gęślą.txt", "polskie")
        try FileManager.default.createSymbolicLink(atPath: sshd.root.url.path + "/link-kat", withDestinationPath: "kat (1)")
        try ws.remotes.save(sshd.connection("aix"), secret: TestSSHD.passphrase)
        defer { ws.remotes.keychain.delete("aix") }

        // Listing i nawigacja (hasło klucza przez askpass/FIFO, bez śladów w katalogu run).
        try await ws.invoke("remote.open", CommandArguments(["alias": "aix"]))
        let tab = ws.left.activeTab
        #expect(tab.path.provider.rawValue == "remote:aix")
        let names = Set(tab.items.map(\.name))
        #expect(names.isSuperset(of: ["plik z spacją.txt", "kat (1)", "zażółć gęślą.txt", "link-kat"]))
        #expect(tab.items.first { $0.name == "link-kat" }?.isNavigable == true)
        let runFiles = try FileManager.default.contentsOfDirectory(atPath: try ws.remotes.socketDirectory().path)
        #expect(!runFiles.contains { $0.hasPrefix("askpass-") || $0.hasSuffix(".log") })
        #expect(ws.resourceAccess(tab.path) == .read)

        // Pobranie (katalog rekurencyjnie, polskie i specjalne znaki) + cofnięcie.
        let paths: [JSONValue] = ["/kat (1)", "/zażółć gęślą.txt"].map { .string("aix:" + $0) }
        try await ws.invoke("file.copy", CommandArguments(["paths": .array(paths), "destination": .string(tmp.url.path + "/R"), "wait": true]))
        let downloaded = try tmp.read("R/kat (1)/pod/a&b'c.txt")
        #expect(downloaded == "x")
        #expect(try tmp.read("R/zażółć gęślą.txt") == "polskie")
        try await ws.invoke("edit.undo")
        #expect(!tmp.exists("R/zażółć gęślą.txt"))

        // Wysłanie katalogu z podkatalogami.
        try tmp.file("L/wyślij/raport ąę.txt", "raport")
        try tmp.file("L/wyślij/sub/b.txt", "b")
        try await ws.left.activeTab.navigate(to: tmp.path.appending("L"))
        try await ws.invoke("file.copy", CommandArguments(["paths": [.string(tmp.url.path + "/L/wyślij")], "destination": "aix:/", "wait": true]))
        #expect(try sshd.root.read("wyślij/raport ąę.txt") == "raport")
        #expect(try sshd.root.read("wyślij/sub/b.txt") == "b")
        // Ponowne wysłanie bez nadpisywania pomija istniejące.
        let job = try await ws.invoke("file.copy", CommandArguments(["paths": [.string(tmp.url.path + "/L/wyślij")], "destination": "aix:/", "wait": true, "conflict": "skip"]))
        #expect("\(job.value ?? .null)".contains("pominięto"))

        // Operacje na serwerze: nowy katalog, zmiana nazwy, usunięcie (z potwierdzeniem).
        try await ws.invoke("remote.open", CommandArguments(["alias": "aix"]))
        try await ws.invoke("file.mkdir", CommandArguments(["name": "nowy katalog"]))
        #expect(FileManager.default.fileExists(atPath: sshd.root.url.path + "/nowy katalog"))
        try await ws.invoke("file.rename", CommandArguments(["path": "aix:/plik z spacją.txt", "newName": "po zmianie.txt"]))
        #expect(sshd.root.exists("po zmianie.txt") && !sshd.root.exists("plik z spacją.txt"))
        await #expect(throws: (any Error).self) {
            try await ws.invoke("file.rename", CommandArguments(["path": "aix:/po zmianie.txt", "newName": "zażółć gęślą.txt"]))
        }
        ui.confirmAnswer = true
        try await ws.invoke("file.trash", CommandArguments(["paths": ["aix:/nowy katalog", "aix:/kat (1)"]]))
        #expect(!sshd.root.exists("nowy katalog") && !sshd.root.exists("kat (1)"))

        // Podgląd/odczyt treści.
        let fs = try await ws.remotes.provider("aix")
        let data = try await fs.readContents(VFSPath(provider: fs.id, path: "/zażółć gęślą.txt"), range: nil)
        #expect(String(decoding: data, as: UTF8.self) == "polskie")
        // Przenoszenie nieobsługiwane — jasny komunikat zamiast połowicznej operacji.
        await #expect(throws: (any Error).self) {
            try await ws.invoke("file.move", CommandArguments(["paths": ["aix:/po zmianie.txt"], "destination": .string(tmp.url.path + "/R"), "wait": true]))
        }
        #expect(sshd.root.exists("po zmianie.txt"))
    }

    /// Katalog danych aplikacji to „~/Library/Application Support/…” — ze spacją w ścieżce gniazda.
    @Test func runDirectoryWithSpaces() async throws {
        let sshd = try TestSSHD()
        let dir = URL(filePath: "/private/tmp/bifold sp-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = sshd.connection("spacja")
        let config = SSHSession.Config(host: c.host, port: c.port, user: c.user, keyFile: c.keyFile, legacyAlgorithms: true,
                                       configFile: sshd.clientConfig, knownHostsFile: dir.appending(path: "known hosts").path)
        let session = try SSHSession(config: config, runDirectory: dir, secret: { TestSSHD.passphrase })
        defer { session.disconnect() }
        try session.recordHostKey()
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "known hosts").path))
        try session.connect()
        let r = try session.run("echo ok")
        #expect(r.status == 0 && String(decoding: r.output, as: UTF8.self) == "ok\n", "\(r.errorText)")
        #expect(SSHSession.pathValue("/a b/%h") == "\"/a b/%%h\"")
    }

    @Test func disconnectClosesSessionAndTabs() async throws {
        let sshd = try TestSSHD(sftp: true)
        let (tmp, ws, _) = try await setup(sshd)
        defer { ws.remotes.stop() }
        try sshd.root.file("a.txt", "a")
        try ws.remotes.save(sshd.connection("aix"), secret: TestSSHD.passphrase)
        try ws.remotes.save(sshd.connection("sftp", kind: .sftp), secret: TestSSHD.passphrase)
        defer { ws.remotes.keychain.delete("aix"); ws.remotes.keychain.delete("sftp") }

        try await ws.invoke("remote.open", CommandArguments(["alias": "aix", "terminal": false]))
        try await ws.invoke("remote.open", CommandArguments(["alias": "sftp", "side": "right", "terminal": false]))
        let scp = try #require(try await ws.remotes.provider("aix") as? ScpFS)
        #expect(scp.session.isConnected && ws.remotes.connected == ["aix", "sftp"])

        // Bez aliasu: serwer z aktywnego panelu (lewy = SCP).
        try await ws.invoke("remote.disconnect")
        #expect(ws.left.tabs.count == 1 && ws.left.activeTab.path == tmp.path.appending("L"), "karta serwera zamknięta")
        #expect(!scp.session.isConnected, "połączenie główne ssh zamknięte")
        #expect(!ws.remotes.connected.contains("aix") && (try? ws.providers.provider(for: RemoteFS.providerID("aix"))) == nil)
        #expect(RemoteFS.alias(of: ws.right.activeTab.path) == "sftp", "drugi serwer bez zmian")

        // SFTP po aliasie; ponowne otwarcie działa.
        try await ws.invoke("remote.disconnect", CommandArguments(["alias": "sftp"]))
        #expect(ws.right.tabs.count == 1 && ws.right.activeTab.path == tmp.path.appending("R") && ws.remotes.connected.isEmpty)
        await #expect(throws: (any Error).self) { try await ws.invoke("remote.disconnect") }
        try await ws.invoke("remote.open", CommandArguments(["alias": "sftp", "terminal": false]))
        #expect(ws.left.activeTab.items.contains { $0.name == "a.txt" })
    }

    /// Połączenie SSH z Menedżera: pliki w aktywnym panelu, terminal w drugim (przez połączenie główne).
    @Test func sshTerminalInOtherPanel() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws, _) = try await setup(sshd)
        // Katalog testu musi żyć do końca (porzucony od razu znikał, a zapis połączeń go odtwarzał).
        defer { withExtendedLifetime(tmp) {} }
        defer { ws.remotes.stop() }
        try sshd.root.dir("logi dzienne")
        try ws.remotes.save(sshd.connection("aix"), secret: TestSSHD.passphrase)
        defer { ws.remotes.keychain.delete("aix") }

        try await ws.invoke("remote.open", CommandArguments(["alias": "aix", "path": "/logi dzienne", "terminal": true]))
        #expect(ws.left.activeTab.terminal == nil && ws.left.activeTab.path.path == "/logi dzienne")
        let term = ws.right.activeTab
        let spec = try #require(term.terminal)
        #expect(spec.alias == "aix" && spec.executable == "/usr/bin/ssh" && term.customTitle == "⌨ aix")
        #expect(spec.arguments.contains("-t") && !spec.arguments.contains("BatchMode=yes"))
        let dir = sshd.root.url.path + "/logi dzienne"
        #expect(spec.arguments.last?.hasPrefix("cd '\(dir)' && exec ") == true, "\(spec.arguments.last ?? "")")

        // Te same argumenty działają bez hasła (połączenie główne) — tu bez terminala, z poleceniem testowym.
        var args = spec.arguments.dropLast().map { $0 == "-t" ? "-T" : $0 }
        args.append("cd '\(dir)' && pwd")
        let r = try Spawn.run(spec.executable, args.map { Array($0.utf8) }, environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"], timeout: 20)
        #expect(r.status == 0 && String(decoding: r.output, as: UTF8.self).hasSuffix("logi dzienne\n"), "\(r.errorText)")

        // Karta-terminal nie trafia do zapisu sesji; rozłączenie ją zamyka.
        #expect(!ws.right.snapshot(home: ws.homePath).tabs.contains { $0.path == term.path && ws.right.tabs.count == 1 })
        #expect(ws.right.snapshot(home: ws.homePath).tabs.count == ws.right.tabs.count - 1)
        try await ws.invoke("remote.disconnect", CommandArguments(["alias": "aix"]))
        #expect(!ws.right.tabs.contains { $0.terminal != nil })

        // Agent nie otwiera terminala, nawet przy połączeniu z włączonym terminalem.
        let gate = AllowAllGate()
        ws.agentGate = gate
        let before = ws.right.tabs.count
        _ = try await ws.invoke("remote.open", CommandArguments(["alias": "aix"]), invoker: .agent(sessionID: "test", agentName: "test"))
        #expect(ws.right.tabs.count == before && !ws.right.tabs.contains { $0.terminal != nil })
    }

    /// Każda karta ma swoją maszynę: połączenia otwierają się w nowych kartach, terminale do różnych
    /// serwerów działają obok siebie, każdy z własnym typem terminala.
    @Test func tabsPerMachineAndSeveralTerminals() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws, _) = try await setup(sshd)
        defer { ws.remotes.stop() }
        var aix = sshd.connection("aix")
        aix.terminalType = "xterm"
        try ws.remotes.save(aix, secret: TestSSHD.passphrase)
        var bad = sshd.connection("drugi")
        bad.terminalType = "xterm; rm -rf /"
        try ws.remotes.save(bad, secret: TestSSHD.passphrase)
        defer { ws.remotes.keychain.delete("aix"); ws.remotes.keychain.delete("drugi") }

        try await ws.invoke("remote.open", CommandArguments(["alias": "aix", "terminal": true]))
        #expect(ws.left.tabs.count == 2 && ws.left.tabs[0].path == tmp.path.appending("L"), "karta lokalna została")
        #expect(ws.left.activeTab.customTitle == "🌐 aix")
        try await ws.invoke("remote.open", CommandArguments(["alias": "drugi", "terminal": true]))
        #expect(ws.left.tabs.count == 3 && RemoteFS.alias(of: ws.left.activeTab.path) == "drugi")
        // Drugi raz ten sam serwer w jego karcie — bez nowej karty z plikami.
        try await ws.invoke("remote.open", CommandArguments(["alias": "drugi", "terminal": false]))
        #expect(ws.left.tabs.count == 3)

        let terminals = ws.right.tabs.compactMap(\.terminal)
        #expect(terminals.map(\.alias) == ["aix", "drugi"] && ws.right.tabs[0].path == tmp.path.appending("R"))
        #expect(terminals.map(\.term) == ["xterm", "xterm-256color"], "niebezpieczny TERM zastąpiony domyślnym")
        try await ws.invoke("remote.terminal", CommandArguments(["alias": "aix"]))
        #expect(ws.right.tabs.compactMap(\.terminal?.alias) == ["aix", "drugi", "aix"])

        // Rozłączenie zamyka karty tylko tego serwera.
        try await ws.invoke("remote.disconnect", CommandArguments(["alias": "aix"]))
        #expect(ws.right.tabs.compactMap(\.terminal?.alias) == ["drugi"] && ws.left.tabs.count == 2)
        #expect(!ws.left.tabs.contains { RemoteFS.alias(of: $0.path) == "aix" })
    }

    @Test func modernClientWithoutLegacyModeFailsWithHint() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws, _) = try await setup(sshd)
        // Katalog testu musi żyć do końca (porzucony od razu znikał, a zapis połączeń go odtwarzał).
        defer { withExtendedLifetime(tmp) {} }
        defer { ws.remotes.stop() }
        try ws.remotes.save(sshd.connection("nowy", legacy: false), secret: TestSSHD.passphrase)
        defer { ws.remotes.keychain.delete("nowy") }
        do {
            _ = try await ws.remotes.provider("nowy")
            Issue.record("połączenie bez trybu zgodności nie powinno się udać")
        } catch {
            #expect(error.localizedDescription.contains("Zgodność ze starymi serwerami"))
        }
    }

    @Test func wrongPassphraseIsRejected() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws, _) = try await setup(sshd)
        // Katalog testu musi żyć do końca (porzucony od razu znikał, a zapis połączeń go odtwarzał).
        defer { withExtendedLifetime(tmp) {} }
        defer { ws.remotes.stop() }
        try ws.remotes.save(sshd.connection("zle"), secret: "złe hasło")
        defer { ws.remotes.keychain.delete("zle") }
        await #expect(throws: (any Error).self) { _ = try await ws.remotes.provider("zle") }
    }

    /// Ten sam przełącznik dla SFTP przez rclone (gdy stary serwer ma SFTP).
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/rclone")))
    func sftpWithLegacyAlgorithmsThroughRclone() async throws {
        let sshd = try TestSSHD(sftp: true)
        let (tmp, ws, _) = try await setup(sshd)
        // Katalog testu musi żyć do końca (porzucony od razu znikał, a zapis połączeń go odtwarzał).
        defer { withExtendedLifetime(tmp) {} }
        defer { ws.remotes.stop() }
        try sshd.root.file("dziennik.log", "sftp")
        try ws.remotes.save(sshd.connection("stary-sftp", kind: .sftp), secret: TestSSHD.passphrase)
        try ws.remotes.save(sshd.connection("nowy-sftp", kind: .sftp, legacy: false), secret: TestSSHD.passphrase)
        defer { ws.remotes.keychain.delete("stary-sftp"); ws.remotes.keychain.delete("nowy-sftp") }
        let fs = try await ws.remotes.provider("stary-sftp")
        let items = try await fs.list(fs.root, options: ListOptions())
        #expect(items.contains { $0.name == "dziennik.log" })
        let modern = try await ws.remotes.provider("nowy-sftp")
        await #expect(throws: (any Error).self) { _ = try await modern.list(modern.root, options: ListOptions()) }
        // Klucz serwera zapamiętany przy pierwszym połączeniu…
        let known = try String(contentsOfFile: sshd.knownHosts, encoding: .utf8)
        #expect(known.contains("[127.0.0.1]:\(sshd.port)"))
    }

    /// Podstawiony serwer (inny klucz pod tym samym adresem) jest odrzucany — hasło nie trafia do niego.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/rclone")))
    func sftpRejectsChangedHostKey() async throws {
        let sshd = try TestSSHD(sftp: true)
        let (tmp, ws, _) = try await setup(sshd)
        // Katalog testu musi żyć do końca (porzucony od razu znikał, a zapis połączeń go odtwarzał).
        defer { withExtendedLifetime(tmp) {} }
        defer { ws.remotes.stop() }
        let other = try TempDir()
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
        p.arguments = ["-q", "-t", "rsa", "-b", "2048", "-N", "", "-f", other.url.path + "/k"]
        try p.run()
        p.waitUntilExit()
        let fake = try String(contentsOfFile: other.url.path + "/k.pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
        try Data("[127.0.0.1]:\(sshd.port) \(fake)\n".utf8).write(to: URL(filePath: sshd.knownHosts))
        try ws.remotes.save(sshd.connection("podstawiony", kind: .sftp), secret: TestSSHD.passphrase)
        try ws.remotes.save(sshd.connection("podstawiony-scp"), secret: TestSSHD.passphrase)
        defer { ws.remotes.keychain.delete("podstawiony"); ws.remotes.keychain.delete("podstawiony-scp") }
        do {
            let fs = try await ws.remotes.provider("podstawiony")
            _ = try await fs.list(fs.root, options: ListOptions())
            Issue.record("połączenie z serwerem o zmienionym kluczu nie powinno się udać")
        } catch {
            #expect(error.localizedDescription.contains("Klucz serwera") || error.localizedDescription.contains("knownhosts"))
        }
        await #expect(throws: (any Error).self) { _ = try await ws.remotes.provider("podstawiony-scp") }
    }
}
