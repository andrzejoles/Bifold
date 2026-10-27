import Foundation
import Testing
@testable import BifoldCore
@testable import BifoldWorkspace

/// SCP: pobieranie i wysyłanie nie niszczą danych (dowiązania, błędy listingu, przerwane nadpisanie,
/// błąd jednego pliku) oraz wspólne połączenie główne kilku aliasów jednego serwera.
@MainActor @Suite(.serialized, .enabled(if: sshdAvailable)) struct ScpSafetyTests {
    func setup(_ sshd: TestSSHD, _ connections: RemoteConnection...) async throws -> (TempDir, Workspace) {
        let tmp = try TempDir()
        try tmp.dir("L")
        try tmp.dir("R")
        let (ws, _) = try await makeWorkspace(tmp, left: "L", right: "R")
        ws.remotes.sshConfigFile = sshd.clientConfig
        ws.remotes.sshKnownHostsFile = sshd.knownHosts
        for c in connections { try ws.remotes.save(c, secret: TestSSHD.passphrase) }
        return (tmp, ws)
    }

    func scp(_ ws: Workspace, _ alias: String) async throws -> ScpFS {
        try #require(try await ws.remotes.provider(alias) as? ScpFS)
    }

    func upload(_ fs: ScpFS, _ sources: [VFSPath], to destination: VFSPath, conflict: ConflictResolution = .skip,
                control: JobControl = JobControl()) async throws -> [String] {
        let job = ScpUpload(fs: fs, sources: sources, destination: destination, delegate: PolicyTransferDelegate(conflict: conflict))
        return try await runBlocking { try job.run(control: control) { _ in } }
    }

    /// Wrogi serwer: dowiązanie `aſ -> ../poza/plik` (APFS: „aſ” = „as”), potem plik `as` — `scp`
    /// zapisujący wprost pod nazwą poszedłby za dowiązaniem. Nazwa zajęta wcześniej przez kolizję
    /// („Readme (2)”) nie jest nadpisywana prawdziwym plikiem o tej nazwie.
    @Test func downloadNeverWritesThroughLinksOrOverExistingNames() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); ws.remotes.keychain.delete("aix") }
        try sshd.root.file("as", "z serwera")
        try sshd.root.file("Readme (2)", "prawdziwy")
        let fs = try await scp(ws, "aix")
        try tmp.file("poza/plik", "ważne")
        try tmp.file("kat/Readme (2)", "kolizja")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.path + "/kat/aſ", withDestinationPath: "../poza/plik")

        let entries = try fs.entriesSync(fs.root)
        for name in ["as", "Readme (2)"] {
            let entry = try #require(entries.first { $0.item.name == name })
            try fs.fetch(entry, to: tmp.path.appending("kat").appending(name), topLevel: false, isCancelled: { false }, isPaused: { false }) { _ in }
        }
        #expect(try tmp.read("poza/plik") == "ważne", "plik poza katalogiem docelowym nietknięty")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: tmp.url.path + "/kat/aſ") == "../poza/plik")
        #expect(try tmp.read("kat/as (2)") == "z serwera")
        #expect(try tmp.read("kat/Readme (2)") == "kolizja")
        #expect(try tmp.read("kat/Readme (2) (2)") == "prawdziwy")
        let left = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path + "/kat")
        #expect(!left.contains { $0.hasPrefix(".bifold-part-") }, "bez plików tymczasowych")
    }

    /// Wybór nazwy rozstrzyga system plików (także bez serwera): `RENAME_EXCL` nie idzie za dowiązaniem.
    @Test func exclusivePlacementSkipsLinksAndFoldedNames() throws {
        let tmp = try TempDir()
        try tmp.file("poza/plik", "ważne")
        try tmp.dir("kat")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.path + "/kat/bς", withDestinationPath: "../poza/plik")
        let part = try tmp.file("kat/.bifold-part-test", "nowy")
        let placed = try ScpFS.storeDownloaded(part, as: tmp.path.appending("kat/bσ"))
        #expect(placed.name == "bσ (2)")
        #expect(try tmp.read("kat/bσ (2)") == "nowy")
        #expect(try tmp.read("poza/plik") == "ważne")
        #expect(!tmp.exists("kat/.bifold-part-test"))
    }

    /// Błąd `cd`/`ls` nie wygląda jak pusty katalog: brak katalogu → „nie znaleziono”, pobranie drzewa
    /// z podkatalogiem bez praw → błąd (a nie po cichu pusty katalog, po którym „usuń” gubi dane).
    @Test func listingErrorsAreNotEmptyDirectories() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); ws.remotes.keychain.delete("aix") }
        let fs = try await scp(ws, "aix")
        #expect(throws: VFSError.notFound(fs.root.appending("brak"))) { _ = try fs.listSync(fs.root.appending("brak")) }

        try sshd.root.file("drzewo/a.txt", "a")
        try sshd.root.file("drzewo/zamknięty/b.txt", "b")
        let locked = sshd.root.url.path + "/drzewo/zamknięty"
        chmod(locked, 0)
        defer { chmod(locked, 0o755) }
        #expect(throws: (any Error).self) {
            _ = try fs.extract([fs.root.appending("drzewo")], toTemporaryIn: tmp.path.appending("R"), isCancelled: { false })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path + "/R").isEmpty, "katalog tymczasowy usunięty")
    }

    /// Katalog docelowy, którego nie da się wylistować (prawa `-wx`): błąd tego katalogu, a istniejący
    /// plik nie jest nadpisany bez pytania jak „nowy”.
    @Test func uploadIntoUnlistableDirectoryReportsError() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); ws.remotes.keychain.delete("aix") }
        try sshd.root.file("kat/a.txt", "stary")
        try tmp.file("L/kat/a.txt", "nowy")
        let dir = sshd.root.url.path + "/kat"
        chmod(dir, 0o300)
        defer { chmod(dir, 0o755) }
        let fs = try await scp(ws, "aix")
        let errors = try await upload(fs, [tmp.path.appending("L/kat")], to: fs.root)
        chmod(dir, 0o755)
        #expect(errors.count == 1 && errors[0].hasPrefix("kat:"), "\(errors)")
        #expect(try sshd.root.read("kat/a.txt") == "stary")
    }

    /// Anulowane „Nadpisz”: istniejący plik zostaje w całości (bez mieszanki bajtów i bez `rm -f`),
    /// plik tymczasowy znika.
    @Test func cancelledOverwriteKeepsOriginal() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); ws.remotes.keychain.delete("aix") }
        try sshd.root.file("duzy.bin", "oryginał")
        let original = try FileManager.default.attributesOfItem(atPath: sshd.root.url.path + "/duzy.bin")[.size] as? Int
        // Duży plik rzadki (szybko tworzony, wysyłany dość długo, żeby zdążyć anulować).
        let big = tmp.url.path + "/L/duzy.bin"
        FileManager.default.createFile(atPath: big, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(filePath: big))
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        let fs = try await scp(ws, "aix")
        let control = JobControl()
        let job = ScpUpload(fs: fs, sources: [.local(big)], destination: fs.root, delegate: PolicyTransferDelegate(conflict: .overwrite))
        let running = Task.detached { try job.run(control: control) { _ in } }
        let root = sshd.root.url.path
        // Wysyłanie trwa: na serwerze rośnie plik tymczasowy (albo — błędnie — sam plik docelowy).
        let started = await eventually {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            let sizes = names.filter { $0 != "duzy.bin" }.compactMap { try? FileManager.default.attributesOfItem(atPath: root + "/" + $0)[.size] as? Int }
            let target = try? FileManager.default.attributesOfItem(atPath: root + "/duzy.bin")[.size] as? Int
            return sizes.contains { $0 > 0 } || target != original
        }
        #expect(started)
        control.cancel()
        await #expect(throws: VFSError.cancelled) { _ = try await running.value }
        #expect(try sshd.root.read("duzy.bin") == "oryginał")
        #expect(await eventually { (try? FileManager.default.contentsOfDirectory(atPath: root)) == ["duzy.bin"] }, "plik tymczasowy usunięty")
    }

    /// Serwer w ISO-8859-2: „€” nie ma w kodowaniu — błąd tego pliku (ze ścieżką względną), reszta drzewa wysłana.
    @Test func oneBadNameDoesNotStopTheTree() async throws {
        let sshd = try TestSSHD()
        var c = sshd.connection("latin2")
        c.nameEncoding = .latin2
        let (tmp, ws) = try await setup(sshd, c)
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); ws.remotes.keychain.delete("latin2") }
        try tmp.file("L/paczka/a€.txt", "euro")
        try tmp.file("L/paczka/b.txt", "b")
        let fs = try await scp(ws, "latin2")
        let errors = try await upload(fs, [tmp.path.appending("L/paczka")], to: fs.root)
        #expect(errors.count == 1 && errors[0].hasPrefix("paczka/a€.txt:"), "\(errors)")
        #expect(try sshd.root.read("paczka/b.txt") == "b")
    }

    /// Dwa aliasy jednego serwera dzielą połączenie główne: rozłączenie B nie kończy terminala A,
    /// a agent nie rozłącza B, gdy A ma terminal.
    @Test func aliasesOfOneServerShareMasterSafely() async throws {
        let sshd = try TestSSHD()
        let a = sshd.connection("serwer-a"), b = sshd.connection("serwer-b")
        let (tmp, ws) = try await setup(sshd, a, b)
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); ws.remotes.keychain.delete("serwer-a"); ws.remotes.keychain.delete("serwer-b") }
        try await ws.invoke("remote.open", CommandArguments(["alias": "serwer-b", "terminal": false]))
        try await ws.invoke("remote.terminal", CommandArguments(["alias": "serwer-a"]))
        #expect(ws.right.tabs.contains { $0.terminal?.alias == "serwer-a" })
        #expect(ws.remotes.aliasesSharingSession(with: "serwer-b") == ["serwer-a", "serwer-b"])

        let gate = AllowAllGate()
        ws.agentGate = gate
        defer { withExtendedLifetime(gate) {} }
        await #expect(throws: (any Error).self) {
            try await ws.invoke("remote.disconnect", CommandArguments(["alias": "serwer-b"]), invoker: .agent(sessionID: "t", agentName: "t"))
        }
        #expect(ws.remotes.connected.contains("serwer-b"))

        try await ws.invoke("remote.disconnect", CommandArguments(["alias": "serwer-b"]))
        #expect(!ws.remotes.connected.contains("serwer-b"))
        #expect(try ws.remotes.sshSession(a).isConnected, "połączenie główne terminala A nadal działa")
        #expect(ws.right.tabs.contains { $0.terminal?.alias == "serwer-a" })
    }

    /// „Rozłącz” w trakcie łączenia: dostawca nie jest rejestrowany, połączenie główne nie zostaje.
    @Test func disconnectWhileConnectingCancels() async throws {
        let sshd = try TestSSHD()
        let c = sshd.connection("aix")
        let (tmp, ws) = try await setup(sshd, c)
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); ws.remotes.keychain.delete("aix") }
        let opening = Task { @MainActor in try await ws.remotes.provider("aix") }
        while ws.remotes.connecting["aix"] == nil { await Task.yield() }
        await ws.remotes.disconnect("aix")
        await #expect(throws: (any Error).self) { _ = try await opening.value }
        #expect(!ws.remotes.connected.contains("aix"))
        #expect((try? ws.providers.provider(for: RemoteFS.providerID("aix"))) == nil)
        #expect(!(try ws.remotes.sshSession(c).isConnected), "połączenie główne zamknięte")
    }

    /// Zmiana połączenia: stary dostawca wyrejestrowany (karta nie połączy się nim ze starym hostem).
    @Test func savingConnectionUnregistersOldProvider() async throws {
        let sshd = try TestSSHD()
        try sshd.root.dir("pod")
        var c = sshd.connection("aix")
        let (tmp, ws) = try await setup(sshd, c)
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); ws.remotes.keychain.delete("aix") }
        let old = try await scp(ws, "aix")
        c.path = sshd.root.url.path + "/pod"
        try ws.remotes.save(c, secret: TestSSHD.passphrase)
        #expect((try? ws.providers.provider(for: RemoteFS.providerID("aix"))) == nil)
        #expect(!old.session.isConnected)
        let new = try await scp(ws, "aix")
        #expect(new !== old && new.base.hasSuffix("/pod"))
    }
}
